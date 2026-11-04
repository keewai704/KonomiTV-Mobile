import Foundation
import XCTest
@testable import KonomiKit

final class DataBroadcastingSettingsTests: XCTestCase {

    // MARK: - ZIP code

    func testZipCodeValidationMatchesTheWebClient() {
        XCTAssertTrue(DataBroadcastingSettings.isValidZipCode(""))
        XCTAssertTrue(DataBroadcastingSettings.isValidZipCode("123-4567"))
        XCTAssertFalse(DataBroadcastingSettings.isValidZipCode("1234567"))
        XCTAssertFalse(DataBroadcastingSettings.isValidZipCode("123-456"))
        XCTAssertFalse(DataBroadcastingSettings.isValidZipCode("12-34567"))
        XCTAssertFalse(DataBroadcastingSettings.isValidZipCode("123-456a"))
        XCTAssertFalse(DataBroadcastingSettings.isValidZipCode(" 123-4567"))
    }

    // MARK: - Prefecture

    func testPrefectureListMatchesTheWebClient() {
        // 未設定 plus the 50 prefecture values of DataBroadcasting.vue.
        XCTAssertEqual(DataBroadcastingPrefecture.all.count, 51)
        XCTAssertEqual(DataBroadcastingPrefecture.all.first, .unset)
        XCTAssertEqual(Set(DataBroadcastingPrefecture.all.map(\.number)).count, 51)
        XCTAssertEqual(DataBroadcastingPrefecture.all.first { $0.number == 14 }?.name, "東京都 (島部を除く)")
        XCTAssertEqual(DataBroadcastingPrefecture.all.first { $0.number == 48 }?.name, "沖縄県")
    }

    func testPrefectureValueStringRoundTrip() {
        for prefecture in DataBroadcastingPrefecture.all {
            let parsed = DataBroadcastingPrefecture(valueString: prefecture.valueString)
            XCTAssertEqual(parsed, prefecture, "valueString: \(prefecture.valueString)")
        }
        // The web client's exact strings, including the zero padded region code.
        let tokyo = DataBroadcastingPrefecture(valueString: "14-0b101010101100")
        XCTAssertEqual(tokyo?.number, 14)
        XCTAssertEqual(tokyo?.regionCode, 0b101010101100)
        XCTAssertEqual(tokyo?.valueString, "14-0b101010101100")
        XCTAssertEqual(DataBroadcastingPrefecture(valueString: "255-0b0"), .unset)
        XCTAssertNil(DataBroadcastingPrefecture(valueString: "not a prefecture"))
        XCTAssertNil(DataBroadcastingPrefecture(valueString: "14-101010101100"))
    }

    // MARK: - NVRAM

    func testNVRAMValuesUseTheWebClientsBase64Encoding() {
        let settings = DataBroadcastingSettings(
            zipCode: "123-4567",
            prefecture: DataBroadcastingPrefecture(valueString: "14-0b101010101100")!
        )
        // btoa("1234567") / btoa(String.fromCharCode(14)) / btoa("\x0a\xac")
        XCTAssertEqual(settings.nvramValues["zipcode"], "MTIzNDU2Nw==")
        XCTAssertEqual(settings.nvramValues["prefecture"], "Dg==")
        XCTAssertEqual(settings.nvramValues["regioncode"], "Cqw=")
    }

    func testNVRAMValuesAreEmptyWhenUnset() {
        XCTAssertTrue(DataBroadcastingSettings.defaults.nvramValues.isEmpty)
        let unset = DataBroadcastingSettings(zipCode: "123-4567")
        XCTAssertEqual(unset.nvramValues.keys.sorted(), ["zipcode"])
    }

    // MARK: - Persistence

    func testSettingsRoundTripThroughUserDefaults() throws {
        let suiteName = "DataBroadcastingSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Defaults of the web client.
        let loaded = DataBroadcastingSettings.load(from: defaults)
        XCTAssertTrue(loaded.isEnabled)
        XCTAssertFalse(loaded.allowsInternetAccess)
        XCTAssertEqual(loaded.zipCode, "")
        XCTAssertEqual(loaded.prefecture, .unset)

        var settings = loaded
        settings.isEnabled = false
        settings.allowsInternetAccess = true
        settings.zipCode = "001-0010"
        settings.prefecture = DataBroadcastingPrefecture.all.first { $0.number == 47 }!
        settings.save(to: defaults)

        XCTAssertEqual(DataBroadcastingSettings.load(from: defaults), settings)
        // The web client's local key names.
        XCTAssertEqual(defaults.object(forKey: "tv_show_data_broadcasting") as? Bool, false)
        XCTAssertEqual(
            defaults.object(forKey: "enable_internet_access_from_data_broadcasting") as? Bool,
            true
        )
        XCTAssertEqual(defaults.string(forKey: "data_broadcasting_zip_code"), "001-0010")
        XCTAssertEqual(
            defaults.string(forKey: "data_broadcasting_prefecture"),
            "47-0b110101000101"
        )
    }

    func testInvalidStoredZipCodeIsIgnored() throws {
        let suiteName = "DataBroadcastingSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("1234567", forKey: DataBroadcastingSettings.Key.zipCode)
        defaults.set("bogus", forKey: DataBroadcastingSettings.Key.prefecture)
        let loaded = DataBroadcastingSettings.load(from: defaults)
        XCTAssertEqual(loaded.zipCode, "")
        XCTAssertEqual(loaded.prefecture, .unset)
    }
}
