import Foundation
import XCTest
@testable import KonomiKit

final class ExtendedModelsTests: XCTestCase {

    // MARK: Recorded video file info / series

    func testRecordedVideoFileInfoDecodes() throws {
        let program = try JSONCoding.decode(RecordedProgram.self, from: Fixtures.recordedProgramSeriesJSON)
        let video = program.recordedVideo

        XCTAssertEqual(video.id, 4)
        XCTAssertEqual(video.status, "Recorded")
        XCTAssertEqual(video.filePath, "/recorded/gr021/program4.m2ts")
        XCTAssertEqual(video.fileHash, "mockhash0004")
        XCTAssertEqual(video.fileSize, 1_000_004_000)
        XCTAssertNotNil(video.fileCreatedAt)
        XCTAssertNotNil(video.fileModifiedAt)
        XCTAssertNotNil(video.recordingStartTime)
        XCTAssertNotNil(video.recordingEndTime)
        XCTAssertEqual(video.containerFormat, "MPEG-TS")
        XCTAssertEqual(video.videoCodec, "H.264")
        XCTAssertEqual(video.videoCodecProfile, "Main")
        XCTAssertEqual(video.videoScanType, "Progressive")
        XCTAssertFalse(video.hasVideoStreamChanges)
        XCTAssertEqual(try XCTUnwrap(video.videoFrameRate), 29.97, accuracy: 0.0001)
        XCTAssertEqual(video.videoResolutionWidth, 1440)
        XCTAssertEqual(video.videoResolutionHeight, 1080)
        XCTAssertEqual(video.primaryAudioCodec, "AAC-LC")
        XCTAssertEqual(video.primaryAudioChannel, "Stereo")
        XCTAssertEqual(video.primaryAudioSamplingRate, 48000)
        XCTAssertNil(video.secondaryAudioCodec)
        XCTAssertEqual(video.cmSections?.count, 0)
        XCTAssertNil(video.thumbnailInfo)
    }

    func testRecordedProgramSeriesFieldsDecode() throws {
        let program = try JSONCoding.decode(RecordedProgram.self, from: Fixtures.recordedProgramSeriesJSON)
        XCTAssertEqual(program.id, 4)
        XCTAssertEqual(program.seriesID, 1)
        XCTAssertEqual(program.seriesBroadcastPeriodID, 0)
        XCTAssertEqual(program.seriesTitle, "アニメ 鬼滅の刃")
        XCTAssertEqual(program.episodeNumber, "第1話")
        XCTAssertEqual(program.subtitle, "アニメ 鬼滅の刃")
        XCTAssertEqual(program.recordingStartMargin, 0)
        XCTAssertEqual(program.recordingEndMargin, 0)
        XCTAssertFalse(program.isPartiallyRecorded)
        XCTAssertEqual(program.primaryAudioType, "2/0モード(ステレオ)")
        XCTAssertEqual(program.primaryAudioLanguage, "日本語")
        XCTAssertNil(program.secondaryAudioType)
        XCTAssertEqual(program.channel?.displayChannelID, "gr021")
        XCTAssertEqual(program.genres.first?.major, "スポーツ")
    }

    func testRecordedProgramWithoutSeriesFieldsStillDecodes() throws {
        // The older fixture has no series_id / file_path / cm_sections at all.
        let programs = try JSONCoding.decode(RecordedPrograms.self, from: Fixtures.recordedProgramsJSON)
        let program = try XCTUnwrap(programs.recordedPrograms.first)
        XCTAssertNil(program.seriesID)
        XCTAssertNil(program.seriesBroadcastPeriodID)
        XCTAssertEqual(program.recordingStartMargin, 0)
        XCTAssertFalse(program.isPartiallyRecorded)
        XCTAssertEqual(program.detail, [:])
        XCTAssertNil(program.recordedVideo.filePath)
        XCTAssertNil(program.recordedVideo.cmSections)
        XCTAssertFalse(program.recordedVideo.hasVideoStreamChanges)
    }

    func testRecordedProgramSeriesRoundTrip() throws {
        let original = try JSONCoding.decode(RecordedProgram.self, from: Fixtures.recordedProgramSeriesJSON)
        let data = try JSONCoding.encode(original)
        let decoded = try JSONCoding.decode(RecordedProgram.self, from: data)
        XCTAssertEqual(decoded.seriesID, original.seriesID)
        XCTAssertEqual(decoded.recordedVideo.filePath, original.recordedVideo.filePath)
        XCTAssertEqual(decoded.recordedVideo.videoCodecProfile, original.recordedVideo.videoCodecProfile)
        XCTAssertEqual(decoded.primaryAudioLanguage, original.primaryAudioLanguage)
    }

    func testThumbnailInfoDecodes() throws {
        let json = """
        {
          "id": 9,
          "status": "Recorded",
          "thumbnail_info": {
            "version": 2,
            "representative": {"format": "WebP", "width": 480, "height": 270, "revision": 7},
            "tile": {
              "format": "WebP",
              "image_width": 4800,
              "image_height": 2700,
              "tile_width": 160,
              "tile_height": 90,
              "total_tiles": 60,
              "column_count": 10,
              "row_count": 6,
              "interval_sec": 2.0
            }
          },
          "cm_sections": [{"start_time": 10.5, "end_time": 40.0}]
        }
        """
        let video = try JSONCoding.decode(RecordedVideo.self, from: json)
        let info = try XCTUnwrap(video.thumbnailInfo)
        XCTAssertEqual(info.version, 2)
        XCTAssertEqual(info.representative?.revision, 7)
        XCTAssertEqual(info.representative?.width, 480)
        XCTAssertEqual(info.tile?.totalTiles, 60)
        XCTAssertEqual(info.tile?.intervalSec, 2.0)
        XCTAssertEqual(video.cmSections?.first?.startTime, 10.5)
        XCTAssertEqual(video.cmSections?.first?.endTime, 40.0)
    }

    // MARK: Channels

    func testChannelJikkyoForceDecodes() throws {
        let json = """
        {
          "id": "gr011",
          "display_channel_id": "gr011",
          "network_id": 32736,
          "service_id": 1024,
          "remocon_id": 1,
          "channel_number": "1",
          "type": "GR",
          "name": "NHK総合",
          "jikkyo_force": 42,
          "is_subchannel": false,
          "is_radiochannel": false,
          "is_watchable": true
        }
        """
        let channel = try JSONCoding.decode(Channel.self, from: json)
        XCTAssertEqual(channel.jikkyoForce, 42)

        let withoutForce = try JSONCoding.decode(
            Channel.self,
            from: #"{"id":"gr011","display_channel_id":"gr011","type":"GR","name":"NHK総合"}"#
        )
        XCTAssertNil(withoutForce.jikkyoForce)
    }

    // MARK: Series

    func testSeriesListDecodes() throws {
        let list = try JSONCoding.decode(SeriesList.self, from: Fixtures.seriesListJSON)
        XCTAssertEqual(list.total, 3)
        XCTAssertEqual(list.seriesList.count, 3)
        XCTAssertEqual(list.seriesList.map { $0.id }, [1, 2, 3])
        XCTAssertEqual(list.seriesList.first?.title, "アニメ 鬼滅の刃")
        XCTAssertEqual(list.seriesList.first?.genres.first?.middle, "国内アニメ")
        XCTAssertNotNil(list.seriesList.first?.updatedAt)

        let period = try XCTUnwrap(list.seriesList.first?.broadcastPeriods.first)
        XCTAssertEqual(period.channel?.displayChannelID, "gr021")
        XCTAssertEqual(period.startDate, "2026-10-06")
        XCTAssertEqual(period.endDate, "2026-12-29")
        XCTAssertEqual(period.recordedPrograms.first?.id, 4)
        XCTAssertEqual(period.recordedPrograms.first?.seriesID, 1)
    }

    func testSeriesDetailDecodes() throws {
        let series = try JSONCoding.decode(Series.self, from: Fixtures.seriesDetailJSON)
        XCTAssertEqual(series.id, 1)
        XCTAssertEqual(series.title, "アニメ 鬼滅の刃")
        XCTAssertTrue(series.description.contains("鬼"))
        XCTAssertEqual(series.broadcastPeriods.count, 1)
        XCTAssertEqual(series.allRecordedPrograms.count, 1)
        XCTAssertEqual(series.allRecordedPrograms.first?.recordedVideo.videoCodec, "H.264")
    }

    func testSeriesWithoutBroadcastPeriodsDecodes() throws {
        let series = try JSONCoding.decode(
            Series.self,
            from: #"{"id":7,"title":"テスト","description":"","genres":[]}"#
        )
        XCTAssertEqual(series.id, 7)
        XCTAssertEqual(series.title, "テスト")
        XCTAssertTrue(series.broadcastPeriods.isEmpty)
        XCTAssertTrue(series.allRecordedPrograms.isEmpty)
    }

    // MARK: Programs search

    func testProgramsDecodes() throws {
        let programs = try JSONCoding.decode(Programs.self, from: Fixtures.programsJSON)
        XCTAssertEqual(programs.total, 7)
        XCTAssertEqual(programs.programs.count, 2)
        let program = try XCTUnwrap(programs.programs.first)
        XCTAssertEqual(program.title, "NHK BS ショッピング・通販")
        XCTAssertEqual(program.channelID, "NID16384-SID1024")
        XCTAssertEqual(program.networkID, 16384)
        XCTAssertEqual(program.serviceID, 1024)
        XCTAssertEqual(program.genres.first?.middle, "ショッピング・通販")
        XCTAssertEqual(program.primaryAudioLanguage, "日本語")
        XCTAssertGreaterThan(program.duration, 0)
    }

    func testProgramSearchConditionEncodesSnakeCaseKeys() throws {
        let condition = ProgramSearchCondition(
            keyword: "ニュース",
            excludeKeyword: "再放送",
            serviceRanges: [ProgramSearchConditionService(networkID: 32736, transportStreamID: 32736, serviceID: 1024)],
            genreRanges: [Genre(major: "ニュース・報道", middle: "定時・総合")],
            dateRanges: [ProgramSearchConditionDate(startDayOfWeek: 0, startHour: 5, endHour: 9)],
            durationRangeMin: 10,
            durationRangeMax: 60,
            broadcastType: .freeOnly,
            duplicateTitleCheckScope: .sameChannelOnly
        )
        let data = try JSONCoding.encode(condition)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["keyword"] as? String, "ニュース")
        XCTAssertEqual(object["exclude_keyword"] as? String, "再放送")
        XCTAssertEqual(object["broadcast_type"] as? String, "FreeOnly")
        XCTAssertEqual(object["duplicate_title_check_scope"] as? String, "SameChannelOnly")
        XCTAssertEqual(object["duplicate_title_check_period_days"] as? Int, 6)
        XCTAssertEqual(object["duration_range_min"] as? Int, 10)
        let genres = try XCTUnwrap(object["genre_ranges"] as? [[String: String]])
        XCTAssertEqual(genres.first?["major"], "ニュース・報道")
        let services = try XCTUnwrap(object["service_ranges"] as? [[String: Int]])
        XCTAssertEqual(services.first?["transport_stream_id"], 32736)
        let dates = try XCTUnwrap(object["date_ranges"] as? [[String: Int]])
        XCTAssertEqual(dates.first?["start_hour"], 5)
        XCTAssertEqual(object["is_regex_search_enabled"] as? Bool, false)

        let decoded = try JSONCoding.decode(ProgramSearchCondition.self, from: data)
        XCTAssertEqual(decoded.keyword, "ニュース")
        XCTAssertEqual(decoded.broadcastType, ProgramSearchBroadcastType.freeOnly)
        XCTAssertEqual(decoded.serviceRanges?.first?.serviceID, 1024)
    }

    // MARK: Timetable

    func testTimeTableDecodes() throws {
        let timetable = try JSONCoding.decode(TimeTable.self, from: Fixtures.timetableJSON)
        XCTAssertEqual(timetable.channels.count, 1)
        XCTAssertNotNil(timetable.dateRange.earliest)
        XCTAssertNotNil(timetable.dateRange.latest)

        let column = try XCTUnwrap(timetable.channels.first)
        XCTAssertEqual(column.channel.displayChannelID, "gr011")
        XCTAssertEqual(column.channel.type, .gr)
        XCTAssertNil(column.channel.jikkyoForce)
        XCTAssertNil(column.subchannels)
        XCTAssertEqual(column.programs.count, 3)

        let program = try XCTUnwrap(column.programs.first)
        // TimeTableProgram wraps Program and keeps the flat JSON shape.
        XCTAssertEqual(program.id, "NID32736-SID1024-EID20000")
        XCTAssertEqual(program.program.title, "NHK総合 モーニングニュース")
        XCTAssertEqual(program.program.channelID, "NID32736-SID1024")
        XCTAssertEqual(program.program.eventID, 20000)
        XCTAssertEqual(program.program.genres.first?.major, "ニュース・報道")
        XCTAssertEqual(program.reservation?.id, 42)
        XCTAssertEqual(program.reservation?.status, .reserved)
        XCTAssertEqual(program.reservation?.recordingAvailability, .full)

        XCTAssertNil(column.programs[1].reservation)
    }

    func testTimeTableProgramEncodesFlatWithReservation() throws {
        let timetable = try JSONCoding.decode(TimeTable.self, from: Fixtures.timetableJSON)
        let data = try JSONCoding.encode(timetable)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let channels = try XCTUnwrap(object["channels"] as? [[String: Any]])
        let programs = try XCTUnwrap(channels.first?["programs"] as? [[String: Any]])
        let program = try XCTUnwrap(programs.first)
        // Program fields stay at the top level, plus the reservation.
        XCTAssertEqual(program["title"] as? String, "NHK総合 モーニングニュース")
        XCTAssertNotNil(program["start_time"] as? String)
        let reservation = try XCTUnwrap(program["reservation"] as? [String: Any])
        XCTAssertEqual(reservation["id"] as? Int, 42)
        XCTAssertEqual(reservation["recording_availability"] as? String, "Full")

        let decoded = try JSONCoding.decode(TimeTable.self, from: data)
        XCTAssertEqual(decoded.channels.first?.programs.first?.program.title, "NHK総合 モーニングニュース")
        XCTAssertEqual(decoded.channels.first?.programs.first?.reservation?.id, 42)
    }

    func testTimeTableLenientDecoding() throws {
        let timetable = try JSONCoding.decode(
            TimeTable.self,
            from: #"{"channels":[{"channel":{"id":"gr011","display_channel_id":"gr011","type":"GR","name":"NHK総合"},"programs":[]}]}"#
        )
        XCTAssertEqual(timetable.channels.count, 1)
        XCTAssertTrue(timetable.channels[0].programs.isEmpty)
        XCTAssertNil(timetable.channels[0].subchannels)
        XCTAssertEqual(timetable.dateRange.earliest.timeIntervalSince1970, 0, accuracy: 0.001)
    }
}
