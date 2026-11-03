import Foundation
import Observation
import KonomiKit
import KonomiStreaming

/// Reads KonomiTV's endless MPEG-TS live stream and writes HLS segments into a
/// `SegmentStore`.
///
/// Runs off the main actor; the only thread hop is the progress callback.
enum LiveStreamReader {
    /// - Parameters:
    ///   - onProgress: called with the number of produced segments.
    ///   - onCaptions: called with the caption / superimpose PES packets
    ///     completed by a chunk, in stream order.
    static func consume(
        url: URL,
        store: SegmentStore,
        onProgress: @escaping @Sendable (Int) async -> Void,
        onCaptions: @escaping @Sendable ([CaptionPES]) async -> Void
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

            let output = segmenter.process(Data(buffer))
            buffer.removeAll(keepingCapacity: true)
            if !output.captions.isEmpty {
                await onCaptions(output.captions)
            }
            if !output.segments.isEmpty {
                await store.append(contentsOf: output.segments)
                produced += output.segments.count
                await onProgress(produced)
            }
        }

        if !buffer.isEmpty {
            let output = segmenter.process(Data(buffer))
            if !output.captions.isEmpty {
                await onCaptions(output.captions)
            }
            if !output.segments.isEmpty {
                await store.append(contentsOf: output.segments)
                produced += output.segments.count
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
    let profile: StreamingProfile

    private(set) var phase: Phase = .idle
    private(set) var segmentCount = 0
    private(set) var playbackURL: URL?
    /// True when the stream carries a secondary audio track (副音声).
    private(set) var hasSecondaryAudio = false
    private(set) var audioSelection: AudioSelection = .primary

    /// Called once when the loopback playlist URL is published.
    @ObservationIgnored var onReady: (@MainActor (URL) -> Void)?
    /// Called when the pipeline fails (network error, stream ended, ...).
    @ObservationIgnored var onFailed: (@MainActor (String) -> Void)?
    /// Called when the stream's audio track layout becomes known or changes.
    @ObservationIgnored var onAudioTrackChange: (@MainActor (Bool) -> Void)?
    /// Called for every caption / superimpose PES packet. Packets that arrive
    /// before the PROGRAM-DATE-TIME anchor is known are buffered here.
    @ObservationIgnored var onCaption: (@MainActor (CaptionPES) -> Void)?

    /// Fixed reference point for `#EXT-X-PROGRAM-DATE-TIME` and for mapping
    /// caption PTS values onto the player's wall clock.
    private(set) var dateTimeAnchor: LiveProgramDateTimeAnchor?

    @ObservationIgnored private var store: SegmentStore?
    @ObservationIgnored private var server: LocalHLSServer?
    @ObservationIgnored private var serverURL: URL?
    @ObservationIgnored private var pipeline: Task<Void, Never>?
    @ObservationIgnored private var reader: Task<String?, Never>?
    @ObservationIgnored private var pendingCaptions: [CaptionPES] = []

    init(channel: LiveChannel, client: APIClient, profile: StreamingProfile) {
        self.channel = channel
        self.client = client
        self.profile = profile
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
            profile: profile,
            isRadioChannel: channel.isRadioChannel
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
        hasSecondaryAudio = false
        dateTimeAnchor = nil
        pendingCaptions.removeAll()
        phase = .idle
    }

    /// Switches 主音声 / 副音声 without restarting the upstream stream.
    func selectAudio(_ selection: AudioSelection) {
        audioSelection = selection
        server?.setAudio(selection)
    }

    // MARK: - Pipeline

    private func bootstrap(upstreamURL: URL, store: SegmentStore) async {
        let server = LocalHLSServer(store: store)
        server.setAudio(audioSelection)
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
            let captions: @Sendable ([CaptionPES]) async -> Void = { [weak self] events in
                await self?.receiveCaptions(events)
            }

            let reader = Task.detached(priority: .userInitiated) { () -> String? in
                do {
                    try await LiveStreamReader.consume(
                        url: upstreamURL,
                        store: store,
                        onProgress: progress,
                        onCaptions: captions
                    )
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

        if let store {
            Task { [weak self, store] in
                let hasSecondary = await store.hasSecondaryAudio
                let anchor = await store.programDateTimeAnchor
                guard !Task.isCancelled else { return }
                guard let self else { return }
                if self.hasSecondaryAudio != hasSecondary {
                    self.hasSecondaryAudio = hasSecondary
                    self.onAudioTrackChange?(hasSecondary)
                }
                self.applyAnchor(anchor)
            }
        }

        guard count >= 3, let serverURL else { return }
        guard playbackURL == nil else { return }
        playbackURL = serverURL
        phase = .ready(serverURL)
        onReady?(serverURL)
    }

    /// Buffers caption PES packets until the segment store has produced its
    /// first segment (and therefore knows the PROGRAM-DATE-TIME anchor).
    private func receiveCaptions(_ events: [CaptionPES]) {
        guard !events.isEmpty else { return }
        guard dateTimeAnchor != nil else {
            pendingCaptions.append(contentsOf: events)
            if pendingCaptions.count > 512 {
                pendingCaptions.removeFirst(pendingCaptions.count - 512)
            }
            return
        }
        for event in events {
            onCaption?(event)
        }
    }

    private func applyAnchor(_ anchor: LiveProgramDateTimeAnchor?) {
        guard let anchor else { return }
        let isNew = dateTimeAnchor == nil
        dateTimeAnchor = anchor
        guard isNew, !pendingCaptions.isEmpty else { return }

        let buffered = pendingCaptions
        pendingCaptions.removeAll(keepingCapacity: true)
        for event in buffered {
            onCaption?(event)
        }
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
