import Foundation
import XCTest
@testable import KonomiKit

final class OfflineVideoModelsTests: XCTestCase {
    private func makeProgram() -> RecordedProgram {
        RecordedProgram(
            id: 12,
            title: "オフラインのテスト",
            description: "説明",
            startTime: Date(timeIntervalSince1970: 1_700_000_000),
            endTime: Date(timeIntervalSince1970: 1_700_003_600),
            duration: 3600,
            genres: [Genre(major: "アニメ", middle: "国内アニメ")],
            channel: Channel(id: "gr011", displayChannelID: "gr011", name: "NHK総合"),
            recordedVideo: RecordedVideo(
                id: 12,
                status: "Recorded",
                duration: 3600,
                fileSize: 1_000_000,
                fileHash: "file-hash"
            )
        )
    }

    private func makeVideo() -> OfflineVideo {
        OfflineVideo(
            videoID: 12,
            generationID: "gen",
            fileHash: "file-hash",
            quality: "720p-hevc-24fps",
            program: makeProgram(),
            segments: [
                OfflineSegmentInfo(sequence: 0, durationMilliseconds: 2000, byteLength: 500),
                OfflineSegmentInfo(sequence: 1, durationMilliseconds: 2000, byteLength: 700),
            ],
            savedAt: Date(timeIntervalSince1970: 1_700_100_000)
        )
    }

    func testVideoRoundTripsThroughJSON() throws {
        let video = makeVideo()
        let encoded = try JSONCoding.encode(video)
        let decoded = try JSONCoding.decode(OfflineVideo.self, from: encoded)

        XCTAssertEqual(decoded.videoID, 12)
        XCTAssertEqual(decoded.generationID, "gen")
        XCTAssertEqual(decoded.fileHash, "file-hash")
        XCTAssertEqual(decoded.quality, "720p-hevc-24fps")
        XCTAssertEqual(decoded.container, .mpegTS)
        XCTAssertEqual(decoded.segments.map(\.sequence), [0, 1])
        XCTAssertEqual(decoded.segments[1].durationMilliseconds, 2000)
        XCTAssertEqual(decoded.segments[1].byteLength, 700)
        XCTAssertEqual(decoded.program.title, "オフラインのテスト")
        XCTAssertEqual(decoded.program.channel?.name, "NHK総合")
        XCTAssertEqual(decoded.savedAt, video.savedAt)
        XCTAssertEqual(decoded, video)
    }

    func testDerivedValues() {
        let video = makeVideo()
        XCTAssertEqual(video.id, 12)
        XCTAssertEqual(video.sizeBytes, 1200)
        XCTAssertEqual(video.segmentCount, 2)
        XCTAssertEqual(video.durationSeconds, 4, accuracy: 0.0001)
        XCTAssertEqual(video.qualityLabel, "720p")
        XCTAssertEqual(video.sizeLabel, "1KB")
    }

    func testDurationFallsBackToTheProgramDuration() {
        var video = makeVideo()
        video.segments = []
        XCTAssertEqual(video.durationSeconds, 3600, accuracy: 0.0001)
    }

    func testJobRoundTripsAndReportsProgress() throws {
        var job = OfflineDownloadJob(
            jobID: "job-1",
            videoID: 12,
            generationID: "gen",
            program: makeProgram(),
            quality: "720p",
            state: .downloading,
            estimatedSizeBytes: 1_000_000,
            downloadedBytes: 250_000,
            receivedSegments: 25,
            expectedSegments: 100
        )
        XCTAssertEqual(job.progress, 0.25, accuracy: 0.0001)

        let encoded = try JSONCoding.encode(job)
        let decoded = try JSONCoding.decode(OfflineDownloadJob.self, from: encoded)
        XCTAssertEqual(decoded.jobID, job.jobID)
        XCTAssertEqual(decoded.videoID, job.videoID)
        XCTAssertEqual(decoded.generationID, job.generationID)
        XCTAssertEqual(decoded.program, job.program)
        XCTAssertEqual(decoded.quality, job.quality)
        XCTAssertEqual(decoded.state, job.state)
        XCTAssertEqual(decoded.estimatedSizeBytes, job.estimatedSizeBytes)
        XCTAssertEqual(decoded.downloadedBytes, job.downloadedBytes)
        XCTAssertEqual(decoded.receivedSegments, job.receivedSegments)
        XCTAssertEqual(decoded.expectedSegments, job.expectedSegments)
        XCTAssertNil(decoded.error)
        XCTAssertEqual(
            decoded.createdAt.timeIntervalSince1970,
            job.createdAt.timeIntervalSince1970,
            accuracy: 0.001
        )

        job.state = .completed
        XCTAssertEqual(job.progress, 1)

        job.state = .failed
        job.receivedSegments = 0
        job.downloadedBytes = 0
        XCTAssertEqual(job.progress, 0)
    }

    func testProgressUsesBytesBeforeTheFirstSegment() {
        XCTAssertEqual(
            OfflineDownloadProgress.fraction(
                receivedSegments: 0,
                expectedSegments: 60,
                downloadedBytes: 500,
                estimatedSizeBytes: 1000
            ),
            0.5,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            OfflineDownloadProgress.fraction(
                receivedSegments: 60,
                expectedSegments: 60,
                downloadedBytes: 10,
                estimatedSizeBytes: 1000
            ),
            0.99,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            OfflineDownloadProgress.fraction(
                receivedSegments: 0,
                expectedSegments: 0,
                downloadedBytes: 0,
                estimatedSizeBytes: 0
            ),
            0
        )
    }

    func testExpectedSegmentCount() {
        XCTAssertEqual(
            OfflineDownloadProgress.expectedSegmentCount(durationSeconds: 120, segmentDurationSeconds: 2),
            60
        )
        XCTAssertEqual(
            OfflineDownloadProgress.expectedSegmentCount(durationSeconds: 121, segmentDurationSeconds: 2),
            61
        )
        XCTAssertEqual(
            OfflineDownloadProgress.expectedSegmentCount(durationSeconds: 0, segmentDurationSeconds: 2),
            0
        )
        XCTAssertEqual(
            OfflineDownloadProgress.expectedSegmentCount(durationSeconds: 120, segmentDurationSeconds: 0),
            0
        )
    }
}
