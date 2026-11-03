import Foundation
import XCTest
@testable import KonomiKit

final class ServerSentEventParserTests: XCTestCase {

    private func parse(_ text: String) -> [ServerSentEvent] {
        var parser = ServerSentEventParser()
        return parser.append(Data(text.utf8))
    }

    func testSingleEvent() {
        let events = parse("event: status_update\ndata: {\"a\":1}\n\n")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].event, "status_update")
        XCTAssertEqual(events[0].data, "{\"a\":1}")
        XCTAssertNil(events[0].id)
    }

    func testEventWithoutEventFieldUsesMessage() {
        let events = parse("data: hello\n\n")
        XCTAssertEqual(events.map(\.event), ["message"])
        XCTAssertEqual(events.map(\.data), ["hello"])
    }

    func testCRLFAndCRLineEndings() {
        XCTAssertEqual(parse("data: a\r\n\r\n").map(\.data), ["a"])
        XCTAssertEqual(parse("data: a\r\r").map(\.data), ["a"])
        XCTAssertEqual(parse("data: a\n\r").map(\.data), ["a"])
    }

    func testMultiLineDataIsJoinedWithNewline() {
        let events = parse("event: x\ndata: line1\ndata: line2\ndata: line3\n\n")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].data, "line1\nline2\nline3")
    }

    func testCommentsAreIgnored() {
        let events = parse(": keep-alive ping\n\ndata: real\n\n: another\n")
        XCTAssertEqual(events.map(\.data), ["real"])
    }

    func testCommentInsideEventDoesNotPolluteData() {
        let events = parse("event: e\ndata: a\n: ping\ndata: b\n\n")
        XCTAssertEqual(events[0].data, "a\nb")
    }

    func testEventWithoutDataIsNotDispatched() {
        XCTAssertTrue(parse("event: empty\n\n").isEmpty)
        XCTAssertTrue(parse(":comment\n\n").isEmpty)
        XCTAssertTrue(parse("\n\n\n").isEmpty)
    }

    func testOneOptionalSpaceIsStripped() {
        let events = parse("data:no-space\ndata:  two-spaces\n\n")
        XCTAssertEqual(events[0].data, "no-space\n two-spaces")
    }

    func testIDIsRememberedAcrossEvents() {
        let events = parse("id: 7\ndata: a\n\ndata: b\n\nid: 8\ndata: c\n\n")
        XCTAssertEqual(events.map(\.id), ["7", "7", "8"])
    }

    func testRetryAndUnknownFieldsAreIgnored() {
        let events = parse("retry: 3000\nfoo: bar\ndata: a\n\n")
        XCTAssertEqual(events.map(\.data), ["a"])
    }

    func testChunkBoundaryAnywhere() {
        let stream = "event: status_update\r\ndata: {\"status\":\"ONAir\"}\r\ndata: second\r\n\r\n"
            + ": ping\r\n\r\n"
            + "data: tail\n\n"
        let bytes = Array(stream.utf8)

        // Every possible split point, feeding one byte at a time as well.
        for split in 1..<bytes.count {
            var parser = ServerSentEventParser()
            var events = parser.append(Array(bytes[0..<split]))
            events.append(contentsOf: parser.append(Array(bytes[split...])))
            XCTAssertEqual(events.count, 2, "split at \(split)")
            XCTAssertEqual(events[0].event, "status_update", "split at \(split)")
            XCTAssertEqual(events[0].data, "{\"status\":\"ONAir\"}\nsecond", "split at \(split)")
            XCTAssertEqual(events[1].data, "tail", "split at \(split)")
        }

        var bytewise = ServerSentEventParser()
        var collected: [ServerSentEvent] = []
        for byte in bytes {
            collected.append(contentsOf: bytewise.append([byte]))
        }
        XCTAssertEqual(collected.count, 2)
        XCTAssertEqual(collected[0].data, "{\"status\":\"ONAir\"}\nsecond")
    }

    func testPendingByteCountAndReset() {
        var parser = ServerSentEventParser()
        // Without a line break the field has not been parsed yet.
        XCTAssertTrue(parser.append(Data("data: partial".utf8)).isEmpty)
        XCTAssertEqual(parser.pendingByteCount, "data: partial".utf8.count)
        XCTAssertFalse(parser.hasPendingEvent)
        // A line break completes the field; the blank line is still missing.
        XCTAssertTrue(parser.append(Data("\n".utf8)).isEmpty)
        XCTAssertEqual(parser.pendingByteCount, 0)
        XCTAssertTrue(parser.hasPendingEvent)
        parser.reset()
        XCTAssertEqual(parser.pendingByteCount, 0)
        XCTAssertFalse(parser.hasPendingEvent)
    }

    func testFinishDispatchesUnterminatedEvent() {
        var parser = ServerSentEventParser()
        XCTAssertTrue(parser.append(Data("event: e\ndata: last".utf8)).isEmpty)
        let events = parser.finish()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].event, "e")
        XCTAssertEqual(events[0].data, "last")
    }

    func testAppendLineHelper() {
        var parser = ServerSentEventParser()
        XCTAssertNil(parser.append(line: "event: e"))
        XCTAssertNil(parser.append(line: "data: one"))
        let event = parser.append(line: "")
        XCTAssertEqual(event?.event, "e")
        XCTAssertEqual(event?.data, "one")
    }

    func testUTF8DataAcrossChunks() {
        // 主音声 in UTF-8 is split in the middle of a multi-byte sequence.
        let data = "data: 主音声\n\n".data(using: .utf8)!
        var parser = ServerSentEventParser()
        var events = parser.append(data.prefix(8))
        events.append(contentsOf: parser.append(data.suffix(from: 8)))
        XCTAssertEqual(events.map(\.data), ["主音声"])
    }
}

final class LiveStreamEventTests: XCTestCase {

    private let payload = """
    {"status":"ONAir","detail":"ライブストリームは ONAir です。","started_at":1762174800.5,"updated_at":1762174860.25,"client_count":3}
    """

    func testDecodeStatusPayload() throws {
        let event = ServerSentEvent(event: "status_update", data: payload)
        let decoded = try LiveStreamEvent.decode(event)
        XCTAssertEqual(decoded.name, "status_update")
        XCTAssertEqual(decoded.kind, .statusUpdate)
        XCTAssertEqual(decoded.status.status, .onAir)
        XCTAssertEqual(decoded.status.detail, "ライブストリームは ONAir です。")
        XCTAssertEqual(decoded.status.startedAt, 1762174800.5, accuracy: 0.001)
        XCTAssertEqual(decoded.status.updatedAt, 1762174860.25, accuracy: 0.001)
        XCTAssertEqual(decoded.status.clientCount, 3)
    }

    func testDecodeEveryEventKind() throws {
        for kind in LiveStreamEventKind.allCases {
            let event = ServerSentEvent(event: kind.rawValue, data: payload)
            let decoded = try LiveStreamEvent.decode(event)
            XCTAssertEqual(decoded.kind, kind)
            XCTAssertEqual(decoded.name, kind.rawValue)
        }
        XCTAssertEqual(
            LiveStreamEventKind.allCases.map(\.rawValue),
            ["initial_update", "status_update", "detail_update", "clients_update"]
        )
    }

    func testDecodeEveryStatus() throws {
        for status in LiveStreamStatusValue.allCases {
            let json = """
            {"status":"\(status.rawValue)","detail":"d","started_at":0,"updated_at":0,"client_count":0}
            """
            let decoded = try LiveStreamEvent.decode(
                ServerSentEvent(event: "initial_update", data: json)
            )
            XCTAssertEqual(decoded.status.status, status)
        }
        XCTAssertEqual(
            LiveStreamStatusValue.allCases.map(\.rawValue),
            ["Offline", "Standby", "ONAir", "Idling", "Restart"]
        )
    }

    func testUnknownEventKindIsKept() throws {
        let decoded = try LiveStreamEvent.decode(
            ServerSentEvent(event: "future_event", data: payload)
        )
        XCTAssertNil(decoded.kind)
        XCTAssertEqual(decoded.name, "future_event")
        XCTAssertEqual(decoded.status.status, .onAir)
    }

    func testInvalidPayloadThrows() {
        XCTAssertThrowsError(
            try LiveStreamEvent.decode(ServerSentEvent(event: "status_update", data: "{}"))
        )
        XCTAssertThrowsError(
            try LiveStreamEvent.decode(ServerSentEvent(event: "status_update", data: "nope"))
        )
    }

    func testParserAndDecoderWorkTogether() throws {
        var parser = ServerSentEventParser()
        let stream = "event: initial_update\ndata: \(payload)\n\n"
            + "event: clients_update\ndata: \(payload)\n\n"
        let events = parser.append(Data(stream.utf8))
        XCTAssertEqual(events.count, 2)
        let decoded = try events.map(LiveStreamEvent.decode)
        XCTAssertEqual(decoded.map(\.kind), [.initialUpdate, .clientsUpdate])
        XCTAssertEqual(decoded.map(\.status.clientCount), [3, 3])
    }
}
