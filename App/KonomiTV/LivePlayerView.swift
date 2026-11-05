import SwiftUI
import KonomiKit

/// テレビ: live playback. The raw MPEG-TS stream is re-packaged into HLS by
/// LiveStreamSession and played from a loopback HTTP server.
///
/// Playback itself is owned by the app wide PlaybackController, so picture in
/// picture and background playback survive navigating away from this screen.
struct LivePlayerView: View {
    let model: AppModel
    private let initialChannel: LiveChannel

    /// Channel switched to on this screen (channel tab, remote, shortcuts).
    /// Switching in place keeps the shared player view on screen; replacing the
    /// navigation route would rebuild the screen around it.
    @State private var selectedChannel: LiveChannel?
    @State private var channels: LiveChannels?
    @State private var channelsError: String?
    @State private var panelTab: LivePanelTab = .program
    @State private var didSetInitialPanelTab = false
    @State private var showsPanel = true
    @State private var showsRemocon = false
    /// Whether the data broadcasting remote section of the panel is open.
    @State private var showsBMLRemote = false
    @State private var commentSession: LiveCommentSession?
    @State private var twitterSession: TwitterSession?
    /// Recording reservations of the programs of the program panel.
    @State private var presentReservation: Reservation?
    @State private var followingReservation: Reservation?
    @State private var isUpdatingReservation = false
    @State private var reservationError: String?
    @State private var showsCancelReservationConfirmation = false
    /// Incremented by the M shortcut so the posting form focuses its field.
    @State private var commentFocusRequest = 0

    init(model: AppModel, channel: LiveChannel) {
        self.model = model
        self.initialChannel = channel
    }

    private var channel: LiveChannel { selectedChannel ?? initialChannel }

    private var playbackItem: PlaybackItem { .live(channel) }

    private var playback: PlaybackController { model.playback }

    private var dataBroadcasting: DataBroadcastingController { playback.dataBroadcasting }

    /// The program on air: the EIT[p/f] the live stream reports replaces the
    /// value `GET /api/channels` returned (the web client does the same).
    private var programPresent: Program? {
        playback.liveProgramPresent ?? channel.programPresent
    }

    private var programFollowing: Program? {
        playback.liveProgramFollowing ?? channel.programFollowing
    }

    private var typeChannels: [LiveChannel] {
        channels?.displayedChannels(for: channel.type) ?? []
    }

    var body: some View {
        AdaptivePlayerLayout(
            isFullscreen: playback.isFullscreen,
            player: { playerArea },
            belowPlayer: { EmptyView() },
            info: { if showsPanel { panel } }
        )
        .playerFullscreen(playback)
        .navigationTitle(channel.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .background(playerShortcuts)
        .task(id: channel.displayChannelID) {
            startPlayback()
            startComments()
            startTwitter()
            await loadReservations()
        }
        .onChange(of: channel.programPresent?.id) { _, _ in
            Task { await loadReservations() }
        }
        .onChange(of: programPresent?.id) { _, _ in
            Task { await loadReservations() }
        }
        .onChange(of: dataBroadcasting.isFeatureAvailable) { _, available in
            // The channel lost its data broadcasting (or the setting was turned
            // off): close the remote with it.
            if !available {
                showsBMLRemote = false
            }
        }
        .task { await loadChannels() }
        .onAppear {
            playback.comments.apply(settings: model.settings)
            playback.viewAppeared(for: playbackItem)
            if !didSetInitialPanelTab {
                didSetInitialPanelTab = true
                panelTab = model.settings.tvPanelActiveTab
            }
        }
        .onChange(of: panelTab) { _, newValue in
            model.mutateSettings { settings in
                settings.tvPanelActiveTab = newValue
            }
        }
        .onDisappear {
            commentSession?.stop()
            commentSession = nil
            playback.viewDisappeared(for: playbackItem)
        }
        .onChange(of: model.settings) { _, newValue in
            playback.comments.apply(settings: newValue)
        }
        .sheet(isPresented: $showsRemocon) {
            RemoconSheet(
                channels: channels,
                initialType: channel.type
            ) { selected in
                showsRemocon = false
                switchChannel(selected)
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                playback.comments.toggleVisibility()
            } label: {
                Image(systemName: playback.comments.isVisible ? "text.bubble.fill" : "text.bubble")
            }
            .accessibilityIdentifier("player.comments.toggle")
            .accessibilityLabel("コメント")
            .accessibilityValue(playback.comments.isVisible ? "表示" : "非表示")

            Button {
                playback.captions.toggleVisibility()
            } label: {
                Image(systemName: playback.captions.isVisible ? "captions.bubble.fill" : "captions.bubble")
            }
            .accessibilityIdentifier("player.captions.toggle")
            .accessibilityLabel("字幕")
            .accessibilityValue(playback.captions.isVisible ? "表示" : "非表示")

            // A radio channel has no video, so capturing is not offered.
            if !channel.isRadioChannel {
                CaptureButton(playback: playback, settings: model.settings)
            }

            qualityMenu


            Button {
                showsRemocon = true
            } label: {
                Image(systemName: "appletvremote.gen4")
            }
            .accessibilityIdentifier("player.remocon")
            .accessibilityLabel("リモコン")
        }
    }

    private var qualityMenu: some View {
        Menu {
            Section("画質") {
                Picker("画質", selection: Binding(
                    get: { playback.profile.quality },
                    set: { playback.switchQuality($0) }
                )) {
                    ForEach(StreamQuality.liveQualities, id: \.self) { quality in
                        Text(quality.displayName).tag(quality)
                    }
                }
            }

            // 主音声 / 副音声 share the menu so the toolbar keeps room for
            // every control on a compact width.
            if playback.hasSecondaryAudio {
                Section("音声") {
                    Picker("音声", selection: Binding(
                        get: { playback.liveAudioSelection },
                        set: { playback.selectLiveAudio($0) }
                    )) {
                        Text("主音声").tag(AudioSelection.primary)
                        Text("副音声").tag(AudioSelection.secondary)
                    }
                }
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .accessibilityIdentifier("player.quality")
        .accessibilityLabel("画質")
    }

    // MARK: - Player

    @ViewBuilder
    private var playerArea: some View {
        ZStack {
            if playback.item == playbackItem, playback.isPlayerAttached {
                PlayerView(playback: playback)
            } else if playback.item == playbackItem, let message = playback.liveErrorMessage {
                errorArea(message)
            } else {
                loadingArea
            }

            if playback.liveStatus != LiveStreamStatusValue.onAir.rawValue,
               !playback.liveDetail.isEmpty {
                liveNotice
            }

            bmlStateLabel
        }
    }

    /// Hidden label the UI tests read (like `player.state`).
    private var bmlStateLabel: some View {
        Text(dataBroadcasting.state.rawValue)
            .font(.system(size: 1))
            .opacity(0.01)
            .accessibilityLabel(dataBroadcasting.state.rawValue)
            .accessibilityValue(
                dataBroadcasting.errorMessage ?? dataBroadcasting.state.rawValue
            )
            .accessibilityIdentifier("bml.state")
            .allowsHitTesting(false)
    }

    private var liveNotice: some View {
        VStack {
            Spacer(minLength: 0)
            Text(playback.liveDetail)
                .font(.footnote)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.black.opacity(0.65), in: Capsule())
                .padding(.bottom, 16)
        }
        .allowsHitTesting(false)
        .accessibilityIdentifier("live.notice")
    }

    private func errorArea(_ message: String) -> some View {
        ZStack {
            Color.black
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.white)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                Button("再試行") {
                    playback.retry()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(24)
        }
    }

    private var loadingArea: some View {
        ZStack {
            Color.black
            VStack(spacing: 10) {
                ProgressView()
                    .tint(.white)
                Text("ライブ配信を準備しています…")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
    }

    // MARK: - Panel

    private var panel: some View {
        VStack(alignment: .leading, spacing: 14) {
            panelTabPicker

            if dataBroadcasting.isFeatureAvailable, showsBMLRemote {
                BMLRemoteControlView(
                    controller: dataBroadcasting
                )
            }

            switch panelTab {
            case .program:
                programPanel
            case .channel:
                channelPanel
            case .comment:
                commentPanel
            case .twitter:
                twitterPanel
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var panelTabPicker: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                panelTabButton(.program, title: "番組", identifier: "panel.program")
                panelTabButton(.channel, title: "チャンネル", identifier: "panel.channel")
                panelTabButton(.comment, title: "コメント", identifier: "panel.comment")
                panelTabButton(.twitter, title: "Twitter", identifier: "panel.twitter")
            }
            .padding(2)
            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))

            // データ放送のリモコン (BML があるチャンネルのみ)
            if dataBroadcasting.isFeatureAvailable {
                // データ放送: the web client's d button. In the panel row rather than
                // the toolbar, which overflows into a menu on compact widths.
                Button {
                    toggleDataBroadcasting()
                } label: {
                    Group {
                        if dataBroadcasting.isLoading {
                            ProgressView()
                        } else {
                            Text("d")
                                .font(.headline.weight(.bold))
                        }
                    }
                    .frame(width: 34, height: 32)
                    .background(
                        dataBroadcasting.isPageVisible ? Color.accentColor : Color.secondary.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 9)
                    )
                    .foregroundStyle(dataBroadcasting.isPageVisible ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("player.dataBroadcasting")
                .accessibilityLabel("データ放送")
                .accessibilityValue(
                    dataBroadcasting.isLoading
                        ? "読み込み中"
                        : (dataBroadcasting.isPageVisible ? "表示" : "非表示")
                )

                Button {
                    showsBMLRemote.toggle()
                } label: {
                    Image(systemName: "appletvremote.gen4")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 34, height: 32)
                        .background(
                            showsBMLRemote ? Color.accentColor : Color.secondary.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 9)
                        )
                        .foregroundStyle(showsBMLRemote ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("bml.remote.toggle")
                .accessibilityLabel("データ放送のリモコン")
                .accessibilityValue(showsBMLRemote ? "表示" : "非表示")
            }
        }
    }

    private func panelTabButton(
        _ tab: LivePanelTab,
        title: String,
        identifier: String
    ) -> some View {
        Button {
            panelTab = tab
        } label: {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(
                    panelTab == tab ? Color.accentColor : Color.clear,
                    in: RoundedRectangle(cornerRadius: 7)
                )
                .foregroundStyle(panelTab == tab ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }

    @ViewBuilder
    private var programPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            channelHeader

            if let program = programPresent {
                Text(program.title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)

                ProgressView(value: program.progress(at: Date()))
                    .tint(.accentColor)

                HStack(spacing: 8) {
                    Text(Formatters.timeRange(start: program.startTime, end: program.endTime))
                    Spacer(minLength: 0)
                    Label("\(playback.liveViewerCount)", systemImage: "eye")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if !program.description.isEmpty {
                    Text(program.description)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !program.genres.isEmpty {
                    Text(program.genres.map { "\($0.major)／\($0.middle)" }.joined(separator: "・"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                ForEach(program.detail.keys.sorted(), id: \.self) { key in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(key)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(program.detail[key] ?? "")
                            .font(.footnote)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                presentProgramReservation(program)
            } else {
                Text("番組情報がありません")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let following = programFollowing {
                VStack(alignment: .leading, spacing: 4) {
                    Text("次の番組")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(following.title)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(Formatters.timeRange(start: following.startTime, end: following.endTime))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    followingProgramReservation(following)
                }
            }

            if let reservationError {
                Text(reservationError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .confirmationDialog(
            "録画予約をキャンセルしますか？",
            isPresented: $showsCancelReservationConfirmation,
            titleVisibility: .visible
        ) {
            Button("予約をキャンセル", role: .destructive) {
                Task { await cancelReservation() }
            }
            .accessibilityIdentifier("panel.program.reservation.cancel.confirm")
            Button("戻る", role: .cancel) {}
        }
    }

    // MARK: - Recording reservations

    /// Record button of the program that is on air, like the web client's
    /// program panel.
    @ViewBuilder
    private func presentProgramReservation(_ program: Program) -> some View {
        if model.isEDCBBackend {
            if let reservation = presentReservation {
                HStack(spacing: 8) {
                    Label(
                        ReservationStatus.label(reservation),
                        systemImage: ReservationStatus.systemImage(reservation)
                    )
                    .font(.caption)
                    .foregroundStyle(ReservationStatus.color(reservation))

                    Spacer(minLength: 0)

                    Button(role: .destructive) {
                        showsCancelReservationConfirmation = true
                    } label: {
                        Label("予約を削除", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .disabled(isUpdatingReservation)
                    .accessibilityIdentifier("panel.program.reservation.cancel")
                }
            } else {
                Button {
                    Task { await reserve(program) }
                } label: {
                    Label("録画予約", systemImage: "record.circle")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isUpdatingReservation)
                .accessibilityIdentifier("panel.program.reserve")
            }
        }
    }

    /// Reserve / cancel the following program.
    @ViewBuilder
    private func followingProgramReservation(_ program: Program) -> some View {
        if model.isEDCBBackend {
            if let reservation = followingReservation {
                HStack(spacing: 8) {
                    Label(
                        ReservationStatus.label(reservation),
                        systemImage: ReservationStatus.systemImage(reservation)
                    )
                    .font(.caption)
                    .foregroundStyle(ReservationStatus.color(reservation))

                    Spacer(minLength: 0)

                    Button {
                        Task { await cancelReservation(id: reservation.id) }
                    } label: {
                        Label("予約を削除", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .disabled(isUpdatingReservation)
                    .accessibilityIdentifier("panel.program.following.reservation.cancel")
                }
            } else {
                Button {
                    Task { await reserve(program) }
                } label: {
                    Label("録画予約", systemImage: "record.circle")
                }
                .buttonStyle(.bordered)
                .disabled(isUpdatingReservation)
                .accessibilityIdentifier("panel.program.following.reserve")
            }
        }
    }

    /// Reloads the reservations of the present and following programs.
    private func loadReservations() async {
        guard model.isEDCBBackend, let client = model.client else {
            presentReservation = nil
            followingReservation = nil
            return
        }
        guard let list = try? await client.reservations() else { return }
        presentReservation = list.reservations.first {
            $0.program.id == programPresent?.id
        }
        followingReservation = list.reservations.first {
            $0.program.id == programFollowing?.id
        }
    }

    private func reserve(_ program: Program) async {
        guard let client = model.client else { return }
        isUpdatingReservation = true
        reservationError = nil
        defer { isUpdatingReservation = false }

        do {
            let settings = await model.loadDefaultRecordSettings()
            try await client.addReservation(
                programID: program.id,
                recordSettings: settings,
                program: ReservationAddProgram(program: program)
            )
            await loadReservations()
        } catch {
            reservationError = ErrorText.message(for: error)
        }
    }

    private func cancelReservation(id: Int? = nil) async {
        guard let client = model.client else { return }
        let target = id ?? presentReservation?.id
        guard let target else { return }

        isUpdatingReservation = true
        reservationError = nil
        defer { isUpdatingReservation = false }

        do {
            try await client.deleteReservation(id: target)
            await loadReservations()
        } catch {
            reservationError = ErrorText.message(for: error)
        }
    }

    private var channelHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(channel.name)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text("チャンネル \(channel.channelNumber)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            HStack(spacing: 4) {
                Button {
                    stepChannel(-1)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("player.channel.previous")
                .accessibilityLabel("前のチャンネル")

                Button {
                    stepChannel(1)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("player.channel.next")
                .accessibilityLabel("次のチャンネル")
            }
        }
    }

    @ViewBuilder
    private var commentPanel: some View {
        if let session = commentSession {
            VStack(alignment: .leading, spacing: 10) {
                CommentListPanel(
                    title: "コメント",
                    comments: session.comments,
                    statusMessage: session.statusMessage,
                    height: 360,
                    onMuteUser: muteUser
                )

                CommentPostingForm(
                    isEnabled: session.isConnected,
                    successfulPostCount: session.successfulPostCount,
                    closeAfterSending: model.settings.closeCommentFormAfterSending,
                    focusRequest: commentFocusRequest
                ) { text, color, position, size in
                    session.postComment(
                        text: text,
                        color: color,
                        position: position,
                        size: size
                    )
                }
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var twitterPanel: some View {
        if let twitterSession {
            TwitterPanelView(
                model: model,
                session: twitterSession,
                context: TwitterPanelContext(
                    channelName: channel.name,
                    programTitle: programPresent?.title ?? channel.name,
                    programID: programPresent?.id
                )
            )
        } else {
            ProgressView()
                .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var channelPanel: some View {
        if !typeChannels.isEmpty {
            VStack(spacing: 0) {
                ForEach(typeChannels) { item in
                    Button {
                        switchChannel(item)
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.name)
                                    .font(.subheadline.weight(
                                        item.displayChannelID == channel.displayChannelID
                                            ? .semibold
                                            : .regular
                                    ))
                                if let program = item.programPresent {
                                    Text(program.title)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                            if item.displayChannelID == channel.displayChannelID {
                                Image(systemName: "checkmark")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tint)
                            }
                        }
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("panel.channel.\(item.displayChannelID)")

                    Divider()
                }
            }
        } else if let channelsError {
            Text(channelsError)
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Keyboard shortcuts

    private var playerShortcuts: some View {
        Group {
            shortcut(.space, action: playback.togglePlayPause)
            shortcut(.leftArrow, modifiers: [.command], action: { playback.seek(by: -0.5) })
            shortcut(.rightArrow, modifiers: [.command], action: { playback.seek(by: 0.5) })
            shortcut(.upArrow, action: { stepChannel(-1) })
            shortcut(.downArrow, action: { stepChannel(1) })
            shortcut("q", action: playback.toggleMute)
            shortcut("w", action: playback.seekToLiveEdge)
            shortcut("r", action: playback.restart)
            shortcut("p", action: { showsPanel.toggle() })
            shortcut("k", action: {
                showsPanel = true
                panelTab = .program
            })
            shortcut("l", action: {
                showsPanel = true
                panelTab = .channel
            })
            shortcut("d", action: playback.comments.toggleVisibility)
            shortcut("s", action: playback.captions.toggleVisibility)
            shortcut("m", action: {
                showsPanel = true
                panelTab = .comment
                commentFocusRequest += 1
            })

            // ***** データ放送 (Web 版の Alt + キー) *****

            // Alt + D: データ放送の d ボタン
            shortcut("d", modifiers: [.option], action: toggleDataBroadcasting)
            // Alt + Delete (Backspace): 戻る
            shortcut(.delete, modifiers: [.option], action: { sendBMLKey("back") })
            // Alt + Return: 決定
            shortcut(.return, modifiers: [.option], action: { sendBMLKey("enter") })
            shortcut(.upArrow, modifiers: [.option], action: { sendBMLKey("up") })
            shortcut(.downArrow, modifiers: [.option], action: { sendBMLKey("down") })
            shortcut(.leftArrow, modifiers: [.option], action: { sendBMLKey("left") })
            shortcut(.rightArrow, modifiers: [.option], action: { sendBMLKey("right") })

            remoconShortcuts(type: .gr, modifiers: [])
            remoconShortcuts(type: .bs, modifiers: [.shift])
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func remoconShortcuts(
        type: ChannelType,
        modifiers: EventModifiers
    ) -> some View {
        ForEach(0..<Self.remoconKeys.count, id: \.self) { index in
            shortcut(Self.remoconKeys[index], modifiers: modifiers) {
                switchToRemocon(type: type, remoconID: index + 1)
            }
        }
    }

    private static let remoconKeys: [KeyEquivalent] = [
        "1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "-", "^",
    ]

    private func shortcut(
        _ key: KeyEquivalent,
        modifiers: EventModifiers = [],
        action: @escaping @MainActor () -> Void
    ) -> some View {
        Button(action: action) {
            EmptyView()
        }
        .keyboardShortcut(key, modifiers: modifiers)
    }

    // MARK: - Actions

    /// Shows or hides the data broadcasting screen and opens the remote, so the
    /// user can interact with it right away.
    private func toggleDataBroadcasting() {
        guard dataBroadcasting.isFeatureAvailable else { return }
        playback.toggleDataBroadcasting()
        showsBMLRemote = true
        showsPanel = true
    }

    private func sendBMLKey(_ name: String) {
        guard dataBroadcasting.isFeatureAvailable else { return }
        dataBroadcasting.sendKey(name)
    }

    private func startPlayback() {
        guard let client = model.client else { return }
        playback.play(
            playbackItem,
            client: client,
            profile: QualityPreferences.liveProfile(cellular: model.networkMonitor.isCellular)
        )
    }

    /// Creates the Twitter panel session once per player screen. The panel
    /// keeps its own state (composer, feeds) while other tabs are shown.
    private func startTwitter() {
        guard twitterSession == nil else { return }
        let session = TwitterSession(model: model, playback: playback)
        // Folding the panel hides the information column the panel lives in.
        session.onFoldPanel = { showsPanel = false }
        twitterSession = session
    }

    /// Starts a fresh comment session for the current channel. Called from the
    /// same task that starts playback, so switching channels stops the old
    /// sockets before the new channel starts.
    private func startComments() {
        commentSession?.stop()
        commentSession = nil
        guard model.client != nil else { return }

        let session = LiveCommentSession(
            model: model,
            channel: channel,
            overlay: playback.comments
        )
        commentSession = session
        session.start()
    }

    private func muteUser(_ userID: String) {
        model.addMutedNiconicoUser(userID)
        commentSession?.removeComments(from: userID)
    }

    private func loadChannels() async {
        guard let client = model.client else { return }
        do {
            let result = try await client.channels()
            guard !Task.isCancelled else { return }
            channels = result
            channelsError = nil
        } catch {
            guard !Task.isCancelled else { return }
            channelsError = ErrorText.message(for: error)
        }
    }

    /// Moves to the next / previous channel shown in the list, skipping the
    /// hidden ones; a hidden channel (opened from the pinned tab) steps from
    /// its own place in the list.
    private func stepChannel(_ offset: Int) {
        let all = channels?.channels(for: channel.type) ?? []
        guard !typeChannels.isEmpty else { return }
        guard var index = all.firstIndex(where: {
            $0.displayChannelID == channel.displayChannelID
        }) else {
            if let first = typeChannels.first {
                switchChannel(first)
            }
            return
        }
        let count = all.count
        for _ in 0..<count {
            index = ((index + offset) % count + count) % count
            if all[index].isDisplay {
                switchChannel(all[index])
                return
            }
        }
    }

    private func switchToRemocon(type: ChannelType, remoconID: Int) {
        guard let target = channels?
            .channels(for: type)
            .first(where: { $0.remoconID == remoconID }) else {
            return
        }
        switchChannel(target)
    }

    private func switchChannel(_ newChannel: LiveChannel) {
        guard newChannel.displayChannelID != channel.displayChannelID else { return }
        selectedChannel = newChannel
        playback.viewAppeared(for: .live(newChannel))
    }
}

/// リモコン: number buttons 1–12 by remocon ID for the selected broadcast
/// type (web Panel/Remocon.vue).
private struct RemoconSheet: View {
    let channels: LiveChannels?
    let onSelect: (LiveChannel) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var type: ChannelType

    init(
        channels: LiveChannels?,
        initialType: ChannelType,
        onSelect: @escaping (LiveChannel) -> Void
    ) {
        self.channels = channels
        self.onSelect = onSelect
        _type = State(initialValue: initialType)
    }

    private var availableTypes: [ChannelType] {
        channels?.nonEmptyGroups().map { $0.type } ?? []
    }

    private var currentChannels: [LiveChannel] {
        channels?.channels(for: type) ?? []
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if availableTypes.count > 1 {
                    Picker("放送種別", selection: $type) {
                        ForEach(availableTypes, id: \.self) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityIdentifier("remocon.typePicker")
                }

                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3),
                    spacing: 12
                ) {
                    ForEach(1...12, id: \.self) { remoconID in
                        remoconButton(remoconID)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(20)
            .navigationTitle("リモコン")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("remocon.sheet")
            .toolbar {
                SheetCloseButton { dismiss() }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func remoconButton(_ remoconID: Int) -> some View {
        let target = currentChannels.first { $0.remoconID == remoconID }

        return Button {
            guard let target else { return }
            onSelect(target)
            dismiss()
        } label: {
            Text(String(remoconID))
                .font(.title2.monospacedDigit().weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 48)
        }
        .buttonStyle(.bordered)
        .disabled(target == nil)
        .accessibilityIdentifier("remocon.\(type.rawValue).\(remoconID)")
        .accessibilityLabel(
            target.map { "\(remoconID) \($0.name)" } ?? String(remoconID)
        )
    }
}
