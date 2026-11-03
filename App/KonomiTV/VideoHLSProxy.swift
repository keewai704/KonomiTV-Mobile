import Foundation
import Network
import KonomiKit
import KonomiStreaming

/// Serves a recorded program's HLS through a loopback HTTP server.
///
/// AVPlayer cannot be pointed at the KonomiTV server directly any more,
/// because the caption pipeline has to see the MPEG-TS segments that go past.
/// This proxy rewrites the server's master and media playlists so AVPlayer
/// fetches everything from `127.0.0.1`; every segment request is forwarded to
/// the server (with the bearer token) and, for the primary video playlist, fed
/// to `TSSegmentProbe`/`CaptionPESExtractor` to produce captions with a
/// playback position.
///
/// Everything else (keep-alive, quality switching, seek, `type=master`) keeps
/// working: the reference to the server's master URL keeps the request shape
/// identical from the server's point of view.
final class VideoHLSProxy: @unchecked Sendable {
    private static let headerTerminator = Data("\r\n\r\n".utf8)
    private static let maximumRequestBytes = 64 * 1024

    private let queue = DispatchQueue(label: "com.github.keewai704.KonomiTV.video-hls")
    private let masterURL: URL
    private let token: String?
    private let onCaption: @Sendable (CaptionPES, Double) -> Void
    private let state = ProxyState()

    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var boundPort: UInt16?
    private var pendingStart: CheckedContinuation<UInt16, Error>?

    init(
        masterURL: URL,
        token: String?,
        onCaption: @escaping @Sendable (CaptionPES, Double) -> Void
    ) {
        self.masterURL = masterURL
        self.token = token
        self.onCaption = onCaption
    }

    // MARK: - Lifecycle

    /// Starts listening and returns the loopback master playlist URL.
    func start() async throws -> URL {
        let port = try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.startOnQueue(continuation)
            }
        }
        guard let url = URL(string: "http://127.0.0.1:\(port)/master.m3u8") else {
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
        let path = target
            .split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? target

        Task { [weak self] in
            guard let self else { return }
            let response = await self.makeResponse(for: path)
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

    private func makeResponse(for path: String) async -> Data {
        if path == "/master.m3u8" {
            return await makeMasterResponse()
        }

        if path.hasSuffix(".m3u8") {
            let key = String(path.dropFirst().dropLast(".m3u8".count))
            if state.media(for: key) != nil {
                return await makeMediaResponse(key: key)
            }
            return notFound()
        }

        let components = path.split(separator: "/").map(String.init)
        if components.count == 3,
           components[1] == "seg",
           components[2].hasSuffix(".ts"),
           let index = Int(components[2].dropLast(".ts".count)) {
            return await makeSegmentResponse(key: components[0], index: index)
        }

        return notFound()
    }

    private func makeMasterResponse() async -> Data {
        do {
            let data = try await fetch(masterURL)
            let text = String(decoding: data, as: UTF8.self)
            var media: [String: ProxyState.Media] = [:]
            var audioIndex = 0
            var videoIndex = 0
            var lines: [String] = []

            for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
                if line.hasPrefix("#EXT-X-MEDIA:"), let uri = Self.attribute("URI", in: line) {
                    let key = "audio\(audioIndex)"
                    let serverURL = URL(string: uri, relativeTo: masterURL)?.absoluteURL ?? masterURL
                    media[key] = ProxyState.Media(
                        serverURL: serverURL,
                        extractsCaptions: false
                    )
                    lines.append(
                        line.replacingOccurrences(
                            of: "\"\(uri)\"",
                            with: "\"/\(key).m3u8\""
                        )
                    )
                    audioIndex += 1
                    continue
                }

                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty, !trimmed.hasPrefix("#") {
                    let key = "video\(videoIndex)"
                    let serverURL = URL(string: trimmed, relativeTo: masterURL)?.absoluteURL ?? masterURL
                    media[key] = ProxyState.Media(
                        serverURL: serverURL,
                        extractsCaptions: true
                    )
                    lines.append("/\(key).m3u8")
                    videoIndex += 1
                } else {
                    lines.append(line)
                }
            }

            guard videoIndex > 0 else { return badGateway() }
            state.setMedia(media)
            return Self.httpResponse(
                status: 200,
                reason: "OK",
                contentType: "application/vnd.apple.mpegurl",
                body: Data(lines.joined(separator: "\n").utf8)
            )
        } catch {
            return badGateway()
        }
    }

    private func makeMediaResponse(key: String) async -> Data {
        guard let media = state.media(for: key) else { return notFound() }
        do {
            let data = try await fetch(media.serverURL)
            let text = String(decoding: data, as: UTF8.self)
            guard let playlist = HLSMediaPlaylist(text: text, url: media.serverURL) else {
                return badGateway()
            }
            state.setPlaylist(playlist, for: key)

            var index = 0
            var lines: [String] = []
            for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || trimmed.hasPrefix("#") {
                    lines.append(line)
                    continue
                }
                lines.append("/\(key)/seg/\(index).ts")
                index += 1
            }

            return Self.httpResponse(
                status: 200,
                reason: "OK",
                contentType: "application/vnd.apple.mpegurl",
                body: Data(lines.joined(separator: "\n").utf8)
            )
        } catch {
            return badGateway()
        }
    }

    private func makeSegmentResponse(key: String, index: Int) async -> Data {
        guard let media = state.media(for: key),
              let playlist = media.playlist,
              playlist.segments.indices.contains(index)
        else {
            return notFound()
        }

        do {
            let segmentURL = playlist.segments[index].url
            let data = try await fetch(segmentURL)
            // Extracted on every fetch: after a seek back AVPlayer fetches the
            // segment again and the caption buffer needs its captions again.
            // A duplicate caption at the same PTS just replaces the same one.
            if media.extractsCaptions {
                extractCaptions(from: data, playlist: playlist, index: index)
            }
            return Self.httpResponse(
                status: 200,
                reason: "OK",
                contentType: "video/mp2t",
                body: data
            )
        } catch {
            return badGateway()
        }
    }

    // MARK: - Captions

    /// Extracts caption PES packets from one segment and maps their PTS onto
    /// the recording's playback timeline.
    private func extractCaptions(from data: Data, playlist: HLSMediaPlaylist, index: Int) {
        let events = TSSegmentProbe.captionPES(in: data)
        guard !events.isEmpty else { return }

        let firstPTS = TSSegmentProbe.firstVideoPTS(in: data)
        let segmentStart = playlist.segments[0..<index].reduce(0.0) { $0 + $1.duration }

        for pes in events {
            let time: Double
            if let firstPTS, let pts = pes.pts,
               let mapped = playlist.playbackTime(
                   segmentIndex: index,
                   pts: pts,
                   firstPTS: firstPTS
               ) {
                time = mapped
            } else {
                // 文字スーパー without a PTS (and malformed caption timing)
                // is shown from the start of its segment.
                time = segmentStart
            }
            onCaption(pes, time)
        }
    }

    // MARK: - Networking

    private func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            throw LocalHLSServerError.stopped
        }
        return data
    }

    private static func attribute(_ name: String, in line: String) -> String? {
        guard let start = line.range(of: name + "=\"") else { return nil }
        let rest = line[start.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    private func notFound() -> Data {
        Self.httpResponse(
            status: 404,
            reason: "Not Found",
            contentType: "text/plain; charset=utf-8",
            body: Data("Not Found".utf8)
        )
    }

    private func badGateway() -> Data {
        Self.httpResponse(
            status: 502,
            reason: "Bad Gateway",
            contentType: "text/plain; charset=utf-8",
            body: Data("Bad Gateway".utf8)
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

// MARK: - State

/// Playlist state shared between the proxy's request tasks.
private final class ProxyState: @unchecked Sendable {
    struct Media: Sendable {
        let serverURL: URL
        /// True for the variant media playlist (the one carrying video). Audio
        /// playlists are proxied byte-for-byte but never parsed for captions.
        let extractsCaptions: Bool
        var playlist: HLSMediaPlaylist?
    }

    private let lock = NSLock()
    private var media: [String: Media] = [:]

    func setMedia(_ media: [String: Media]) {
        lock.lock()
        self.media = media
        lock.unlock()
    }

    func media(for key: String) -> Media? {
        lock.lock()
        defer { lock.unlock() }
        return media[key]
    }

    func setPlaylist(_ playlist: HLSMediaPlaylist, for key: String) {
        lock.lock()
        defer { lock.unlock() }
        media[key]?.playlist = playlist
    }

}
