import SwiftUI
import KonomiKit

/// A recorded program, with the HLS player above (or beside) the details.
///
/// Playback itself is owned by the app wide PlaybackController, so picture in
/// picture and background playback survive navigating away from this screen.
struct VideoDetailView: View {
    let model: AppModel
    let video: RecordedProgram

    @Environment(\.dismiss) private var dismiss

    @State private var detail: RecordedProgram?
    @State private var series: Series?
    @State private var activeSheet: VideoDetailSheet?
    @State private var showsDeleteConfirmation = false
    @State private var isWorking = false
    @State private var actionMessage: String?
    @State private var isDownloading = false
    @State private var downloadProgress: Double = 0
    @State private var commentSession: RecordedCommentSession?
    @State private var panelTab: VideoPanelTab = .recordedProgram
    @State private var didSetInitialPanelTab = false
    @State private var twitterSession: TwitterSession?

    private var current: RecordedProgram { detail ?? video }

    private var playbackItem: PlaybackItem { .video(video) }

    private var isInMylist: Bool { model.isInMylist(videoID: video.id) }

    private var isAdmin: Bool { model.user?.isAdmin == true }

    private var isRecording: Bool { current.recordedVideo.status == "Recording" }

    var body: some View {
        AdaptivePlayerLayout(
            isFullscreen: model.playback.isFullscreen,
            player: { playerArea },
            belowPlayer: { sceneStrip },
            info: { info }
        )
        .playerFullscreen(model.playback)
        .navigationTitle(current.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .task {
            startPlayback()
            startComments()
            startTwitter()
        }
        .task { await loadDetail() }
        .onAppear {
            model.playback.comments.apply(settings: model.settings)
            model.playback.viewAppeared(for: playbackItem)
            if !didSetInitialPanelTab {
                didSetInitialPanelTab = true
                panelTab = model.settings.videoPanelActiveTab
            }
        }
        .onChange(of: panelTab) { _, newValue in
            model.mutateSettings { settings in
                settings.videoPanelActiveTab = newValue
            }
        }
        .onDisappear {
            commentSession?.stop()
            commentSession = nil
            model.playback.viewDisappeared(for: playbackItem)
        }
        .background {
            PlaybackProgressObserver(playback: model.playback) { position, isPlaying in
                commentSession?.update(position: position, isPlaying: isPlaying)
            }
        }
        .onChange(of: model.settings) { _, newValue in
            model.playback.comments.apply(settings: newValue)
        }
        .background(playerShortcuts)
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .fileInfo:
                RecordedFileInfoSheet(program: current)
            case .share(let file):
                ShareSheet(url: file.url)
            case .offline:
                OfflineSaveSheet(model: model, program: current)
            }
        }
        .confirmationDialog(
            "本当に録画ファイルを削除しますか？",
            isPresented: $showsDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("録画ファイルを削除", role: .destructive) {
                deleteVideo()
            }
            .accessibilityIdentifier("video.delete.confirm")

            Button("キャンセル", role: .cancel) {}
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                model.playback.comments.toggleVisibility()
            } label: {
                Image(systemName: model.playback.comments.isVisible ? "text.bubble.fill" : "text.bubble")
            }
            .accessibilityIdentifier("player.comments.toggle")
            .accessibilityLabel("コメント")
            .accessibilityValue(model.playback.comments.isVisible ? "表示" : "非表示")

            Button {
                model.playback.captions.toggleVisibility()
            } label: {
                Image(systemName: model.playback.captions.isVisible ? "captions.bubble.fill" : "captions.bubble")
            }
            .accessibilityIdentifier("player.captions.toggle")
            .accessibilityLabel("字幕")
            .accessibilityValue(model.playback.captions.isVisible ? "表示" : "非表示")

            CaptureButton(playback: model.playback, settings: model.settings)

            qualityMenu

            Menu {
                Button {
                    activeSheet = .fileInfo
                } label: {
                    Label("録画ファイル情報", systemImage: "doc.text")
                }
                .accessibilityIdentifier("video.menu.info")

                Button {
                    startDownload()
                } label: {
                    Label("ダウンロード", systemImage: "arrow.down.circle")
                }
                .disabled(isRecording || isDownloading)
                .accessibilityIdentifier("video.menu.download")

                // オフライン保存 is a 0.15 feature; v0.14.1 has no such route.
                if model.offlineVideosAvailable {
                    Button {
                        activeSheet = .offline
                    } label: {
                        Label("オフライン保存", systemImage: "arrow.down.circle")
                    }
                    .disabled(isRecording)
                    .accessibilityIdentifier("video.offline.save")
                }

                if isAdmin {
                    Button {
                        reanalyze()
                    } label: {
                        Label("メタデータを再解析", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .accessibilityIdentifier("video.menu.reanalyze")

                    Button {
                        regenerateThumbnail()
                    } label: {
                        Label("サムネイルを再生成", systemImage: "photo")
                    }
                    .accessibilityIdentifier("video.menu.thumbnail")

                    Divider()

                    Button(role: .destructive) {
                        showsDeleteConfirmation = true
                    } label: {
                        Label("録画ファイルを削除", systemImage: "trash")
                    }
                    .disabled(isRecording)
                    .accessibilityIdentifier("video.menu.delete")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityIdentifier("video.menu")
        }
    }

    // MARK: - Menus

    /// In-player quality menu: switching restarts the video stream with the
    /// new base quality and resumes at the current position.
    private var qualityMenu: some View {
        Menu {
            Picker("画質", selection: Binding(
                get: { model.playback.profile.quality },
                set: { model.playback.switchQuality($0) }
            )) {
                ForEach(StreamQuality.videoQualities, id: \.self) { quality in
                    Text(quality.displayName).tag(quality)
                }
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .accessibilityIdentifier("player.quality")
        .accessibilityLabel("画質")
    }

    // MARK: - Views

    @ViewBuilder
    private var playerArea: some View {
        if model.playback.item == playbackItem, model.playback.isPlayerAttached {
            PlayerView(playback: model.playback)
        } else {
            ZStack {
                Color.black
                ProgressView()
                    .tint(.white)
            }
        }
    }

    @ViewBuilder
    private var sceneStrip: some View {
        if let client = model.client,
           let tile = current.recordedVideo.thumbnailInfo?.tile {
            VideoSceneStrip(
                playback: model.playback,
                videoID: current.id,
                tile: tile,
                client: client
            )
        }
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 12) {
            panelTabPicker

            switch panelTab {
            case .recordedProgram:
                programInfo
            case .comment:
                commentTab
            case .twitter:
                twitterPanel
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var panelTabPicker: some View {
        HStack(spacing: 2) {
            panelTabButton(.recordedProgram, identifier: "video.panel.program")
            panelTabButton(.comment, identifier: "video.panel.comment")
            panelTabButton(.twitter, identifier: "video.panel.twitter")
        }
        .padding(2)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
    }

    private func panelTabButton(_ tab: VideoPanelTab, identifier: String) -> some View {
        Button {
            panelTab = tab
        } label: {
            Text(tab.displayName)
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
    private var twitterPanel: some View {
        if let twitterSession {
            TwitterPanelView(
                model: model,
                session: twitterSession,
                context: TwitterPanelContext(
                    channelName: nil,
                    programTitle: current.title,
                    programID: nil
                )
            )
        } else {
            ProgressView()
                .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var commentTab: some View {
        if let commentSession {
            CommentListPanel(
                title: "コメント",
                comments: commentSession.visibleComments,
                statusMessage: commentSession.statusMessage,
                height: 360,
                onMuteUser: { userID in
                    model.addMutedNiconicoUser(userID)
                    commentSession.removeComments(from: userID)
                }
            )
        } else {
            Text("コメントはありません")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    /// The program information tab.
    private var programInfo: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(current.title)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("video.detail.title")

                Button {
                    model.toggleMylist(videoID: video.id)
                } label: {
                    Image(systemName: isInMylist ? "bookmark.fill" : "bookmark")
                        .font(.title3)
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("video.mylist")
                .accessibilityLabel(isInMylist ? "マイリストから削除" : "マイリストに追加")
            }

            HStack(spacing: 8) {
                if let channel = current.channel {
                    Text(channel.name)
                }
                Text(Formatters.dateTime(current.startTime))
                Text("・")
                Text(Formatters.duration(current.duration))
            }
            .font(.footnote)
            .foregroundStyle(.secondary)

            if !current.genres.isEmpty {
                Text(current.genres.map { "\($0.major)／\($0.middle)" }.joined(separator: "・"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if isDownloading {
                ProgressView(value: downloadProgress)
                    .accessibilityIdentifier("video.downloadProgress")
                    .accessibilityLabel("ダウンロード中")
            }

            offlineStatus

            if isWorking {
                ProgressView()
                    .controlSize(.small)
            }

            if let actionMessage {
                Text(actionMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if !current.description.isEmpty {
                Text(current.description)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !seriesEpisodes.isEmpty {
                seriesSection
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Offline save state of this program: progress with a cancel button, the
    /// failure with a retry, or the saved quality and size.
    @ViewBuilder
    private var offlineStatus: some View {
        if let job = model.offline.activeJob(videoID: current.id) {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: job.progress)
                    .accessibilityIdentifier("video.offline.progress")
                    .accessibilityLabel("オフライン保存中")
                    .accessibilityValue(Formatters.percent(job.progress))

                HStack {
                    Text("\(job.qualityLabel)・\(Formatters.percent(job.progress))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button("キャンセル", role: .destructive) {
                        model.offline.cancel(jobID: job.jobID)
                    }
                    .font(.footnote)
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("video.offline.cancel")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let failed = model.offline.failedJob(videoID: current.id) {
            VStack(alignment: .leading, spacing: 6) {
                Text(failed.error ?? "オフライン保存に失敗しました。")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("video.offline.error")

                if let client = model.client {
                    Button("再試行") {
                        model.offline.retry(jobID: failed.jobID, client: client)
                    }
                    .font(.footnote)
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("video.offline.retry")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let saved = model.offline.video(id: current.id) {
            Label(
                "オフライン保存済み (\(saved.qualityLabel)・\(saved.sizeLabel))",
                systemImage: "arrow.down.circle.fill"
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("video.offline.saved")
        }
    }

    private var seriesEpisodes: [RecordedProgram] {
        guard let series else { return [] }
        var seen: Set<Int> = [video.id]
        return series.allRecordedPrograms.filter { episode in
            guard !seen.contains(episode.id) else { return false }
            seen.insert(episode.id)
            return true
        }
    }

    private var seriesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let series {
                NavigationLink(value: SectionRoute.series(series.id)) {
                    HStack(spacing: 6) {
                        Text("シリーズ")
                            .font(.headline)
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("video.series.link")
            } else {
                Text("シリーズ")
                    .font(.headline)
            }

            ForEach(seriesEpisodes) { episode in
                NavigationLink(value: SectionRoute.video(episode)) {
                    HStack(spacing: 8) {
                        if let number = episode.episodeNumber, !number.isEmpty {
                            Text(number)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(episode.title)
                            .font(.subheadline)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Text(Formatters.date(episode.startTime))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Keyboard shortcuts

    /// iPadOS lists these while ⌘ is held. Space, arrows, mute, restart, full
    /// screen and PiP only exist on player screens, so they live here.
    private var playerShortcuts: some View {
        Group {
            shortcut(.space, action: model.playback.togglePlayPause)
            shortcut(.leftArrow, action: { model.playback.seek(by: -5) })
            shortcut(.rightArrow, action: { model.playback.seek(by: 5) })
            shortcut(.leftArrow, modifiers: [.command], action: { model.playback.seek(by: -15) })
            shortcut(.rightArrow, modifiers: [.command], action: { model.playback.seek(by: 15) })
            shortcut(.leftArrow, modifiers: [.shift], action: { model.playback.seek(by: -30) })
            shortcut(.rightArrow, modifiers: [.shift], action: { model.playback.seek(by: 30) })
            shortcut(.leftArrow, modifiers: [.option], action: { model.playback.seek(by: -60) })
            shortcut(.rightArrow, modifiers: [.option], action: { model.playback.seek(by: 60) })
            shortcut("q", action: model.playback.toggleMute)
            shortcut("r", action: model.playback.restart)
            shortcut("d", action: model.playback.comments.toggleVisibility)
            shortcut("s", action: model.playback.captions.toggleVisibility)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

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

    // MARK: - Loading

    private func startPlayback() {
        guard let client = model.client else { return }
        model.playback.play(
            playbackItem,
            client: client,
            profile: QualityPreferences.videoProfile(cellular: model.networkMonitor.isCellular),
            startAt: model.resumePosition(for: video)
        )
    }

    /// Creates the Twitter panel session once per screen.
    private func startTwitter() {
        guard twitterSession == nil else { return }
        let session = TwitterSession(model: model, playback: model.playback)
        session.onFoldPanel = {}
        twitterSession = session
    }

    /// Loads the past log comments of the recording (step 2 of the comment
    /// feature) and lets `RecordedCommentSession` feed the overlay while the
    /// playback position advances.
    private func startComments() {
        commentSession?.stop()
        commentSession = nil
        guard let client = model.client else { return }

        let session = RecordedCommentSession(
            video: video,
            model: model,
            client: client,
            overlay: model.playback.comments
        )
        commentSession = session
        session.start()
    }

    private func loadDetail() async {
        guard let client = model.client else { return }

        if let loaded = try? await client.video(id: video.id) {
            detail = loaded
        }

        guard let seriesID = (detail ?? video).seriesID else { return }
        guard let loaded = try? await client.series(id: seriesID) else { return }
        series = loaded
    }

    // MARK: - Actions

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard !isWorking else { return }
        isWorking = true
        actionMessage = nil

        Task {
            defer { isWorking = false }
            do {
                try await action()
            } catch {
                actionMessage = ErrorText.message(for: error)
            }
        }
    }

    private func reanalyze() {
        guard let client = model.client else { return }
        let videoID = current.id
        perform {
            try await client.reanalyzeVideo(id: videoID)
        }
    }

    private func regenerateThumbnail() {
        guard let client = model.client else { return }
        let videoID = current.id
        perform {
            try await client.regenerateThumbnail(id: videoID)
        }
    }

    private func deleteVideo() {
        guard let client = model.client else { return }
        let videoID = current.id

        perform {
            try await client.deleteVideo(id: videoID)
            model.markVideoDeleted(id: videoID)
            model.removeFromMylist(videoID: videoID)
            model.removeWatchedHistory(videoID: videoID)
            model.playback.stop()
            dismiss()
        }
    }

    private func startDownload() {
        guard let client = model.client, !isDownloading else { return }
        isDownloading = true
        downloadProgress = 0
        actionMessage = nil

        Task {
            defer { isDownloading = false }
            do {
                let file = try await VideoFileDownload.download(
                    video: current,
                    client: client,
                    progress: { value in
                        downloadProgress = value
                    }
                )
                activeSheet = .share(file)
            } catch {
                actionMessage = ErrorText.message(for: error)
            }
        }
    }
}

/// Sheets of the video detail screen.
private enum VideoDetailSheet: Identifiable {
    case fileInfo
    case share(DownloadedFile)
    case offline

    var id: String {
        switch self {
        case .fileInfo: return "fileInfo"
        case .share(let file): return "share-\(file.id.uuidString)"
        case .offline: return "offline"
        }
    }
}

/// 録画ファイル情報: the file, video and audio information of a recording
/// (mirrors the web client's RecordedFileInfoDialog).
struct RecordedFileInfoSheet: View {
    let program: RecordedProgram

    @Environment(\.dismiss) private var dismiss

    private var video: RecordedVideo { program.recordedVideo }

    var body: some View {
        NavigationStack {
            List {
                Section("ファイル情報") {
                    LabeledContent("ファイルパス", value: video.filePath ?? "不明")
                    LabeledContent("ファイルサイズ", value: Formatters.bytes(video.fileSize))
                    LabeledContent("録画期間", value: recordingTime)
                    LabeledContent("最終更新日時", value: dateTime(video.fileModifiedAt ?? video.fileCreatedAt))
                }

                Section("映像情報") {
                    LabeledContent("コーデック", value: codec)
                    LabeledContent("解像度", value: "\(video.videoResolutionWidth)×\(video.videoResolutionHeight)")
                    LabeledContent("フレームレート", value: frameRate)
                    LabeledContent("スキャン方式", value: video.videoScanType ?? "不明")
                }

                Section("音声情報（主音声）") {
                    LabeledContent("コーデック", value: video.primaryAudioCodec ?? "不明")
                    LabeledContent("チャンネル", value: video.primaryAudioChannel ?? "不明")
                    LabeledContent("サンプリングレート", value: samplingRate(video.primaryAudioSamplingRate))
                }

                if let secondaryAudioCodec = video.secondaryAudioCodec, !secondaryAudioCodec.isEmpty {
                    Section("音声情報（副音声）") {
                        LabeledContent("コーデック", value: secondaryAudioCodec)
                        LabeledContent("チャンネル", value: video.secondaryAudioChannel ?? "不明")
                        LabeledContent(
                            "サンプリングレート",
                            value: samplingRate(video.secondaryAudioSamplingRate)
                        )
                    }
                }
            }
            .navigationTitle("録画ファイル情報")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                SheetCloseButton { dismiss() }
            }
        }
    }

    private var codec: String {
        guard let profile = video.videoCodecProfile, !profile.isEmpty else {
            return video.videoCodec
        }
        return "\(video.videoCodec) (\(profile))"
    }

    private var frameRate: String {
        guard let rate = video.videoFrameRate else { return "不明" }
        return String(format: "%.2f fps", rate)
    }

    private var recordingTime: String {
        guard let start = video.recordingStartTime, let end = video.recordingEndTime else {
            return "不明"
        }
        return "\(Formatters.dateTime(start))〜\(Formatters.time(end))"
    }

    private func dateTime(_ date: Date?) -> String {
        guard let date else { return "不明" }
        return Formatters.dateTime(date)
    }

    private func samplingRate(_ rate: Int?) -> String {
        guard let rate, rate > 0 else { return "不明" }
        return String(format: "%.1fkHz", Double(rate) / 1000)
    }
}

/// Forwards the playback position and play state from a view of its own.
///
/// Reading `positionSeconds` in a screen's body re-evaluates the whole screen
/// every second while playing, toolbar included, and a toolbar Menu that is
/// rebuilt closes under the user's finger.
struct PlaybackProgressObserver: View {
    let playback: PlaybackController
    let onChange: (_ position: Double, _ isPlaying: Bool) -> Void

    var body: some View {
        Color.clear
            .accessibilityHidden(true)
            .onChange(of: playback.positionSeconds) { _, position in
                onChange(Double(position), playback.isPlaying)
            }
            .onChange(of: playback.isPlaying) { _, isPlaying in
                onChange(Double(playback.positionSeconds), isPlaying)
            }
    }
}
