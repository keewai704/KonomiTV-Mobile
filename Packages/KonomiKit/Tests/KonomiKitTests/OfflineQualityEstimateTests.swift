import XCTest
@testable import KonomiKit

final class OfflineQualityEstimateTests: XCTestCase {
    // MARK: - Quality names

    func testAPIQualityMatchesTheWebRule() {
        XCTAssertEqual(
            OfflineQualityEstimate.apiQuality(base: .p720, dataSaver: false, use24fps: false),
            "720p"
        )
        XCTAssertEqual(
            OfflineQualityEstimate.apiQuality(base: .p720, dataSaver: true, use24fps: false),
            "720p-hevc"
        )
        XCTAssertEqual(
            OfflineQualityEstimate.apiQuality(base: .p720, dataSaver: true, use24fps: true),
            "720p-hevc-24fps"
        )
        XCTAssertEqual(
            OfflineQualityEstimate.apiQuality(base: .p1080p60, dataSaver: false, use24fps: true),
            "1080p-60fps"
        )
        XCTAssertEqual(
            OfflineQualityEstimate.apiQuality(base: .p1080p60, dataSaver: true, use24fps: true),
            "1080p-60fps-hevc"
        )
        XCTAssertEqual(
            OfflineQualityEstimate.apiQuality(base: .p240, dataSaver: false, use24fps: true),
            "240p-24fps"
        )
    }

    func testOfferedQualitiesAreTheRecordedVideoQualities() {
        XCTAssertEqual(
            OfflineQualityEstimate.baseQualities,
            [.p1080p60, .p1080, .p810, .p720, .p540, .p480, .p360, .p240]
        )
    }

    // MARK: - Bitrates

    func testBitrateLookupIgnoresEncodingSuffixes() {
        let base = OfflineQualityEstimate.streamBitrates(apiQuality: "720p")
        XCTAssertEqual(base?.videoBitrateKbps, 4500)
        XCTAssertEqual(base?.videoBitrateMaxKbps, 6200)
        XCTAssertEqual(base?.audioBitrateKbps, 192)

        XCTAssertEqual(
            OfflineQualityEstimate.streamBitrates(apiQuality: "720p-hevc-10bit-24fps")?.videoBitrateKbps,
            2000
        )
        XCTAssertEqual(
            OfflineQualityEstimate.streamBitrates(apiQuality: "1080p-60fps-hevc")?.videoBitrateKbps,
            3500
        )
        XCTAssertEqual(OfflineQualityEstimate.streamBitrates(apiQuality: "2160p")?.videoBitrateKbps, nil)
        XCTAssertEqual(OfflineQualityEstimate.effectiveTotalBitrateKbps(apiQuality: "2160p"), 0)
    }

    // MARK: - Size estimates

    func testEstimatesMirrorTheWebClient() {
        // 720p AVC: 4500 kbps × 0.85 + 192 kbps = 4017 kbps
        XCTAssertEqual(
            OfflineQualityEstimate.effectiveTotalBitrateKbps(apiQuality: "720p"),
            4017,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            OfflineQualityEstimate.estimateDisplaySizeBytes(durationSeconds: 1800, apiQuality: "720p"),
            903_825_000
        )
        XCTAssertEqual(
            OfflineQualityEstimate.estimateJobSizeBytes(durationSeconds: 1800, apiQuality: "720p"),
            949_016_250
        )
        // The web client's Math.ceil() sees the same 1.1 floating point product,
        // so the ceiling is one byte above the exact value there as well.
        XCTAssertEqual(
            OfflineQualityEstimate.estimateRequiredStorageBytes(durationSeconds: 1800, apiQuality: "720p"),
            1_582_020_001
        )

        // 720p HEVC: 2000 kbps × 0.75 + 192 kbps = 1692 kbps
        XCTAssertEqual(
            OfflineQualityEstimate.effectiveTotalBitrateKbps(apiQuality: "720p-hevc"),
            1692,
            accuracy: 0.0001
        )

        XCTAssertNil(OfflineQualityEstimate.estimateJobSizeBytes(durationSeconds: 60, apiQuality: "2160p"))
        XCTAssertNil(OfflineQualityEstimate.estimateRequiredStorageBytes(durationSeconds: 60, apiQuality: "2160p"))
    }

    // MARK: - Labels

    func testSizeFormatting() {
        XCTAssertEqual(OfflineQualityEstimate.formatOfflineSize(bytes: 903_825_000, approximate: true), "約860MB")
        XCTAssertEqual(OfflineQualityEstimate.formatOfflineSize(bytes: 903_825_000, approximate: false), "862MB")
        XCTAssertEqual(OfflineQualityEstimate.formatOfflineSize(bytes: 1_610_612_736, approximate: true), "約1.5GB")
        XCTAssertEqual(OfflineQualityEstimate.formatOfflineSize(bytes: 1_610_612_736, approximate: false), "1.50GB")
        XCTAssertEqual(OfflineQualityEstimate.formatOfflineSize(bytes: 2048, approximate: true), "約2.0KB")
        XCTAssertEqual(OfflineQualityEstimate.formatOfflineSize(bytes: 900, approximate: false), "900B")
    }

    func testQualityLabels() {
        XCTAssertEqual(
            OfflineQualityEstimate.formatQualitySelectLabel(base: .p720, durationSeconds: 1800, dataSaver: false),
            "720p (約860MB / 平均4.0Mbps)"
        )
        XCTAssertEqual(
            OfflineQualityEstimate.formatQualitySelectLabel(base: .p720, durationSeconds: 1800, dataSaver: true),
            "720p (約360MB / 平均1.7Mbps)"
        )
        XCTAssertEqual(
            OfflineQualityEstimate.formatQualitySelectLabel(base: .p1080p60, durationSeconds: 3600, dataSaver: false),
            "1080p (60fps) (約3.5GB / 平均8.3Mbps)"
        )
        XCTAssertEqual(OfflineQualityEstimate.formatQualityLabel(apiQuality: "720p-hevc-24fps"), "720p")
        XCTAssertEqual(OfflineQualityEstimate.formatQualityLabel(apiQuality: "1080p-60fps-hevc"), "1080p (60fps)")
        XCTAssertEqual(OfflineQualityEstimate.formatQualityLabel(apiQuality: "2160p"), "2160p")
        XCTAssertEqual(OfflineQualityEstimate.formatAverageBitrateLabel(apiQuality: "240p"), "0.6Mbps")
    }

    func testDefaultMenuSize() {
        XCTAssertEqual(
            OfflineQualityEstimate.defaultMenuSizeLabel(durationSeconds: 1800, dataSaver: false),
            "約860MB"
        )
    }
}
