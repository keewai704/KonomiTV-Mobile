import Foundation
import Network
import KonomiKit
import KonomiStreaming

enum LocalHLSServerError: Error, LocalizedError, Sendable {
    case notStarted
    case stopped

    var errorDescription: String? {
        switch self {
        case .notStarted:
            return "ローカル再生サーバーを起動できませんでした。"
        case .stopped:
            return "ローカル再生サーバーが停止しました。"
        }
    }
}

/// Thread-safe holder of the selected audio track.
private final class AudioSelectionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var selection: AudioSelection = .primary

    func set(_ selection: AudioSelection) {
        lock.lock()
        self.selection = selection
        lock.unlock()
    }

    var current: AudioSelection {
        lock.lock()
        defer { lock.unlock() }
        return selection
    }
}

/// Where a saved (offline) video is served from.
///
/// The playlist is the finished VOD playlist of the save; its segment URIs are
/// relative, so the player resolves them against the loopback playlist URL.
struct OfflinePlaybackSource: Sendable {
    let playlist: String
    /// Directory that contains the playlist and its segments.
    let directory: URL
    let segmentDirectoryName: String
    let segmentFileExtension: String
    let segmentContentType: String
    /// Init segment file name (fMP4 saves); nil for MPEG-TS.
    let initSegmentFile: String?
    /// Called for every caption PES packet of a served segment, with its
    /// playback time, so offline playback keeps the ARIB caption overlay.
    let onCaption: @Sendable (CaptionPES, Double) -> Void
}

/// A minimal HTTP/1.1 server bound to `127.0.0.1` that exposes the live
/// segment store (or a saved video) as an HLS playlist.
///
/// Neither AVPlayer nor libVLC can consume the endless raw MPEG-TS stream
/// KonomiTV serves, so the app re-packetises it into short HLS segments and
/// plays them from here.
///
/// All `NWListener` / `NWConnection` callbacks run on one serial queue; the
/// class is `@unchecked Sendable` and only hands `Sendable` values (the actor,
/// `Data`, `UUID`) to other tasks.
final class LocalHLSServer: @unchecked Sendable {
    private static let headerTerminator = Data("\r\n\r\n".utf8)
    private static let maximumRequestBytes = 64 * 1024

    private let queue = DispatchQueue(label: "com.github.keewai704.KonomiTV.local-hls")
    private let store: SegmentStore?
    private let offline: OfflinePlaybackSource?
    private let offlinePlaylist: HLSMediaPlaylist?
    private let audio = AudioSelectionBox()
    /// Called with the sequence number of every live segment served, in request
    /// order. The player anchors its live clock to the first one after a load:
    /// that is the segment libVLC starts from, so its PROGRAM-DATE-TIME and
    /// first video PTS are the mapping's fixed point.
    private let onSegmentServed: (@Sendable (Int) -> Void)?

    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var boundPort: UInt16?
    private var pendingStart: CheckedContinuation<UInt16, Error>?

    init(store: SegmentStore, onSegmentServed: (@Sendable (Int) -> Void)? = nil) {
        self.store = store
        self.offline = nil
        self.offlinePlaylist = nil
        self.onSegmentServed = onSegmentServed
    }

    /// Serves a saved video from disk instead of the live segment store.
    init(offline: OfflinePlaybackSource) {
        self.store = nil
        self.offline = offline
        self.onSegmentServed = nil
        self.offlinePlaylist = HLSMediaPlaylist(
            text: offline.playlist,
            url: URL(string: "http://127.0.0.1/offline/playlist.m3u8")!
        )
    }

    /// Selects the audio track served by the segment endpoint. Switching takes
    /// effect with the next segment request, without restarting the stream.
    func setAudio(_ selection: AudioSelection) {
        audio.set(selection)
    }

    // MARK: - Lifecycle

    /// Starts listening on an OS assigned loopback port and returns it.
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.startOnQueue(continuation)
            }
        }
    }

    /// Starts listening and returns the loopback URL of `path`.
    func startURL(path: String) async throws -> URL {
        let port = try await start()
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else {
            throw LocalHLSServerError.notStarted
        }
        return url
    }

    func stop() {
        queue.async {
            self.teardownOnQueue()
        }
    }

    private func startOnQueue(_ continuation: CheckedContinuation<UInt16, Error>) {
        if let boundPort {
            continuation.resume(returning: boundPort)
            return
        }
        if listener != nil {
            pendingStart = continuation
            return
        }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = false
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)

        do {
            let listener = try NWListener(using: parameters, on: .any)
            listener.stateUpdateHandler = { [weak self] state in
                self?.handleListenerState(state)
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            self.listener = listener
            self.pendingStart = continuation
            listener.start(queue: queue)
        } catch {
            continuation.resume(throwing: error)
        }
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard let port = listener?.port?.rawValue else {
                failPendingStart(with: LocalHLSServerError.notStarted)
                return
            }
            boundPort = port
            if let pending = pendingStart {
                pendingStart = nil
                pending.resume(returning: port)
            }
        case .failed(let error):
            if let pending = pendingStart {
                pendingStart = nil
                pending.resume(throwing: error)
            }
            teardownOnQueue()
        case .cancelled:
            failPendingStart(with: LocalHLSServerError.stopped)
        default:
            break
        }
    }

    private func failPendingStart(with error: Error) {
        if let pending = pendingStart {
            pendingStart = nil
            pending.resume(throwing: error)
        }
    }

    private func teardownOnQueue() {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil

        for connection in connections.values {
            connection.stateUpdateHandler = nil
            connection.cancel()
        }
        connections.removeAll()

        failPendingStart(with: LocalHLSServerError.stopped)
        boundPort = nil
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        connections[id] = connection

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.closeConnection(id)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(on: id, buffer: Data())
    }

    private func closeConnection(_ id: UUID) {
        guard let connection = connections.removeValue(forKey: id) else { return }
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

    private func receive(on id: UUID, buffer: Data) {
        guard let connection = connections[id] else { return }

        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            var buffer = buffer
            if let data, !data.isEmpty {
                buffer.append(data)
            }

            if let terminator = buffer.range(of: Self.headerTerminator) {
                let head = String(decoding: buffer[buffer.startIndex..<terminator.lowerBound], as: UTF8.self)
                self.respond(to: head, on: id)
                return
            }

            if isComplete || error != nil || buffer.count > Self.maximumRequestBytes {
                self.closeConnection(id)
                return
            }

            self.receive(on: id, buffer: buffer)
        }
    }

    private func respond(to head: String, on id: UUID) {
        let requestLine = head.components(separatedBy: "\r\n").first ?? ""
        let parts = requestLine.split(separator: " ")
        let target = parts.count >= 2 ? String(parts[1]) : "/"
        let store = self.store
        let offline = self.offline
        let offlinePlaylist = self.offlinePlaylist
        let audio = self.audio.current

        Task { [weak self] in
            let response = await LocalHLSServer.makeResponse(
                for: target,
                store: store,
                offline: offline,
                offlinePlaylist: offlinePlaylist,
                audio: audio,
                onSegmentServed: self?.onSegmentServed
            )
            guard let self else { return }
            self.queue.async {
                self.send(response, to: id)
            }
        }
    }

    private func send(_ data: Data, to id: UUID) {
        guard let connection = connections[id] else { return }
        connection.send(content: data, isComplete: true, completion: .contentProcessed { [weak self] _ in
            self?.closeConnection(id)
        })
    }

    // MARK: - Responses

    /// Segments listed in the live playlist (one second each); the store
    /// keeps 30.
    static let liveWindowSegments = 20

    private static func makeResponse(
        for target: String,
        store: SegmentStore?,
        offline: OfflinePlaybackSource?,
        offlinePlaylist: HLSMediaPlaylist?,
        audio: AudioSelection,
        onSegmentServed: (@Sendable (Int) -> Void)?
    ) async -> Data {
        let path = target
            .split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? target

        // A saved video is served from disk: no server, no network.
        if let offline {
            return offlineResponse(for: path, source: offline, playlist: offlinePlaylist)
        }

        if path == "/live.m3u8", let store {
            // libVLC's HLS module buffers several seconds before it plays and
            // only reloads the playlist once it has fetched nearly everything
            // listed; a six-segment window of one-second segments left it
            // waiting at the window end. Twenty segments give it room.
            let playlist = await store.playlist(windowSize: Self.liveWindowSegments)
            let firstSequence = playlist.split(separator: "\n")
                .first { $0.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") }?
                .dropFirst("#EXT-X-MEDIA-SEQUENCE:".count) ?? "-"
            let segmentCount = playlist.split(separator: "\n").filter { $0.hasPrefix("seg/") }.count
            AppLog.hls.debug("live.m3u8 media-sequence=\(String(firstSequence), privacy: .public) segments=\(segmentCount, privacy: .public)")
            return httpResponse(
                status: 200,
                reason: "OK",
                contentType: "application/vnd.apple.mpegurl",
                body: Data(playlist.utf8)
            )
        }

        if path.hasPrefix("/seg/"), path.hasSuffix(".ts") {
            let number = path.dropFirst("/seg/".count).dropLast(".ts".count)
            if let sequence = Int(number),
               let segment = await store?.segment(sequence: sequence, audio: audio) {
                AppLog.hls.debug("segment \(sequence, privacy: .public) (\(segment.duration, privacy: .public)s)")
                onSegmentServed?(sequence)
                return httpResponse(
                    status: 200,
                    reason: "OK",
                    contentType: "video/mp2t",
                    // Captions were already extracted from the original
                    // bytes; the player only gets the audio and video (which
                    // also keeps libVLC's own caption decoder idle).
                    body: PlayerStreamFilter.audioVideoOnly(
                        segment.data,
                        pmt: segment.pmt,
                        pmtPID: segment.pmtPID
                    )
                )
            }
        }

        AppLog.hls.debug("not found \(path, privacy: .public)")
        return notFound()
    }

    // MARK: - Offline responses

    private static func offlineResponse(
        for path: String,
        source: OfflinePlaybackSource,
        playlist: HLSMediaPlaylist?
    ) -> Data {
        if path == "/offline/playlist.m3u8" {
            return httpResponse(
                status: 200,
                reason: "OK",
                contentType: "application/vnd.apple.mpegurl",
                body: Data(source.playlist.utf8)
            )
        }

        if let initSegment = source.initSegmentFile, path == "/offline/\(initSegment)" {
            if let data = try? Data(contentsOf: source.directory.appendingPathComponent(initSegment)) {
                return httpResponse(status: 200, reason: "OK", contentType: "video/mp4", body: data)
            }
            return notFound()
        }

        let prefix = "/offline/\(source.segmentDirectoryName)/"
        let suffix = ".\(source.segmentFileExtension)"
        if path.hasPrefix(prefix), path.hasSuffix(suffix) {
            let number = path.dropFirst(prefix.count).dropLast(suffix.count)
            if let sequence = Int(number) {
                let fileURL = source.directory
                    .appendingPathComponent(source.segmentDirectoryName, isDirectory: true)
                    .appendingPathComponent("\(sequence)\(suffix)")
                if let data = try? Data(contentsOf: fileURL) {
                    // Extracted on every fetch like the online proxy does, so
                    // seeking back re-fills the caption buffer.
                    if let playlist {
                        for event in VideoCaptionExtraction.events(
                            in: data,
                            playlist: playlist,
                            segmentIndex: sequence
                        ) {
                            source.onCaption(event.pes, event.time)
                        }
                    }
                    return httpResponse(
                        status: 200,
                        reason: "OK",
                        contentType: source.segmentContentType,
                        body: source.segmentFileExtension == "ts"
                            ? PlayerStreamFilter.audioVideoOnly(data)
                            : data
                    )
                }
            }
        }

        return notFound()
    }

    private static func notFound() -> Data {
        httpResponse(
            status: 404,
            reason: "Not Found",
            contentType: "text/plain; charset=utf-8",
            body: Data("Not Found".utf8)
        )
    }

    private static func httpResponse(
        status: Int,
        reason: String,
        contentType: String,
        body: Data
    ) -> Data {
        var header = "HTTP/1.1 \(status) \(reason)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Cache-Control: no-cache\r\n"
        header += "Connection: close\r\n"
        header += "Access-Control-Allow-Origin: *\r\n"
        header += "\r\n"

        var response = Data(header.utf8)
        response.append(body)
        return response
    }
}
