import Foundation
import Observation
import UIKit
import KonomiKit

// MARK: - Errors

/// Failures of an offline save that the UI shows as the job's error.
enum OfflineVideoError: LocalizedError, Sendable, Equatable {
    case alreadySaving
    case unsupportedQuality(String)
    case insufficientSpace(required: Int, available: Int64)
    case httpStatus(Int)
    case metadataMismatch
    case emptyStream
    case interrupted

    var errorDescription: String? {
        switch self {
        case .alreadySaving:
            return "この録画番組はすでにオフライン保存中です。"
        case .unsupportedQuality(let quality):
            return "オフライン保存に対応していない画質です。(\(quality))"
        case .insufficientSpace(let required, let available):
            let requiredLabel = OfflineQualityEstimate.formatOfflineSize(bytes: required, approximate: true)
            let availableLabel = OfflineQualityEstimate.formatOfflineSize(
                bytes: Int(max(available, 0)),
                approximate: true
            )
            return "オフライン保存に必要な空き容量が不足しています。必要: \(requiredLabel) / 空き: \(availableLabel)"
        case .httpStatus(let status):
            switch status {
            case 404:
                return "このサーバーはオフライン保存に対応していません。"
            case 409:
                return "録画中の番組はオフライン保存できません。"
            case 401, 403:
                return "オフライン保存にはログインが必要です。"
            default:
                return "オフライン保存 API が HTTP \(status) を返しました。"
            }
        case .metadataMismatch:
            return "オフライン保存データが保存ジョブと一致しません。"
        case .emptyStream:
            return "オフライン保存データに映像セグメントがありません。"
        case .interrupted:
            return "アプリが終了したため、オフライン保存が中断されました。"
        }
    }
}

// MARK: - Manager

/// Owns the offline save jobs, the saved videos on disk and their storage use.
///
/// Layout under `Application Support/OfflineVideos`:
///
///     videos.json                      saved video records
///     jobs.json                        running / failed / finished jobs
///     <video_id>/playlist.m3u8         finished VOD playlist
///     <video_id>/segments/<n>.ts       segments exactly as the server sent them
///     <video_id>/assets/thumbnail      list thumbnail (no network needed)
///     <video_id>/assets/jikkyo.json    past log comments of the recording
///     <video_id>.tmp/                  staging directory of a running save
///
/// The staging directory is moved into place only after the playlist is
/// written, so a half saved program never looks finished. `-UITesting`
/// launches delete the whole directory (see `removeAllStorage()`).
@MainActor
@Observable
final class OfflineVideoManager {
    /// Saved videos, newest first.
    private(set) var videos: [OfflineVideo] = []
    /// Running, failed and finished save jobs, newest first.
    private(set) var jobs: [OfflineDownloadJob] = []
    /// Bytes the saved videos occupy.
    private(set) var storageUsageBytes = 0
    /// Free space of the volume (`volumeAvailableCapacityForImportantUsage`).
    private(set) var availableCapacityBytes: Int64?

    /// Directory name below Application Support.
    nonisolated static let storageDirectoryName = "OfflineVideos"
    /// KonomiTV segments recorded videos into about 2 seconds, which is the
    /// expected segment count before the first segment tells us more.
    nonisolated static let defaultSegmentDurationSeconds: Double = 2
    /// Interval of the storage usage refresh while a save is running.
    private nonisolated static let progressPersistenceInterval: TimeInterval = 5

    @ObservationIgnored private let rootURL: URL
    @ObservationIgnored private var downloadTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var lastProgressPersistence: [String: Date] = [:]

    // MARK: - Paths

    /// Root of the offline library.
    nonisolated static var storeRootURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent(storageDirectoryName, isDirectory: true)
    }

    /// Deletes the whole offline library (the `-UITesting` launch hook).
    nonisolated static func removeAllStorage() {
        try? FileManager.default.removeItem(at: storeRootURL)
    }

    init(rootURL: URL = OfflineVideoManager.storeRootURL) {
        self.rootURL = rootURL
        createRootDirectory()
        loadState()
        recoverInterruptedJobs()
        refreshStorageUsage()
    }

    private func directory(for videoID: Int) -> URL {
        rootURL.appendingPathComponent(String(videoID), isDirectory: true)
    }

    private func stagingDirectory(for videoID: Int) -> URL {
        rootURL.appendingPathComponent("\(videoID).tmp", isDirectory: true)
    }

    private var videosIndexURL: URL {
        rootURL.appendingPathComponent("videos.json")
    }

    private var jobsIndexURL: URL {
        rootURL.appendingPathComponent("jobs.json")
    }

    private func createRootDirectory() {
        var url = rootURL
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // Saved videos are several gigabytes; they must not be part of an
        // iCloud backup.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    // MARK: - Persistence

    private func loadState() {
        if let data = try? Data(contentsOf: videosIndexURL),
           let loaded = try? JSONCoding.decode([OfflineVideo].self, from: data) {
            videos = loaded
                .filter { FileManager.default.fileExists(atPath: playlistURL(for: $0).path) }
                .sorted { $0.savedAt > $1.savedAt }
        }
        if let data = try? Data(contentsOf: jobsIndexURL),
           let loaded = try? JSONCoding.decode([OfflineDownloadJob].self, from: data) {
            // Finished saves are represented by the video record; only
            // running and failed jobs need a row.
            jobs = loaded
                .filter { $0.state != .cancelled && $0.state != .completed }
                .sorted { $0.createdAt > $1.createdAt }
        }
    }

    /// A job that was still active when the app last quit can never finish:
    /// its connection is gone. Mark it failed and drop its partial data, which
    /// is what the web client's recovery does after a closed page.
    private func recoverInterruptedJobs() {
        var changed = false
        for index in jobs.indices where jobs[index].state.isActive {
            jobs[index].state = .failed
            jobs[index].error = OfflineVideoError.interrupted.localizedDescription
            jobs[index].updatedAt = Date()
            removeStagingDirectory(for: jobs[index].videoID)
            changed = true
        }
        if changed {
            persistJobs()
        }
    }

    private func persistVideos() {
        guard let data = try? JSONCoding.encode(videos) else { return }
        try? data.write(to: videosIndexURL, options: .atomic)
    }

    private func persistJobs() {
        guard let data = try? JSONCoding.encode(jobs) else { return }
        try? data.write(to: jobsIndexURL, options: .atomic)
    }

    /// Re-reads the saved size and the free space of the volume.
    func refreshStorageUsage() {
        storageUsageBytes = videos.reduce(0) { $0 + $1.sizeBytes }
        let values = try? rootURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        availableCapacityBytes = values?.volumeAvailableCapacityForImportantUsage
    }

    // MARK: - Queries

    /// Whether anything is saved or a job is shown (keeps the section reachable
    /// while the server is unreachable).
    var hasContent: Bool {
        !videos.isEmpty || jobs.contains { $0.state != .cancelled }
    }

    var activeJobs: [OfflineDownloadJob] {
        jobs.filter { $0.state.isActive }
    }

    var failedJobs: [OfflineDownloadJob] {
        jobs.filter { $0.state == .failed }
    }

    func video(id: Int) -> OfflineVideo? {
        videos.first { $0.videoID == id }
    }

    func activeJob(videoID: Int) -> OfflineDownloadJob? {
        jobs.first { $0.videoID == videoID && $0.state.isActive }
    }

    func failedJob(videoID: Int) -> OfflineDownloadJob? {
        jobs.first { $0.videoID == videoID && $0.state == .failed }
    }

    /// Directory the loopback server serves a saved video from.
    func playbackDirectory(for video: OfflineVideo) -> URL {
        directory(for: video.videoID)
    }

    /// Saved list thumbnail, read from disk (no network needed).
    func thumbnailURL(for video: OfflineVideo) -> URL? {
        let url = directory(for: video.videoID)
            .appendingPathComponent("assets", isDirectory: true)
            .appendingPathComponent("thumbnail")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Past log comments stored with a saved video.
    func storedComments(videoID: Int) -> JikkyoComments? {
        let url = directory(for: videoID)
            .appendingPathComponent("assets", isDirectory: true)
            .appendingPathComponent("jikkyo.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONCoding.decode(JikkyoComments.self, from: data)
    }

    private func playlistURL(for video: OfflineVideo) -> URL {
        directory(for: video.videoID).appendingPathComponent("playlist.m3u8")
    }

    // MARK: - Starting a save

    /// Starts saving a recorded program.
    ///
    /// The free space check uses the bitrate ceiling (the web client's
    /// `estimateRequiredStorageBytes`), so the save does not run out of disk
    /// halfway through.
    @discardableResult
    func start(
        program: RecordedProgram,
        client: APIClient,
        apiQuality: String
    ) throws -> OfflineDownloadJob {
        if activeJob(videoID: program.id) != nil {
            throw OfflineVideoError.alreadySaving
        }

        let duration = program.recordedVideo.duration
        guard let estimatedSize = OfflineQualityEstimate.estimateJobSizeBytes(
            durationSeconds: duration,
            apiQuality: apiQuality
        ), let requiredSize = OfflineQualityEstimate.estimateRequiredStorageBytes(
            durationSeconds: duration,
            apiQuality: apiQuality
        ) else {
            throw OfflineVideoError.unsupportedQuality(apiQuality)
        }

        refreshStorageUsage()
        if let availableCapacityBytes, Int64(requiredSize) > availableCapacityBytes {
            throw OfflineVideoError.insufficientSpace(
                required: requiredSize,
                available: availableCapacityBytes
            )
        }

        // A new save replaces the previous failure entry for the same program
        // (the web client deletes failed / cancelled rows the same way).
        jobs.removeAll { $0.videoID == program.id && $0.state != .completed }
        var job = OfflineDownloadJob(
            videoID: program.id,
            program: program,
            quality: apiQuality,
            estimatedSizeBytes: estimatedSize
        )
        job.expectedSegments = OfflineDownloadProgress.expectedSegmentCount(
            durationSeconds: duration,
            segmentDurationSeconds: Self.defaultSegmentDurationSeconds
        )
        jobs.insert(job, at: 0)
        persistJobs()
        launch(job, client: client)
        return job
    }

    private func launch(_ job: OfflineDownloadJob, client: APIClient) {
        downloadTasks[job.jobID]?.cancel()
        prepareStagingDirectory(for: job.videoID)

        let url = client.offlineStreamURL(videoID: job.videoID, apiQuality: job.quality)
        let directory = stagingDirectory(for: job.videoID)
        let expectation = OfflineStreamExpectation(
            videoID: job.videoID,
            fileHash: job.program.recordedVideo.fileHash ?? "",
            quality: job.quality
        )

        beginBackgroundTask()
        let jobID = job.jobID
        let program = job.program
        downloadTasks[jobID] = Task { [weak self] in
            await self?.runDownload(
                jobID: jobID,
                program: program,
                url: url,
                directory: directory,
                expectation: expectation,
                client: client
            )
        }
    }

    private func runDownload(
        jobID: String,
        program: RecordedProgram,
        url: URL,
        directory: URL,
        expectation: OfflineStreamExpectation,
        client: APIClient
    ) async {
        guard let index = jobs.firstIndex(where: { $0.jobID == jobID }) else { return }
        jobs[index].state = .downloading
        jobs[index].updatedAt = Date()
        persistJobs()

        // The thumbnail and the past comments are small, so they are fetched
        // while the video streams (the web client does the same).
        let assets = Task.detached(priority: .utility) {
            await OfflineVideoManager.storeAssets(
                videoID: program.id,
                client: client,
                directory: directory
            )
        }

        do {
            let outcome = try await Self.receiveStream(
                url: url,
                directory: directory,
                expectation: expectation
            ) { progress in
                Task { @MainActor [weak self] in
                    self?.apply(progress: progress, jobID: jobID, program: program)
                }
            }
            _ = await assets.value
            try Task.checkCancellation()
            try finalize(jobID: jobID, outcome: outcome)
        } catch {
            assets.cancel()
            fail(jobID: jobID, error: error)
        }
    }

    private func apply(progress: OfflineStreamProgress, jobID: String, program: RecordedProgram) {
        guard let index = jobs.firstIndex(where: { $0.jobID == jobID }) else { return }
        guard jobs[index].state.isActive else { return }

        jobs[index].downloadedBytes = progress.downloadedBytes
        jobs[index].receivedSegments = progress.receivedSegments
        if let segmentDuration = progress.segmentDurationSeconds, segmentDuration > 0 {
            jobs[index].expectedSegments = OfflineDownloadProgress.expectedSegmentCount(
                durationSeconds: program.recordedVideo.duration,
                segmentDurationSeconds: segmentDuration
            )
        }
        jobs[index].updatedAt = Date()

        // Persist progress rarely: only state changes need to survive a crash,
        // and the recovery turns running jobs into retryable failures anyway.
        let now = Date()
        if let last = lastProgressPersistence[jobID],
           now.timeIntervalSince(last) < Self.progressPersistenceInterval {
            return
        }
        lastProgressPersistence[jobID] = now
        persistJobs()
    }

    // MARK: - Finishing a save

    private func finalize(jobID: String, outcome: OfflineStreamOutcome) throws {
        guard let index = jobs.firstIndex(where: { $0.jobID == jobID }),
              jobs[index].state.isActive else {
            throw CancellationError()
        }
        guard !outcome.segments.isEmpty else {
            throw OfflineVideoError.emptyStream
        }

        let job = jobs[index]
        let staging = stagingDirectory(for: job.videoID)
        let video = OfflineVideo(
            videoID: job.videoID,
            generationID: job.generationID,
            fileHash: outcome.metadata.fileHash,
            quality: job.quality,
            program: job.program,
            segments: outcome.segments,
            container: .mpegTS
        )

        // The playlist is the last thing written into the staging directory, so
        // a save that stops before this point is never listed.
        let playlist = OfflineHLSPlaylist.mediaPlaylist(for: video)
        try Data(playlist.utf8).write(
            to: staging.appendingPathComponent("playlist.m3u8"),
            options: .atomic
        )

        let destination = directory(for: job.videoID)
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: destination)
        try fileManager.moveItem(at: staging, to: destination)

        videos.removeAll { $0.videoID == job.videoID }
        videos.insert(video, at: 0)
        // Drop the older rows of the same program first: removing array
        // elements moves the index this job had.
        jobs.removeAll { $0.videoID == job.videoID && $0.jobID != jobID }
        if let completedIndex = jobs.firstIndex(where: { $0.jobID == jobID }) {
            jobs[completedIndex].state = .completed
            jobs[completedIndex].downloadedBytes = video.sizeBytes
            jobs[completedIndex].receivedSegments = video.segmentCount
            jobs[completedIndex].error = nil
            jobs[completedIndex].updatedAt = Date()
        }

        downloadTasks[jobID] = nil
        lastProgressPersistence[jobID] = nil
        persistVideos()
        persistJobs()
        refreshStorageUsage()
        endBackgroundTaskIfIdle()
    }

    private func fail(jobID: String, error: Error) {
        guard let index = jobs.firstIndex(where: { $0.jobID == jobID }) else { return }
        guard jobs[index].state.isActive else {
            // Cancelled (or already completed) by the user: drop the leftovers
            // of the generation this task was writing.
            return
        }
        let videoID = jobs[index].videoID
        // A cancelled Task surfaces as URLError(.cancelled); the job state was
        // already decided by cancel(), so it is ignored above.
        if error is CancellationError {
            return
        }
        jobs[index].state = .failed
        jobs[index].error = ErrorText.message(for: error)
        jobs[index].updatedAt = Date()
        removeStagingDirectory(for: videoID)
        downloadTasks[jobID] = nil
        lastProgressPersistence[jobID] = nil
        persistJobs()
        endBackgroundTaskIfIdle()
    }

    // MARK: - User actions

    /// Cancels a running save and deletes its partial data.
    func cancel(jobID: String) {
        guard let index = jobs.firstIndex(where: { $0.jobID == jobID }),
              jobs[index].state.isActive else {
            return
        }
        let videoID = jobs[index].videoID
        downloadTasks[jobID]?.cancel()
        downloadTasks[jobID] = nil
        jobs.remove(at: index)
        lastProgressPersistence[jobID] = nil
        removeStagingDirectory(for: videoID)
        persistJobs()
        endBackgroundTaskIfIdle()
    }

    /// Restarts a failed save from the beginning (the web client's retry).
    func retry(jobID: String, client: APIClient) {
        guard let index = jobs.firstIndex(where: { $0.jobID == jobID }),
              jobs[index].state == .failed else {
            return
        }
        jobs[index].state = .waiting
        jobs[index].error = nil
        jobs[index].downloadedBytes = 0
        jobs[index].receivedSegments = 0
        jobs[index].expectedSegments = OfflineDownloadProgress.expectedSegmentCount(
            durationSeconds: jobs[index].program.recordedVideo.duration,
            segmentDurationSeconds: Self.defaultSegmentDurationSeconds
        )
        jobs[index].updatedAt = Date()
        let job = jobs[index]
        persistJobs()
        launch(job, client: client)
    }

    /// Removes a finished or failed job row.
    func dismiss(jobID: String) {
        guard let index = jobs.firstIndex(where: { $0.jobID == jobID }),
              !jobs[index].state.isActive else {
            return
        }
        jobs.remove(at: index)
        persistJobs()
    }

    /// Deletes a saved video (and its running / failed job rows).
    func delete(videoID: Int) {
        for jobID in jobs.filter({ $0.videoID == videoID }).map(\.jobID) {
            downloadTasks[jobID]?.cancel()
            downloadTasks[jobID] = nil
            lastProgressPersistence[jobID] = nil
        }
        jobs.removeAll { $0.videoID == videoID }
        if videos.contains(where: { $0.videoID == videoID }) {
            try? FileManager.default.removeItem(at: directory(for: videoID))
        }
        removeStagingDirectory(for: videoID)
        videos.removeAll { $0.videoID == videoID }
        persistVideos()
        persistJobs()
        refreshStorageUsage()
        endBackgroundTaskIfIdle()
    }

    // MARK: - Files

    private func prepareStagingDirectory(for videoID: Int) {
        let staging = stagingDirectory(for: videoID)
        try? FileManager.default.removeItem(at: staging)
        try? FileManager.default.createDirectory(
            at: staging.appendingPathComponent(OfflineHLSPlaylist.segmentDirectoryName, isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    private func removeStagingDirectory(for videoID: Int) {
        try? FileManager.default.removeItem(at: stagingDirectory(for: videoID))
    }

    // MARK: - Background execution

    /// Asks iOS for extra time so a save keeps running after the app leaves the
    /// foreground. When the time is used up the save fails with a retry row
    /// instead of silently dying with the process.
    private func beginBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(
            withName: "KonomiTV.OfflineVideo"
        ) { [weak self] in
            Task { @MainActor in
                self?.backgroundTimeExpired()
            }
        }
    }

    private func endBackgroundTaskIfIdle() {
        guard downloadTasks.isEmpty else { return }
        endBackgroundTask()
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private func backgroundTimeExpired() {
        for jobID in Array(downloadTasks.keys) {
            downloadTasks[jobID]?.cancel()
            downloadTasks[jobID] = nil
            guard let index = jobs.firstIndex(where: { $0.jobID == jobID }),
                  jobs[index].state.isActive else {
                continue
            }
            jobs[index].state = .failed
            jobs[index].error = "バックグラウンドでの保存が中断されました。再試行してください。"
            jobs[index].updatedAt = Date()
            removeStagingDirectory(for: jobs[index].videoID)
        }
        persistJobs()
        endBackgroundTask()
    }

    // MARK: - Streaming

    /// Streams the save stream to disk and returns the segment list.
    ///
    /// Runs off the main actor: parsing and writing a segment take as long as
    /// they take and must not block the UI.
    private nonisolated static func receiveStream(
        url: URL,
        directory: URL,
        expectation: OfflineStreamExpectation,
        onProgress: @escaping @Sendable (OfflineStreamProgress) -> Void
    ) async throws -> OfflineStreamOutcome {
        let container = OfflineSegmentContainer.mpegTS
        let segmentsDirectory = directory.appendingPathComponent(
            OfflineHLSPlaylist.segmentDirectoryName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: segmentsDirectory,
            withIntermediateDirectories: true
        )

        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        let receiver = OfflineStreamReceiver(continuation: continuation)
        let session = URLSession(configuration: .ephemeral, delegate: receiver, delegateQueue: nil)
        var request = URLRequest(url: url)
        request.timeoutInterval = 60 * 60
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let dataTask = session.dataTask(with: request)
        receiver.attach(session: session, task: dataTask)

        return try await withTaskCancellationHandler {
            defer {
                receiver.invalidate()
                session.invalidateAndCancel()
            }
            dataTask.resume()

            var parser = OfflineStreamParser()
            var segments: [OfflineSegmentInfo] = []
            var metadata: OfflineStreamMetadata?
            var downloadedBytes = 0

            for try await chunk in stream {
                try Task.checkCancellation()
                for event in try parser.append(chunk) {
                    switch event {
                    case .metadata(let header):
                        guard header.matches(
                            videoID: expectation.videoID,
                            fileHash: expectation.fileHash,
                            quality: expectation.quality
                        ) else {
                            throw OfflineVideoError.metadataMismatch
                        }
                        metadata = header

                    case .segment(let segment):
                        let fileURL = segmentsDirectory.appendingPathComponent(
                            "\(segment.sequence).\(container.fileExtension)"
                        )
                        try segment.data.write(to: fileURL, options: .atomic)
                        segments.append(
                            OfflineSegmentInfo(
                                sequence: segment.sequence,
                                durationMilliseconds: segment.durationMilliseconds,
                                byteLength: segment.data.count
                            )
                        )
                        downloadedBytes += segment.data.count
                        onProgress(
                            OfflineStreamProgress(
                                downloadedBytes: downloadedBytes,
                                receivedSegments: segments.count,
                                segmentDurationSeconds: segment.durationSeconds
                            )
                        )

                    case .end:
                        break
                    }
                }
            }

            try parser.finish()
            guard let metadata else {
                throw OfflineVideoError.emptyStream
            }
            guard !segments.isEmpty else {
                throw OfflineVideoError.emptyStream
            }
            return OfflineStreamOutcome(metadata: metadata, segments: segments)
        } onCancel: {
            dataTask.cancel()
            continuation.finish()
        }
    }

    /// Downloads the small assets that make a saved video usable without the
    /// server: the list thumbnail and the past log comments.
    private nonisolated static func storeAssets(
        videoID: Int,
        client: APIClient,
        directory: URL
    ) async {
        let assetsDirectory = directory.appendingPathComponent("assets", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: assetsDirectory,
            withIntermediateDirectories: true
        )

        if let thumbnail = await fetch(client.thumbnailURL(videoID: videoID)) {
            try? thumbnail.write(
                to: assetsDirectory.appendingPathComponent("thumbnail"),
                options: .atomic
            )
        }

        if let comments = try? await client.pastComments(videoID: videoID),
           let data = try? JSONCoding.encode(comments) {
            try? data.write(
                to: assetsDirectory.appendingPathComponent("jikkyo.json"),
                options: .atomic
            )
        }
    }

    private nonisolated static func fetch(_ url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                return nil
            }
            return data
        } catch {
            return nil
        }
    }
}

// MARK: - Streaming values

struct OfflineStreamExpectation: Sendable {
    let videoID: Int
    let fileHash: String
    let quality: String
}

struct OfflineStreamProgress: Sendable {
    let downloadedBytes: Int
    let receivedSegments: Int
    let segmentDurationSeconds: Double?
}

struct OfflineStreamOutcome: Sendable {
    let metadata: OfflineStreamMetadata
    let segments: [OfflineSegmentInfo]
}

/// Bridges the data task's chunks into an `AsyncThrowingStream`.
///
/// `URLSession.AsyncBytes` delivers single bytes, which is far too slow for a
/// multi-gigabyte save; the delegate receives the network's own chunk sizes.
private final class OfflineStreamReceiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var isFinished = false

    init(continuation: AsyncThrowingStream<Data, Error>.Continuation) {
        self.continuation = continuation
    }

    func attach(session: URLSession, task: URLSessionDataTask) {
        lock.lock()
        self.session = session
        self.task = task
        lock.unlock()
    }

    func invalidate() {
        lock.lock()
        session = nil
        task = nil
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        continuation.yield(data)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(throwing: OfflineVideoError.httpStatus(0))
            return
        }
        guard (200..<300).contains(http.statusCode) else {
            completionHandler(.cancel)
            finish(throwing: OfflineVideoError.httpStatus(http.statusCode))
            return
        }
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            finish(throwing: error)
        } else {
            finish()
        }
    }

    private func finish() {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        lock.unlock()
        continuation.finish()
    }

    private func finish(throwing error: Error) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        lock.unlock()
        continuation.finish(throwing: error)
    }
}
