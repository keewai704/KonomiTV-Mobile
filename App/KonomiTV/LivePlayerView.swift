import SwiftUI
import KonomiKit

/// テレビ: live playback. The raw MPEG-TS stream is re-packaged into HLS by
/// LiveStreamSession and played from a loopback HTTP server.
///
/// Playback itself is owned by the app wide PlaybackController, so picture in
/// picture and background playback survive navigating away from this screen.
struct LivePlayerView: View {
    let model: AppModel
    let channel: LiveChannel

    @State private var channels: LiveChannels?
    @State private var channelsError: String?
    @State private var panelTab: LivePanelTab = .program
    @State private var showsPanel = true
    @State private var showsRemocon = false

    private enum LivePanelTab: String, Hashable {
        case program
        case channel
    }

    private var playbackItem: PlaybackItem { .live(channel) }

    private var playback: PlaybackController { model.playback }

    private var typeChannels: [LiveChannel] {
        channels?.channels(for: channel.type) ?? []
    }

    var body: some View {
        AdaptivePlayerLayout(
            player: { playerArea },
            belowPlayer: { EmptyView() },
            info: { if showsPanel { panel } }
        )
        .navigationTitle(channel.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .background(playerShortcuts)
        .task { startPlayback() }
        .task { await loadChannels() }
        .onAppear { playback.viewAppeared(for: playbackItem) }
        .onDisappear { playback.viewDisappeared(for: playbackItem) }
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
            qualityMenu

            if playback.hasSecondaryAudio {
                audioMenu
            }

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
            ForEach(StreamQuality.liveQualities, id: \.self) { quality in
                Button {
                    playback.switchQuality(quality)
                } label: {
                    if playback.profile.quality == quality {
                        Label(quality.displayName, systemImage: "checkmark")
                    } else {
                        Text(quality.displayName)
                    }
                }
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .accessibilityIdentifier("player.quality")
        .accessibilityLabel("画質")
    }

    private var audioMenu: some View {
        Menu {
            Button {
                playback.selectLiveAudio(.primary)
            } label: {
                if playback.liveAudioSelection == .primary {
                    Label("主音声", systemImage: "checkmark")
                } else {
                    Text("主音声")
                }
            }

            Button {
                playback.selectLiveAudio(.secondary)
            } label: {
                if playback.liveAudioSelection == .secondary {
                    Label("副音声", systemImage: "checkmark")
                } else {
                    Text("副音声")
                }
            }
        } label: {
            Image(systemName: "waveform")
        }
        .accessibilityIdentifier("player.audio")
        .accessibilityLabel("音声")
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
        }
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

            switch panelTab {
            case .program:
                programPanel
            case .channel:
                channelPanel
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var panelTabPicker: some View {
        HStack(spacing: 2) {
            panelTabButton(.program, title: "番組", identifier: "panel.program")
            panelTabButton(.channel, title: "チャンネル", identifier: "panel.channel")
        }
        .padding(2)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
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

            if let program = channel.programPresent {
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
            } else {
                Text("番組情報がありません")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let following = channel.programFollowing {
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
                }
            }
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

    private func startPlayback() {
        guard let client = model.client else { return }
        playback.play(
            playbackItem,
            client: client,
            profile: QualityPreferences.liveProfile(cellular: model.networkMonitor.isCellular)
        )
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

    private func stepChannel(_ offset: Int) {
        guard !typeChannels.isEmpty else { return }
        guard let index = typeChannels.firstIndex(where: {
            $0.displayChannelID == channel.displayChannelID
        }) else {
            if let first = typeChannels.first {
                switchChannel(first)
            }
            return
        }
        let count = typeChannels.count
        let next = ((index + offset) % count + count) % count
        switchChannel(typeChannels[next])
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
        model.switchLiveChannel(newChannel)
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
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") {
                        dismiss()
                    }
                }
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
