import Foundation

/// Live stream state reported by `GET /api/streams/live/{id}/{quality}` and by
/// the event stream (`.../events`).
public enum LiveStreamStatusValue: String, Codable, CaseIterable, Sendable, Hashable {
    case offline = "Offline"
    case standby = "Standby"
    case onAir = "ONAir"
    case idling = "Idling"
    case restart = "Restart"
}

/// Payload of every live stream event (all four event types share it).
public struct LiveStreamStatus: Codable, Sendable, Hashable {
    public let status: LiveStreamStatusValue
    /// Human readable detail, shown by the player while Standby / Offline.
    public let detail: String
    /// UNIX timestamp (seconds) when the stream started.
    public let startedAt: Double
    /// UNIX timestamp (seconds) of the last status change.
    public let updatedAt: Double
    /// Viewers of this channel across all qualities.
    public let clientCount: Int

    public init(
        status: LiveStreamStatusValue,
        detail: String,
        startedAt: Double,
        updatedAt: Double,
        clientCount: Int
    ) {
        self.status = status
        self.detail = detail
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.clientCount = clientCount
    }

    private enum CodingKeys: String, CodingKey {
        case status
        case detail
        case startedAt = "started_at"
        case updatedAt = "updated_at"
        case clientCount = "client_count"
    }
}

/// Event names emitted by the live stream event API.
public enum LiveStreamEventKind: String, Codable, CaseIterable, Sendable, Hashable {
    /// Sent once on connect with the current status.
    case initialUpdate = "initial_update"
    /// The status itself changed (Offline / Standby / ONAir / Idling / Restart).
    case statusUpdate = "status_update"
    /// Only `detail` changed.
    case detailUpdate = "detail_update"
    /// Only `client_count` changed.
    case clientsUpdate = "clients_update"
}

/// A decoded live stream event.
public struct LiveStreamEvent: Sendable, Hashable {
    /// The raw `event:` name, kept for forward compatibility.
    public let name: String
    /// The known event kind, or nil for an event this client does not know.
    public let kind: LiveStreamEventKind?
    public let status: LiveStreamStatus

    public init(name: String, kind: LiveStreamEventKind?, status: LiveStreamStatus) {
        self.name = name
        self.kind = kind
        self.status = status
    }

    /// Decodes the JSON payload of a Server-Sent Event.
    public static func decode(_ event: ServerSentEvent) throws -> LiveStreamEvent {
        let status = try JSONCoding.decode(LiveStreamStatus.self, from: event.data)
        return LiveStreamEvent(
            name: event.event,
            kind: LiveStreamEventKind(rawValue: event.event),
            status: status
        )
    }
}
