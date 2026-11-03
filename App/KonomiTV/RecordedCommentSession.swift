import Foundation
import KonomiKit
import Observation

/// Past log comments of a recorded program (`GET /api/videos/{id}/jikkyo`).
///
/// The comments are loaded when playback starts, muted ones are dropped and
/// the rest is emitted to the overlay when the playback position passes their
/// time. The panel list shows the comments up to the current position. Large
/// position jumps (seeks) re-sync the cursor instead of drawing the whole
/// skipped range, and nothing is drawn while playback is paused.
@MainActor
@Observable
final class RecordedCommentSession {
    /// Where the past log comments come from.
    private enum Source {
        /// `GET /api/videos/{id}/jikkyo`.
        case api(APIClient)
        /// Comments saved with an offline video.
        case stored(JikkyoComments)
    }

    private let video: RecordedProgram
    private let model: AppModel
    private let source: Source
    private let overlay: CommentOverlayModel

    /// Comments up to the current playback position.
    private(set) var visibleComments: [CommentRow] = []
    private(set) var statusMessage: String?

    @ObservationIgnored private var allRows: [CommentRow] = []
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var nextIndex = 0
    @ObservationIgnored private var visibleCount = 0
    @ObservationIgnored private var lastPosition: Double = 0
    @ObservationIgnored private var isLoaded = false
    @ObservationIgnored private var isStopped = false

    /// A position jump larger than this is treated as a seek.
    private static let forwardSeekThreshold: Double = 4
    private static let backwardSeekThreshold: Double = -1.5

    init(
        video: RecordedProgram,
        model: AppModel,
        client: APIClient,
        overlay: CommentOverlayModel
    ) {
        self.video = video
        self.model = model
        self.source = .api(client)
        self.overlay = overlay
    }

    /// Plays back the comments stored with an offline video instead of
    /// fetching them (the offline library saved `jikkyo.json`).
    init(
        video: RecordedProgram,
        model: AppModel,
        comments: JikkyoComments,
        overlay: CommentOverlayModel
    ) {
        self.video = video
        self.model = model
        self.source = .stored(comments)
        self.overlay = overlay
    }

    func start() {
        guard !isStopped, loadTask == nil else { return }
        isStopped = false
        loadTask = Task { await self.load() }
    }

    func stop() {
        isStopped = true
        loadTask?.cancel()
        loadTask = nil
    }

    // MARK: - Loading

    private func load() async {
        let result: JikkyoComments
        switch source {
        case .api(let client):
            do {
                result = try await client.pastComments(videoID: video.id)
            } catch {
                guard !isStopped else { return }
                statusMessage = "過去ログコメントを取得できませんでした。"
                return
            }
        case .stored(let comments):
            result = comments
        }
        guard !Task.isCancelled, !isStopped else { return }

        let options = CommentMuteFilter.Options(settings: model.settings)
        let recordingStartTime = video.recordedVideo.recordingStartTime
        var rows: [CommentRow] = []
        var identifier = 0

        for comment in result.comments.sorted(by: { $0.time < $1.time }) {
            guard !CommentMuteFilter.isMuted(comment, options: options) else { continue }
            identifier += 1
            let date = recordingStartTime?.addingTimeInterval(comment.time)
            rows.append(
                CommentRow(
                    id: identifier,
                    danmaku: CommentDanmaku(pastComment: comment),
                    displayTime: date.map {
                        Formatters.clock($0, use28HourClock: model.settings.use28HourClock)
                    } ?? Formatters.offset(comment.time)
                )
            )
        }

        allRows = rows
        isLoaded = true
        if !result.isSuccess, rows.isEmpty, !result.detail.isEmpty {
            statusMessage = result.detail
        }

        // Start from the current playback position (watch history resume) and
        // do not draw the comments before it.
        let position = currentPosition
        lastPosition = position
        nextIndex = upperBound(position)
        visibleCount = nextIndex
        visibleComments = Array(allRows.prefix(visibleCount))
        overlay.clear()
    }

    // MARK: - Playback position

    /// Called for every playback position tick (and when play / pause changes).
    func update(position: Double, isPlaying: Bool) {
        guard isLoaded else { return }

        let jump = position - lastPosition
        lastPosition = position

        if jump < Self.backwardSeekThreshold || jump > Self.forwardSeekThreshold {
            // Seek: move the cursor, drop what is on screen and do not draw the
            // comments of the skipped range.
            nextIndex = upperBound(position)
            overlay.clear()
            refreshVisibleComments(position)
            return
        }

        if isPlaying {
            while nextIndex < allRows.count, allRows[nextIndex].danmaku.time <= position {
                let danmaku = allRows[nextIndex].danmaku
                if !model.settings.mutedNiconicoUserIDs.contains(danmaku.authorID) {
                    overlay.emit(danmaku)
                }
                nextIndex += 1
            }
        }

        refreshVisibleComments(position)
    }

    /// Removes a muted user's comments (the panel's context menu).
    func removeComments(from authorID: String) {
        guard !authorID.isEmpty else { return }
        let position = lastPosition
        allRows.removeAll { $0.authorID == authorID }
        nextIndex = upperBound(position)
        refreshVisibleComments(position)
    }

    private var currentPosition: Double {
        Double(model.playback.positionSeconds)
    }

    private func refreshVisibleComments(_ position: Double) {
        let count = upperBound(position)
        guard count != visibleCount else { return }
        visibleCount = count
        visibleComments = Array(allRows.prefix(count))
    }

    /// Index of the first comment later than `position`.
    private func upperBound(_ position: Double) -> Int {
        var low = 0
        var high = allRows.count
        while low < high {
            let middle = (low + high) / 2
            if allRows[middle].danmaku.time <= position {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }
}
