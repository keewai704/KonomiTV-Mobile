import Foundation
import Observation
import KonomiKit

/// Reads a live channel's Server-Sent Events stream
/// (`GET /api/streams/live/{id}/{quality}/events`) and publishes the latest
/// live stream status.
@MainActor
@Observable
final class LiveEventsMonitor {
    private(set) var status: LiveStreamStatus?
    private(set) var failureMessage: String?

    /// Called for every decoded status event.
    @ObservationIgnored var onUpdate: (@MainActor (LiveStreamStatus) -> Void)?

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var connectionID = UUID()

    /// Starts reading `url`, replacing any previous connection.
    func start(url: URL) {
        stop()

        let connectionID = UUID()
        self.connectionID = connectionID
        failureMessage = nil

        task = Task { [weak self] in
            var request = URLRequest(url: url)
            request.timeoutInterval = 3600
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

            do {
                let (bytes, response) = try await URLSession.shared.bytes(for: request)
                guard let httpResponse = response as? HTTPURLResponse,
                      (200..<300).contains(httpResponse.statusCode) else {
                    throw APIError.httpStatus(
                        (response as? HTTPURLResponse)?.statusCode ?? 0,
                        nil
                    )
                }

                var parser = ServerSentEventParser()
                var received = 0
                for try await byte in bytes {
                    received += 1
                    if received % 1024 == 0, Task.isCancelled { return }

                    for event in parser.append([byte]) {
                        guard !Task.isCancelled else { return }
                        guard let decoded = try? LiveStreamEvent.decode(event) else {
                            continue
                        }
                        self?.apply(decoded.status, connectionID: connectionID)
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self?.failureMessage = (error as? LocalizedError)?.errorDescription
                    ?? "ライブストリームの状態を取得できませんでした。"
            }
        }
    }

    /// Stops the connection. Called when playback stops or restarts.
    func stop() {
        task?.cancel()
        task = nil
        status = nil
        failureMessage = nil
    }

    private func apply(_ status: LiveStreamStatus, connectionID: UUID) {
        guard connectionID == self.connectionID else { return }
        self.status = status
        onUpdate?(status)
    }
}
