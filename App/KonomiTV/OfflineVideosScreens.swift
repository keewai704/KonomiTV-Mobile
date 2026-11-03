import SwiftUI
import UIKit
import KonomiKit

// MARK: - List

/// オフライン: the saved videos, the running jobs and the storage they use.
///
/// The screen renders from `OfflineVideoManager` only, so it works with no
/// network and no server session.
struct OfflineVideosScreen: View {
    let model: AppModel

    @State private var pendingDeletion: OfflineVideo?
    @State private var showsDeleteConfirmation = false

    private var manager: OfflineVideoManager { model.offline }

    var body: some View {
        List {
            storageSection

            if !manager.activeJobs.isEmpty {
                Section("保存中") {
                    ForEach(manager.activeJobs) { job in
                        activeJobRow(job)
                    }
                }
            }

            if !manager.failedJobs.isEmpty {
                Section("保存できませんでした") {
                    ForEach(manager.failedJobs) { job in
                        failedJobRow(job)
                    }
                }
            }

            savedSection
        }
        .accessibilityIdentifier("offline.list")
        .navigationTitle("オフライン")
        .task { manager.refreshStorageUsage() }
        .confirmationDialog(
            "オフライン保存を削除しますか？",
            isPresented: $showsDeleteConfirmation,
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { video in
            Button("削除", role: .destructive) {
                manager.delete(videoID: video.videoID)
            }
            .accessibilityIdentifier("offline.delete.confirm")

            Button("キャンセル", role: .cancel) {}
        }
    }

    // MARK: Storage

    private var storageSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent("保存済み") {
                    Text(OfflineQualityEstimate.formatOfflineSize(
                        bytes: manager.storageUsageBytes,
                        approximate: false
                    ))
                }
                if let available = manager.availableCapacityBytes {
                    LabeledContent("空き容量") {
                        Text(OfflineQualityEstimate.formatOfflineSize(
                            bytes: Int(max(available, 0)),
                            approximate: false
                        ))
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("offline.storage")
        }
    }

    // MARK: Jobs

    private func activeJobRow(_ job: OfflineDownloadJob) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(job.program.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)

            ProgressView(value: job.progress)
                .accessibilityIdentifier("video.offline.progress")
                .accessibilityLabel("オフライン保存中")
                .accessibilityValue(Formatters.percent(job.progress))

            HStack {
                Text("\(job.qualityLabel)・\(Formatters.percent(job.progress))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("キャンセル", role: .destructive) {
                    manager.cancel(jobID: job.jobID)
                }
                .font(.caption)
                .buttonStyle(.borderless)
                .accessibilityIdentifier("video.offline.cancel")
            }
        }
        .padding(.vertical, 2)
    }

    private func failedJobRow(_ job: OfflineDownloadJob) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(job.program.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)

            Text(job.error ?? "オフライン保存に失敗しました。")
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("video.offline.error")

            HStack(spacing: 16) {
                Button("再試行") {
                    retry(job)
                }
                .font(.caption)
                .buttonStyle(.borderless)
                .accessibilityIdentifier("video.offline.retry")

                Button("閉じる") {
                    manager.dismiss(jobID: job.jobID)
                }
                .font(.caption)
                .buttonStyle(.borderless)
                .accessibilityIdentifier("video.offline.dismiss")
            }
        }
        .padding(.vertical, 2)
    }

    private func retry(_ job: OfflineDownloadJob) {
        guard let client = model.client else { return }
        manager.retry(jobID: job.jobID, client: client)
    }

    // MARK: Saved videos

    @ViewBuilder
    private var savedSection: some View {
        Section("保存済み") {
            if manager.videos.isEmpty {
                Text("オフライン保存した番組はありません。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(manager.videos) { video in
                    NavigationLink(value: SectionRoute.offline(video.program)) {
                        OfflineVideoRow(model: model, video: video)
                    }
                    .accessibilityIdentifier("offline.video.\(video.videoID)")
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            pendingDeletion = video
                            showsDeleteConfirmation = true
                        } label: {
                            Label("削除", systemImage: "trash")
                        }
                        .accessibilityIdentifier("offline.video.\(video.videoID).delete")
                    }
                }
            }
        }
    }
}

/// One saved video: its stored thumbnail, title, quality and size.
struct OfflineVideoRow: View {
    let model: AppModel
    let video: OfflineVideo

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            OfflineThumbnailView(url: model.offline.thumbnailURL(for: video))
                .frame(width: 96)

            VStack(alignment: .leading, spacing: 4) {
                Text(video.program.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)

                Text("\(video.qualityLabel)・\(video.sizeLabel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("\(Formatters.dateTime(video.program.startTime))・\(Formatters.duration(video.program.duration))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Thumbnail read from the saved video's assets (AsyncImage cannot read
/// `file://` URLs).
struct OfflineThumbnailView: View {
    let url: URL?

    @State private var image: UIImage?

    var body: some View {
        Color.secondary.opacity(0.12)
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "film")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .task(id: url) {
                image = url.flatMap { UIImage(contentsOfFile: $0.path) }
            }
    }
}

// MARK: - Player

/// Plays a saved video through the loopback server: no server, no network.
///
/// The screen only needs the video ID; the record (and its segments) come from
/// the offline library, so a saved program still plays after its server deleted
/// the recording.
struct OfflineVideoPlayerView: View {
    let model: AppModel
    let program: RecordedProgram

    @State private var content: OfflineVideo?
    @State private var isMissing = false
    @State private var commentSession: RecordedCommentSession?

    private var playbackItem: PlaybackItem { .offline(program) }

    var body: some View {
        AdaptivePlayerLayout(
            player: { playerArea },
            belowPlayer: { EmptyView() },
            info: { info }
        )
        .navigationTitle(program.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { startPlayback() }
        .onAppear {
            model.playback.comments.apply(settings: model.settings)
            model.playback.viewAppeared(for: playbackItem)
        }
        .onDisappear {
            commentSession?.stop()
            commentSession = nil
            model.playback.viewDisappeared(for: playbackItem)
        }
        .onChange(of: model.playback.positionSeconds) { _, value in
            commentSession?.update(
                position: Double(value),
                isPlaying: model.playback.isPlaying
            )
        }
        .onChange(of: model.playback.isPlaying) { _, value in
            commentSession?.update(
                position: Double(model.playback.positionSeconds),
                isPlaying: value
            )
        }
    }

    @ViewBuilder
    private var playerArea: some View {
        if isMissing {
            ZStack {
                Color.black
                ContentUnavailableView {
                    Label("保存済みのデータが見つかりません", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("オフライン保存を削除したか、端末からデータが失われました。")
                }
                .foregroundStyle(.white)
            }
        } else if model.playback.item == playbackItem, model.playback.isPlayerAttached {
            PlayerView(playback: model.playback)
        } else {
            ZStack {
                Color.black
                ProgressView()
                    .tint(.white)
            }
        }
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(program.title)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("offline.player.title")

            HStack(spacing: 8) {
                if let channel = program.channel {
                    Text(channel.name)
                }
                Text(Formatters.dateTime(program.startTime))
                Text("・")
                Text(Formatters.duration(program.duration))
            }
            .font(.footnote)
            .foregroundStyle(.secondary)

            if let content {
                Text("\(content.qualityLabel)・\(content.sizeLabel)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if !program.description.isEmpty {
                Text(program.description)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func startPlayback() {
        guard let video = model.offline.video(id: program.id) else {
            isMissing = true
            return
        }
        content = video
        model.playback.playOffline(
            video,
            directory: model.offline.playbackDirectory(for: video),
            startAt: model.resumePosition(for: program)
        )
        startComments(videoID: video.videoID)
    }

    /// The past log comments were saved with the video, so they play back
    /// without the server.
    private func startComments(videoID: Int) {
        commentSession?.stop()
        commentSession = nil
        guard let comments = model.offline.storedComments(videoID: videoID) else { return }
        let session = RecordedCommentSession(
            video: program,
            model: model,
            comments: comments,
            overlay: model.playback.comments
        )
        commentSession = session
        session.start()
    }
}

// MARK: - Save sheet

/// オフライン保存: pick the quality (with its size estimate) and start the save.
///
/// Tapping a quality row starts the save, like the web client's
/// "ダウンロード開始" after choosing from its select.
struct OfflineSaveSheet: View {
    let model: AppModel
    let program: RecordedProgram

    @Environment(\.dismiss) private var dismiss

    @State private var dataSaver = false
    @State private var use24fps = false
    @State private var errorMessage: String?
    @State private var isStarting = false
    @State private var hasAppliedDefaults = false

    private var job: OfflineDownloadJob? { model.offline.activeJob(videoID: program.id) }
    private var savedVideo: OfflineVideo? { model.offline.video(id: program.id) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let job {
                        ProgressView(value: job.progress)
                            .accessibilityIdentifier("video.offline.progress")
                            .accessibilityLabel("オフライン保存中")
                            .accessibilityValue(Formatters.percent(job.progress))
                    } else if let savedVideo {
                        LabeledContent("保存済み") {
                            Text("\(savedVideo.qualityLabel)・\(savedVideo.sizeLabel)")
                        }
                    } else {
                        Text("オフライン再生用に保存します。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Toggle("通信節約モード (H.265 / HEVC)", isOn: $dataSaver)
                        .accessibilityIdentifier("video.offline.dataSaver")

                    ForEach(OfflineQualityEstimate.baseQualities, id: \.self) { quality in
                        Button {
                            start(quality)
                        } label: {
                            HStack {
                                Text(OfflineQualityEstimate.formatQualitySelectLabel(
                                    base: quality,
                                    durationSeconds: program.recordedVideo.duration,
                                    dataSaver: dataSaver
                                ))
                                Spacer(minLength: 8)
                            }
                            .contentShape(Rectangle())
                        }
                        .disabled(isStarting || job != nil)
                        .accessibilityIdentifier("video.offline.quality.\(quality.rawValue)")
                    }
                } header: {
                    Text("保存画質")
                } footer: {
                    if let errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("video.offline.error")
                    }
                }
            }
            .navigationTitle("オフライン保存")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") {
                        dismiss()
                    }
                }
            }
            .task {
                guard !hasAppliedDefaults else { return }
                hasAppliedDefaults = true
                let profile = QualityPreferences.videoProfile(
                    cellular: model.networkMonitor.isCellular
                )
                dataSaver = profile.dataSaver
                use24fps = profile.use24fps
            }
        }
    }

    private func start(_ quality: StreamQuality) {
        guard let client = model.client else {
            errorMessage = "サーバーに接続できません。"
            return
        }
        isStarting = true
        errorMessage = nil
        do {
            try model.offline.start(
                program: program,
                client: client,
                apiQuality: OfflineQualityEstimate.apiQuality(
                    base: quality,
                    dataSaver: dataSaver,
                    use24fps: use24fps
                )
            )
            dismiss()
        } catch {
            errorMessage = ErrorText.message(for: error)
        }
        isStarting = false
    }
}
