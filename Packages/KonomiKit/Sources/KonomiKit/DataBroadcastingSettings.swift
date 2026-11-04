import Foundation

// MARK: - Prefecture

/// お住まいの都道府県 of the data broadcasting settings.
///
/// Mirrors the table of the web client's Settings/DataBroadcasting.vue: the
/// value stored in the local settings (and in web-bml's NVRAM) is
/// `<prefecture number>-0b<12 bit region code>`.
public struct DataBroadcastingPrefecture: Sendable, Hashable, Identifiable {
    /// ARIB 都道府県番号. 255 means "未設定" (unset).
    public let number: Int
    /// 12 bit 地域コード (bit field of the ARIB receiver information).
    public let regionCode: Int
    public let name: String

    public var id: Int { number }

    public init(number: Int, regionCode: Int, name: String) {
        self.number = number
        self.regionCode = regionCode
        self.name = name
    }

    /// Unset value: `255-0b0` (web-bml reads 0xFF for it).
    public static let unset = DataBroadcastingPrefecture(number: 255, regionCode: 0, name: "未設定")

    /// The web client's prefecture list, in its order.
    public static let all: [DataBroadcastingPrefecture] = [
        .unset,
        DataBroadcastingPrefecture(number: 2, regionCode: 0b000101101011, name: "西北海道"),
        DataBroadcastingPrefecture(number: 1, regionCode: 0b000101101011, name: "東北海道"),
        DataBroadcastingPrefecture(number: 3, regionCode: 0b010001100111, name: "青森県"),
        DataBroadcastingPrefecture(number: 4, regionCode: 0b010111010100, name: "岩手県"),
        DataBroadcastingPrefecture(number: 5, regionCode: 0b011101011000, name: "宮城県"),
        DataBroadcastingPrefecture(number: 6, regionCode: 0b101011000110, name: "秋田県"),
        DataBroadcastingPrefecture(number: 7, regionCode: 0b111001001100, name: "山形県"),
        DataBroadcastingPrefecture(number: 8, regionCode: 0b000110101110, name: "福島県"),
        DataBroadcastingPrefecture(number: 9, regionCode: 0b110001101001, name: "茨城県"),
        DataBroadcastingPrefecture(number: 10, regionCode: 0b111000111000, name: "栃木県"),
        DataBroadcastingPrefecture(number: 11, regionCode: 0b100110001011, name: "群馬県"),
        DataBroadcastingPrefecture(number: 12, regionCode: 0b011001001011, name: "埼玉県"),
        DataBroadcastingPrefecture(number: 13, regionCode: 0b000111000111, name: "千葉県"),
        DataBroadcastingPrefecture(number: 14, regionCode: 0b101010101100, name: "東京都 (島部を除く)"),
        DataBroadcastingPrefecture(number: 49, regionCode: 0b101010101100, name: "東京都島部 (伊豆・小笠原諸島)"),
        DataBroadcastingPrefecture(number: 15, regionCode: 0b010101101100, name: "神奈川県"),
        DataBroadcastingPrefecture(number: 16, regionCode: 0b010011001110, name: "新潟県"),
        DataBroadcastingPrefecture(number: 17, regionCode: 0b010100111001, name: "富山県"),
        DataBroadcastingPrefecture(number: 18, regionCode: 0b011010100110, name: "石川県"),
        DataBroadcastingPrefecture(number: 19, regionCode: 0b100100101101, name: "福井県"),
        DataBroadcastingPrefecture(number: 20, regionCode: 0b110101001010, name: "山梨県"),
        DataBroadcastingPrefecture(number: 21, regionCode: 0b100111010010, name: "長野県"),
        DataBroadcastingPrefecture(number: 22, regionCode: 0b101001100101, name: "岐阜県"),
        DataBroadcastingPrefecture(number: 23, regionCode: 0b101001011010, name: "静岡県"),
        DataBroadcastingPrefecture(number: 24, regionCode: 0b100101100110, name: "愛知県"),
        DataBroadcastingPrefecture(number: 25, regionCode: 0b001011011100, name: "三重県"),
        DataBroadcastingPrefecture(number: 26, regionCode: 0b110011100100, name: "滋賀県"),
        DataBroadcastingPrefecture(number: 27, regionCode: 0b010110011010, name: "京都府"),
        DataBroadcastingPrefecture(number: 28, regionCode: 0b110010110010, name: "大阪府"),
        DataBroadcastingPrefecture(number: 29, regionCode: 0b011001110100, name: "兵庫県"),
        DataBroadcastingPrefecture(number: 30, regionCode: 0b101010010011, name: "奈良県"),
        DataBroadcastingPrefecture(number: 31, regionCode: 0b001110010110, name: "和歌山県"),
        DataBroadcastingPrefecture(number: 32, regionCode: 0b110100100011, name: "鳥取県"),
        DataBroadcastingPrefecture(number: 33, regionCode: 0b001100011011, name: "島根県"),
        DataBroadcastingPrefecture(number: 34, regionCode: 0b001010110101, name: "岡山県"),
        DataBroadcastingPrefecture(number: 35, regionCode: 0b101100110001, name: "広島県"),
        DataBroadcastingPrefecture(number: 36, regionCode: 0b101110011000, name: "山口県"),
        DataBroadcastingPrefecture(number: 37, regionCode: 0b111001100010, name: "徳島県"),
        DataBroadcastingPrefecture(number: 38, regionCode: 0b100110110100, name: "香川県"),
        DataBroadcastingPrefecture(number: 39, regionCode: 0b000110011101, name: "愛媛県"),
        DataBroadcastingPrefecture(number: 40, regionCode: 0b001011100011, name: "高知県"),
        DataBroadcastingPrefecture(number: 41, regionCode: 0b011000101101, name: "福岡県"),
        DataBroadcastingPrefecture(number: 42, regionCode: 0b100101011001, name: "佐賀県"),
        DataBroadcastingPrefecture(number: 43, regionCode: 0b101000101011, name: "長崎県"),
        DataBroadcastingPrefecture(number: 44, regionCode: 0b100010100111, name: "熊本県"),
        DataBroadcastingPrefecture(number: 45, regionCode: 0b110010001101, name: "大分県"),
        DataBroadcastingPrefecture(number: 46, regionCode: 0b110100011100, name: "宮崎県"),
        DataBroadcastingPrefecture(number: 47, regionCode: 0b110101000101, name: "鹿児島県 (南西諸島を除く)"),
        DataBroadcastingPrefecture(number: 50, regionCode: 0b110101000101, name: "鹿児島県島部 (南西諸島の鹿児島県域)"),
        DataBroadcastingPrefecture(number: 48, regionCode: 0b001101110010, name: "沖縄県"),
    ]

    /// The value the local settings store (the web client's select value).
    public var valueString: String {
        guard number != DataBroadcastingPrefecture.unset.number else { return "255-0b0" }
        return "\(number)-0b\(zeroPaddedBinary(regionCode, width: 12))"
    }

    /// Parses `14-0b101010101100` back to a prefecture. Unknown values return
    /// nil, so a stale setting falls back to 未設定.
    public init?(valueString: String) {
        if valueString == "255-0b0" {
            self = .unset
            return
        }
        let parts = valueString.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let number = Int(parts[0]) else { return nil }
        let bits = parts[1]
        guard bits.hasPrefix("0b"), let regionCode = Int(bits.dropFirst(2), radix: 2) else {
            return nil
        }
        // An unknown but well formed value keeps its numbers instead of being
        // dropped, so a future prefecture still round trips.
        self = DataBroadcastingPrefecture.match(number: number, regionCode: regionCode)
            ?? DataBroadcastingPrefecture(number: number, regionCode: regionCode, name: "")
    }

    /// The entry of `all` with these numbers, if there is one.
    public static func match(number: Int, regionCode: Int) -> DataBroadcastingPrefecture? {
        all.first { $0.number == number && $0.regionCode == regionCode }
    }
}

/// `value` in binary with leading zeros (the web client's `0b` region code).
private func zeroPaddedBinary(_ value: Int, width: Int) -> String {
    let digits = String(value, radix: 2)
    return String(repeating: "0", count: Swift.max(width - digits.count, 0)) + digits
}

// MARK: - Settings

/// 設定 → データ放送 (the web client's Settings/DataBroadcasting.vue).
///
/// Like the web client, none of these values are synced with the server: the
/// web client keeps them in localStorage (they are listed as 同期無効 in its
/// SettingsStore), so the app keeps them in `UserDefaults` under the web
/// client's key names.
public struct DataBroadcastingSettings: Sendable, Hashable {
    /// テレビをみるときにデータ放送機能を利用する (tv_show_data_broadcasting).
    public var isEnabled: Bool
    /// データ放送からのインターネットアクセスを有効にする
    /// (enable_internet_access_from_data_broadcasting).
    public var allowsInternetAccess: Bool
    /// お住まいの郵便番号 (`123-4567`, empty when unset).
    public var zipCode: String
    /// お住まいの都道府県.
    public var prefecture: DataBroadcastingPrefecture

    public init(
        isEnabled: Bool = true,
        allowsInternetAccess: Bool = false,
        zipCode: String = "",
        prefecture: DataBroadcastingPrefecture = .unset
    ) {
        self.isEnabled = isEnabled
        self.allowsInternetAccess = allowsInternetAccess
        self.zipCode = zipCode
        self.prefecture = prefecture
    }

    /// The web client's defaults (SettingsStore.ts): data broadcasting on,
    /// internet access off, receiver information unset.
    public static let defaults = DataBroadcastingSettings()

    // MARK: Keys

    public enum Key {
        public static let isEnabled = "tv_show_data_broadcasting"
        public static let allowsInternetAccess = "enable_internet_access_from_data_broadcasting"
        public static let zipCode = "data_broadcasting_zip_code"
        public static let prefecture = "data_broadcasting_prefecture"
    }

    // MARK: Persistence

    public static func load(from defaults: UserDefaults) -> DataBroadcastingSettings {
        var settings = DataBroadcastingSettings.defaults
        if defaults.object(forKey: Key.isEnabled) != nil {
            settings.isEnabled = defaults.bool(forKey: Key.isEnabled)
        }
        if defaults.object(forKey: Key.allowsInternetAccess) != nil {
            settings.allowsInternetAccess = defaults.bool(forKey: Key.allowsInternetAccess)
        }
        if let zipCode = defaults.string(forKey: Key.zipCode),
           DataBroadcastingSettings.isValidZipCode(zipCode) {
            settings.zipCode = zipCode
        }
        if let raw = defaults.string(forKey: Key.prefecture),
           let prefecture = DataBroadcastingPrefecture(valueString: raw) {
            settings.prefecture = prefecture
        }
        return settings
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(isEnabled, forKey: Key.isEnabled)
        defaults.set(allowsInternetAccess, forKey: Key.allowsInternetAccess)
        if zipCode.isEmpty {
            defaults.removeObject(forKey: Key.zipCode)
        } else {
            defaults.set(zipCode, forKey: Key.zipCode)
        }
        defaults.set(prefecture.valueString, forKey: Key.prefecture)
    }

    // MARK: Validation

    /// The web client accepts `000-0000` or nothing at all.
    public static func isValidZipCode(_ value: String) -> Bool {
        if value.isEmpty { return true }
        return value.range(of: "^[0-9]{3}-[0-9]{4}$", options: .regularExpression) != nil
    }

    /// ZIP code as web-bml's NVRAM stores it: the seven digits without the
    /// hyphen (empty when unset).
    public var zipCodeDigits: String {
        zipCode.replacingOccurrences(of: "-", with: "")
    }

    // MARK: web-bml NVRAM

    /// Values web-bml reads from `nvram://receiverinfo/...`.
    ///
    /// The keys are the NVRAM names and the values are base64 of the raw
    /// bytes, exactly what the web client writes to localStorage as
    /// `KonomiTV-BMLBrowser_nvram_prefix=receiverinfo%2F<name>`.
    public var nvramValues: [String: String] {
        var values: [String: String] = [:]
        if zipCodeDigits.range(of: "^[0-9]{7}$", options: .regularExpression) != nil {
            values["zipcode"] = Data(zipCodeDigits.utf8).base64EncodedString()
        }
        if prefecture.number != DataBroadcastingPrefecture.unset.number {
            values["prefecture"] = Data([UInt8(clamping: prefecture.number)]).base64EncodedString()
            let regionCode = UInt16(clamping: prefecture.regionCode)
            values["regioncode"] = Data([
                UInt8((regionCode >> 8) & 0xFF),
                UInt8(regionCode & 0xFF),
            ]).base64EncodedString()
        }
        return values
    }
}
