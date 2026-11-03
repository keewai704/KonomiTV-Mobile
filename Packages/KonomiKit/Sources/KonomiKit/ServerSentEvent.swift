import Foundation

/// One dispatched Server-Sent Event.
public struct ServerSentEvent: Sendable, Hashable {
    /// Value of the `event:` field, or `"message"` when the server omits it.
    public let event: String
    /// Value of the `data:` field(s), joined with \n (the SSE line separator).
    public let data: String
    /// Value of the last `id:` field seen on the connection, if any.
    public let id: String?

    public init(event: String = "message", data: String = "", id: String? = nil) {
        self.event = event
        self.data = data
        self.id = id
    }
}

/// Incremental Server-Sent Events parser.
///
/// Feed arbitrary byte chunks (network reads split anywhere) with
/// `append(_:)`; every blank line that terminates a complete event returns it.
/// Implements the WHATWG event-stream rules the KonomiTV server relies on:
///
/// - lines end with \n, \r\n or \r
/// - `:` at the start of a line is a comment (used for keep-alive pings)
/// - `field: value`, with one optional space stripped after the colon
/// - multiple `data:` lines are joined with \n
/// - an empty `data` buffer dispatches nothing
/// - `id:` is remembered for the rest of the connection
public struct ServerSentEventParser: Sendable {
    private var buffer: [UInt8] = []
    private var eventName: String?
    private var dataLines: [String] = []
    private var lastEventID: String?
    /// True when the previous byte was a CR, so a following LF is swallowed
    /// instead of ending a second (empty) line.
    private var sawCR = false

    public init() {}

    /// Bytes received but not yet terminated by a line break.
    public var pendingByteCount: Int {
        buffer.count
    }

    /// True while a partial event has been accumulated.
    public var hasPendingEvent: Bool {
        eventName != nil || !dataLines.isEmpty
    }

    public mutating func append(_ data: Data) -> [ServerSentEvent] {
        append(Array(data))
    }

    public mutating func append(_ bytes: [UInt8]) -> [ServerSentEvent] {
        buffer.append(contentsOf: bytes)
        var events: [ServerSentEvent] = []
        var lineStart = 0

        var index = 0
        while index < buffer.count {
            let byte = buffer[index]

            if byte == 0x0A {
                // The LF of a CRLF pair: the line already ended at the CR.
                if sawCR {
                    sawCR = false
                    index += 1
                    lineStart = index
                    continue
                }
                let line = String(decoding: buffer[lineStart..<index], as: UTF8.self)
                index += 1
                lineStart = index
                process(line: line, into: &events)
                continue
            }

            if byte == 0x0D {
                let line = String(decoding: buffer[lineStart..<index], as: UTF8.self)
                index += 1
                lineStart = index
                sawCR = true
                process(line: line, into: &events)
                continue
            }

            sawCR = false
            index += 1
        }

        if lineStart > 0 {
            buffer.removeFirst(lineStart)
        }
        return events
    }

    /// Feeds a single already-split line (without its line break).
    ///
    /// Returns the event dispatched by a blank line, if any.
    public mutating func append(line: String) -> ServerSentEvent? {
        var events: [ServerSentEvent] = []
        process(line: line, into: &events)
        return events.first
    }

    /// Dispatches a trailing event that was not terminated by a blank line.
    ///
    /// The SSE specification discards such an incomplete event, but when a
    /// proxy closes the connection right after the last `data:` line the app
    /// is better off with the event itself.
    public mutating func finish() -> [ServerSentEvent] {
        var events: [ServerSentEvent] = []
        if !buffer.isEmpty {
            let line = String(decoding: buffer, as: UTF8.self)
            buffer.removeAll(keepingCapacity: true)
            process(line: line, into: &events)
        }
        if let event = dispatch() {
            events.append(event)
        }
        return events
    }

    public mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
        eventName = nil
        dataLines.removeAll(keepingCapacity: true)
        lastEventID = nil
        sawCR = false
    }

    // MARK: - Line handling

    private mutating func process(line: String, into events: inout [ServerSentEvent]) {
        if line.isEmpty {
            if let event = dispatch() {
                events.append(event)
            }
            return
        }

        // Comment / keep-alive ping.
        if line.hasPrefix(":") {
            return
        }

        let field: String
        var value: String
        if let colon = line.firstIndex(of: ":") {
            field = String(line[line.startIndex..<colon])
            value = String(line[line.index(after: colon)...])
            if value.hasPrefix(" ") {
                value.removeFirst()
            }
        } else {
            field = line
            value = ""
        }

        switch field {
        case "event":
            eventName = value
        case "data":
            dataLines.append(value)
        case "id":
            // An id containing a NUL is ignored per the specification.
            if !value.contains("\u{0}") {
                lastEventID = value
            }
        default:
            // "retry" and unknown fields are not used by KonomiTV.
            break
        }
    }

    private mutating func dispatch() -> ServerSentEvent? {
        let name = eventName
        eventName = nil

        guard !dataLines.isEmpty else {
            dataLines.removeAll(keepingCapacity: true)
            return nil
        }
        let data = dataLines.joined(separator: "\n")
        dataLines.removeAll(keepingCapacity: true)
        return ServerSentEvent(
            event: name ?? "message",
            data: data,
            id: lastEventID
        )
    }
}
