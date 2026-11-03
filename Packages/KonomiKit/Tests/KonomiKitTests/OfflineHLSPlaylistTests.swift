import Foundation
import XCTest
@testable import KonomiKit

final class OfflineHLSPlaylistTests: XCTestCase {
    private func makeVideo(
        container: OfflineSegmentContainer = .mpegTS,
        initSegmentFile: String? = nil,
        durations: [Int] = [2000, 2000, 1500]
    ) -> OfflineVideo {
        OfflineVideo(
            videoID: 42,
            generationID: "generation",
            fileHash: "hash",
            quality: "720p",
            program: RecordedProgram(id: 42, title: "テスト番組"),
            segments: durations.enumerated().map { index, duration in
                OfflineSegmentInfo(
                    sequence: index,
                    durationMilliseconds: duration,
                    byteLength: 1000 + index
                )
            },
            container: container,
            initSegmentFile: initSegmentFile,
            savedAt: Date(timeIntervalSince1970: 0)
        )
    }

    func testMediaPlaylistIsAFinishedVODPlaylist() {
        let playlist = OfflineHLSPlaylist.mediaPlaylist(for: makeVideo())
        XCTAssertEqual(
            playlist,
            """
            #EXTM3U
            #EXT-X-VERSION:6
            #EXT-X-PLAYLIST-TYPE:VOD
            #EXT-X-TARGETDURATION:2
            #EXTINF:2.000,
            segments/0.ts
            #EXTINF:2.000,
            segments/1.ts
            #EXTINF:1.500,
            segments/2.ts
            #EXT-X-ENDLIST

            """
        )
    }

    func testTargetDurationIsTheCeilingOfTheLongestSegment() {
        XCTAssertEqual(
            OfflineHLSPlaylist.targetDuration(for: makeVideo(durations: [4000, 6001]).segments),
            7
        )
        XCTAssertEqual(OfflineHLSPlaylist.targetDuration(for: []), 1)
        XCTAssertEqual(
            OfflineHLSPlaylist.targetDuration(for: makeVideo(durations: [2000]).segments),
            2
        )
    }

    func testFragmentedMP4PlaylistDeclaresItsInitSegment() {
        let playlist = OfflineHLSPlaylist.mediaPlaylist(
            for: makeVideo(container: .fragmentedMP4, initSegmentFile: "init.mp4")
        )
        XCTAssertTrue(playlist.contains("#EXT-X-MAP:URI=\"init.mp4\""))
        XCTAssertTrue(playlist.contains("segments/0.m4s"))
        // EXT-X-MAP has to precede the first segment of the playlist.
        let mapRange = playlist.range(of: "#EXT-X-MAP")
        let firstSegment = playlist.range(of: "#EXTINF")
        XCTAssertNotNil(mapRange)
        XCTAssertNotNil(firstSegment)
        if let mapRange, let firstSegment {
            XCTAssertLessThan(mapRange.lowerBound, firstSegment.lowerBound)
        }
    }

    func testSegmentsAreWrittenInSequenceOrder() {
        var video = makeVideo(durations: [2000, 2000])
        video.segments.reverse()
        let playlist = OfflineHLSPlaylist.mediaPlaylist(for: video)
        let segmentLines = playlist.split(separator: "\n").filter { $0.hasPrefix("segments/") }
        XCTAssertEqual(segmentLines, ["segments/0.ts", "segments/1.ts"])
    }

    func testCustomSegmentPathPrefix() {
        let playlist = OfflineHLSPlaylist.mediaPlaylist(
            for: makeVideo(durations: [2000]),
            segmentPathPrefix: "media/"
        )
        XCTAssertTrue(playlist.contains("media/0.ts"))
    }
}
