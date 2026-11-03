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

    private var current: RecordedProgram { detail ?? video }

    private var playbackItem: PlaybackItem { .video(video) }

    private var isInMylist: Bool { model.isInMylist(videoID: video.id) }

    private var isAdmin: Bool { model.user?.isAdmin == true }

    private var isRecording: Bool { current.recordedVideo.status == "Recording" }

    var body: some View {
        AdaptivePlayerLayout(
            player: { playerArea },
            belowPlayer: { sceneStrip },
            info: { info }
        )
        .navigationTitle(current.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .task { startPlayback() }
        .task { await loadDetail() }
        .onAppear { model.playback.viewAppeared(for: playbackItem) }
        .onDisappear { model.playback.viewDisappeared(for: playbackItem) }
        .background(playerShortcuts)
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .fileInfo:
                RecordedFileInfoSheet(program: current)
            case .share(let file):
                ShareSheet(url: file.url)
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
            qualityMenu

            Button {
                model.toggleMylist(videoID: video.id)
            } label: {
                Image(systemName: isInMylist ? "bookmark.fill" : "bookmark")
            }
            .accessibilityIdentifier("video.mylist")
            .accessibilityLabel(isInMylist ? "マイリストから削除" : "マイリストに追加")

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
            ForEach(StreamQuality.videoQualities, id: \.self) { quality in
                Button {
                    model.playback.switchQuality(quality)
                } label: {
                    if model.playback.profile.quality == quality {
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
            Text(current.title)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("video.detail.title")

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
            Text("シリーズ")
                .font(.headline)

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

    var id: String {
        switch self {
        case .fileInfo: return "fileInfo"
        case .share(let file): return "share-\(file.id.uuidString)"
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
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") {
                        dismiss()
                    }
                }
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
