import Foundation
import Observation
import KonomiKit
import KonomiStreaming

/// Reads KonomiTV's endless MPEG-TS live stream and writes HLS segments into a
/// `SegmentStore`.
///
/// Runs off the main actor; the only thread hop is the progress callback.
enum LiveStreamReader {
    /// - Parameter onProgress: called with the number of produced segments.
    static func consume(
        url: URL,
        store: SegmentStore,
        onProgress: @escaping @Sendable (Int) async -> Void
    ) async throws {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("video/mp2t", forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            throw APIError.httpStatus(httpResponse.statusCode, nil)
        }

        var segmenter = LiveSegmenter(targetDuration: 1.0)
        var buffer: [UInt8] = []
        buffer.reserveCapacity(65_536)
        var produced = 0
        var received = 0

        for try await byte in bytes {
            buffer.append(byte)
            received += 1

            // Leaving the loop cancels the underlying data task.
            if received % 4096 == 0, Task.isCancelled {
                throw CancellationError()
            }

            guard buffer.count >= 65_536 else { continue }

            let segments = segmenter.append(Data(buffer))
            buffer.removeAll(keepingCapacity: true)
            if !segments.isEmpty {
                await store.append(contentsOf: segments)
                produced += segments.count
                await onProgress(produced)
            }
        }

        if !buffer.isEmpty {
            let segments = segmenter.append(Data(buffer))
            if !segments.isEmpty {
                await store.append(contentsOf: segments)
                produced += segments.count
                await onProgress(produced)
            }
        }

        if let last = segmenter.flush() {
            await store.append(last)
            produced += 1
            await onProgress(produced)
        }
    }
}

/// UI facing facade for live playback: starts the local HLS server, streams
/// and segments the upstream MPEG-TS, and publishes the loopback playlist URL
/// once enough segments exist.
@MainActor
@Observable
final class LiveStreamSession {
    enum Phase: Equatable, Sendable {
        case idle
        case buffering
        case ready(URL)
        case failed(String)
    }

    let channel: LiveChannel
    let client: APIClient
    let quality: StreamQuality

    private(set) var phase: Phase = .idle
    private(set) var segmentCount = 0
    private(set) var playbackURL: URL?

    /// Called once when the loopback playlist URL is published.
    @ObservationIgnored var onReady: (@MainActor (URL) -> Void)?
    /// Called when the pipeline fails (network error, stream ended, ...).
    @ObservationIgnored var onFailed: (@MainActor (String) -> Void)?

    @ObservationIgnored private var store: SegmentStore?
    @ObservationIgnored private var server: LocalHLSServer?
    @ObservationIgnored private var serverURL: URL?
    @ObservationIgnored private var pipeline: Task<Void, Never>?
    @ObservationIgnored private var reader: Task<String?, Never>?

    init(channel: LiveChannel, client: APIClient, quality: StreamQuality) {
        self.channel = channel
        self.client = client
        self.quality = quality
    }

    func start() {
        guard pipeline == nil else { return }

        phase = .buffering
        segmentCount = 0
        playbackURL = nil
        serverURL = nil

        let store = SegmentStore(capacity: 30)
        self.store = store

        let upstreamURL = client.liveStreamURL(
            displayChannelID: channel.displayChannelID,
            quality: quality
        )

        pipeline = Task { [weak self] in
            await self?.bootstrap(upstreamURL: upstreamURL, store: store)
        }
    }

    func stop() {
        pipeline?.cancel()
        pipeline = nil
        reader?.cancel()
        reader = nil
        server?.stop()
        server = nil
        store = nil
        serverURL = nil
        playbackURL = nil
        segmentCount = 0
        phase = .idle
    }

    // MARK: - Pipeline

    private func bootstrap(upstreamURL: URL, store: SegmentStore) async {
        let server = LocalHLSServer(store: store)
        self.server = server

        do {
            let port = try await server.start()
            guard let localURL = URL(string: "http://127.0.0.1:\(port)/live.m3u8") else {
                throw LocalHLSServerError.notStarted
            }
            if Task.isCancelled {
                server.stop()
                return
            }
            // The loopback URL is only published once enough segments exist,
            // so AVPlayer never sees an empty playlist.
            serverURL = localURL

            // Captured as a constant so the nested progress closure does not
            // reference the outer closure's weak `self` variable.
            let progress: @Sendable (Int) async -> Void = { [weak self] count in
                await self?.applySegmentCount(count)
            }

            let reader = Task.detached(priority: .userInitiated) { () -> String? in
                do {
                    try await LiveStreamReader.consume(url: upstreamURL, store: store, onProgress: progress)
                    return nil
                } catch is CancellationError {
                    return nil
                } catch {
                    return liveStreamErrorMessage(error)
                }
            }
            self.reader = reader

            let failure = await reader.value
            self.reader = nil

            guard !Task.isCancelled else { return }

            if let failure {
                fail(failure)
            } else {
                fail("ライブ配信が終了しました。")
            }
        } catch is CancellationError {
            // Cancelled by `stop()`.
        } catch {
            guard !Task.isCancelled else { return }
            fail(liveStreamErrorMessage(error))
        }
    }

    private func fail(_ message: String) {
        phase = .failed(message)
        onFailed?(message)
    }

    private func applySegmentCount(_ count: Int) {
        segmentCount = count
        guard count >= 3, let serverURL else { return }
        guard playbackURL == nil else { return }
        playbackURL = serverURL
        phase = .ready(serverURL)
        onReady?(serverURL)
    }
}

/// Japanese message for a live pipeline failure. Free function so the detached
/// reader task can use it without hopping to an actor.
private func liveStreamErrorMessage(_ error: Error) -> String {
    if let apiError = error as? APIError, let description = apiError.errorDescription {
        return description
    }
    if let localized = (error as? LocalizedError)?.errorDescription {
        return localized
    }
    let nsError = error as NSError
    if nsError.domain == NSURLErrorDomain {
        return "ライブ配信に接続できませんでした。ネットワーク接続を確認してください。"
    }
    return "ライブ配信を開始できませんでした。"
}
