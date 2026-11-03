import Foundation
import XCTest
@testable import KonomiKit

final class ModelsTests: XCTestCase {

    func testVersionInfoDecodes() throws {
        let version = try JSONCoding.decode(VersionInfo.self, from: Fixtures.versionJSON)
        XCTAssertEqual(version.version, "v2.0.0")
        XCTAssertNil(version.latestVersion)
        XCTAssertEqual(version.environment, "Linux")
        XCTAssertEqual(version.backend, "EDCB")
        XCTAssertEqual(version.encoder, "FFmpeg")
    }

    func testChannelsDecodeLeniently() throws {
        let channels = try JSONCoding.decode(LiveChannels.self, from: Fixtures.channelsJSON)

        XCTAssertEqual(channels.gr.count, 2)
        XCTAssertEqual(channels.bs.count, 1)
        XCTAssertTrue(channels.cs.isEmpty)
        XCTAssertFalse(channels.isEmpty)
        XCTAssertEqual(channels.allChannels.count, 3)

        let first = try XCTUnwrap(channels.gr.first)
        XCTAssertEqual(first.id, "gr011")
        XCTAssertEqual(first.displayChannelID, "gr011")
        XCTAssertEqual(first.type, .gr)
        XCTAssertEqual(first.name, "NHK総合")
        XCTAssertEqual(first.viewerCount, 12)
        XCTAssertTrue(first.isWatchable)
        XCTAssertTrue(first.isDisplay)
        XCTAssertEqual(first.transportStreamID, 32736)
        XCTAssertEqual(first.programPresent?.title, "ニュース7")
        XCTAssertEqual(first.programPresent?.genres.first?.middle, "報道")
        XCTAssertEqual(first.programFollowing?.title, "次の番組")

        XCTAssertEqual(channels.gr[1].channelNumber, "021")
        XCTAssertTrue(channels.gr[1].isSubChannel)
        XCTAssertNil(channels.gr[1].programPresent)
    }

    func testNonEmptyGroupsAreInDisplayOrder() throws {
        let channels = try JSONCoding.decode(LiveChannels.self, from: Fixtures.channelsJSON)
        let groups = channels.nonEmptyGroups()
        XCTAssertEqual(groups.map { $0.type }, [.gr, .bs])
        XCTAssertEqual(groups.map { $0.channels.count }, [2, 1])
        XCTAssertEqual(channels.channels(for: .bs).first?.name, "NHK BS")
        XCTAssertTrue(channels.channels(for: .bs4k).isEmpty)
    }

    func testProgramProgress() throws {
        let channels = try JSONCoding.decode(LiveChannels.self, from: Fixtures.channelsJSON)
        let program = try XCTUnwrap(channels.gr.first?.programPresent)
        let start = try XCTUnwrap(JSONCoding.parseISO8601("2026-11-03T21:00:00+09:00"))
        let middle = try XCTUnwrap(JSONCoding.parseISO8601("2026-11-03T21:15:00+09:00"))
        let before = try XCTUnwrap(JSONCoding.parseISO8601("2026-11-03T20:00:00+09:00"))
        let after = try XCTUnwrap(JSONCoding.parseISO8601("2026-11-03T23:00:00+09:00"))

        XCTAssertEqual(program.startTime.timeIntervalSince1970, start.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(program.progress(at: middle), 0.5, accuracy: 0.0001)
        XCTAssertEqual(program.progress(at: before), 0.0)
        XCTAssertEqual(program.progress(at: after), 1.0)
    }

    func testFractionalSecondDates() throws {
        let channels = try JSONCoding.decode(LiveChannels.self, from: Fixtures.channelsJSON)
        let program = try XCTUnwrap(channels.bs.first?.programPresent)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expected = try XCTUnwrap(
            formatter.date(from: "2026-11-03T21:00:00.123456+09:00")
        )
        XCTAssertEqual(program.startTime.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 0.001)
    }

    func testLenientProgramDecoding() throws {
        let json = """
        {"id": "unknown", "title": "タイトルのみ"}
        """
        let program = try JSONCoding.decode(Program.self, from: json)
        XCTAssertEqual(program.id, "unknown")
        XCTAssertEqual(program.title, "タイトルのみ")
        XCTAssertEqual(program.description, "")
        XCTAssertEqual(program.duration, 0)
        XCTAssertTrue(program.isFree)
        XCTAssertEqual(program.progress(at: Date()), 0)
    }

    func testRecordedProgramsDecode() throws {
        let programs = try JSONCoding.decode(RecordedPrograms.self, from: Fixtures.recordedProgramsJSON)
        XCTAssertEqual(programs.total, 35)
        XCTAssertEqual(programs.recordedPrograms.count, 2)

        let first = try XCTUnwrap(programs.recordedPrograms.first)
        XCTAssertEqual(first.id, 101)
        XCTAssertEqual(first.title, "テスト番組")
        XCTAssertEqual(first.seriesTitle, "テストシリーズ")
        XCTAssertEqual(first.episodeNumber, "第1話")
        XCTAssertEqual(first.subtitle, "サブタイトル")
        XCTAssertEqual(first.channel?.name, "NHK総合")
        XCTAssertEqual(first.recordedVideo.videoResolutionWidth, 1920)
        XCTAssertEqual(first.recordedVideo.videoResolutionHeight, 1080)
        XCTAssertEqual(first.recordedVideo.videoCodec, "H.264")
        XCTAssertEqual(first.recordedVideo.fileSize, 123_456_789)

        let second = try XCTUnwrap(programs.recordedPrograms.last)
        XCTAssertNil(second.channel)
        XCTAssertEqual(second.recordedVideo.id, 102)
        XCTAssertEqual(second.recordedVideo.duration, 120.5, accuracy: 0.0001)
        XCTAssertEqual(second.recordedVideo.videoResolutionWidth, 0)
    }

    func testRecordedProgramDetailDecodes() throws {
        let program = try JSONCoding.decode(RecordedProgram.self, from: Fixtures.recordedProgramJSON)
        XCTAssertEqual(program.id, 101)
        XCTAssertEqual(program.channel?.displayChannelID, "gr011")
        XCTAssertEqual(program.recordedVideo.id, 101)
        XCTAssertEqual(program.genres.first?.major, "ドラマ")
    }

    func testUserAndTokenDecode() throws {
        let token = try JSONCoding.decode(UserAccessToken.self, from: Fixtures.loginJSON)
        XCTAssertEqual(token.accessToken, "test-access-token")
        XCTAssertEqual(token.tokenType, "bearer")

        let user = try JSONCoding.decode(User.self, from: Fixtures.userJSON)
        XCTAssertEqual(user.id, 1)
        XCTAssertEqual(user.name, "テストユーザー")
        XCTAssertFalse(user.isAdmin)
        XCTAssertNotNil(user.createdAt)
    }

    func testJSONCodingRoundTrip() throws {
        let original = try JSONCoding.decode(RecordedProgram.self, from: Fixtures.recordedProgramJSON)
        let data = try JSONCoding.encode(original)
        let decoded = try JSONCoding.decode(RecordedProgram.self, from: data)
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.title, original.title)
        XCTAssertEqual(decoded.recordedVideo.videoCodec, original.recordedVideo.videoCodec)
        XCTAssertEqual(
            decoded.startTime.timeIntervalSince1970,
            original.startTime.timeIntervalSince1970,
            accuracy: 0.001
        )
    }
}
