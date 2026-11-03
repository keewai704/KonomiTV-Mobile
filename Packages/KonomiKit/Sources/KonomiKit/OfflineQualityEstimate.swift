import Foundation

/// Encoder settings KonomiTV uses for one stream quality
/// (`server/app/constants.py`).
public struct OfflineStreamBitrates: Sendable, Hashable {
    /// Target average video bitrate (VBR).
    public let videoBitrateKbps: Int
    /// Upper bound of the video bitrate; used for the free space check.
    public let videoBitrateMaxKbps: Int
    public let audioBitrateKbps: Int

    public init(videoBitrateKbps: Int, videoBitrateMaxKbps: Int, audioBitrateKbps: Int) {
        self.videoBitrateKbps = videoBitrateKbps
        self.videoBitrateMaxKbps = videoBitrateMaxKbps
        self.audioBitrateKbps = audioBitrateKbps
    }
}

/// Quality names, size estimates and labels for offline saves.
///
/// This mirrors the web client's `services/OfflineVideos.ts` so an iOS save
/// shows the same labels and makes the same free space decision as the browser.
public enum OfflineQualityEstimate {

    /// Qualities the save picker offers, in server order. `original` is
    /// re-encoded on the server, so it can never be saved.
    public static let baseQualities: [StreamQuality] = StreamQuality.videoQualities

    /// Margin for the free space check (measured against the bitrate ceiling).
    public static let requiredStorageSizeMargin = 1.1
    /// Margin for the progress bar estimate (measured against the average).
    public static let jobProgressSizeMargin = 1.05
    /// VBR encoder targets are upper bounds: HEVC content usually lands lower.
    public static let vbrEffectiveVideoBitrateRatioHEVC = 0.75
    /// Same for AVC.
    public static let vbrEffectiveVideoBitrateRatioAVC = 0.85

    /// `server/app/constants.py` QUALITY (target and ceiling video bitrate,
    /// audio bitrate).
    public static let bitrates: [String: OfflineStreamBitrates] = [
        "1080p-60fps": OfflineStreamBitrates(videoBitrateKbps: 9500, videoBitrateMaxKbps: 13000, audioBitrateKbps: 256),
        "1080p-60fps-hevc": OfflineStreamBitrates(videoBitrateKbps: 3500, videoBitrateMaxKbps: 5200, audioBitrateKbps: 192),
        "1080p": OfflineStreamBitrates(videoBitrateKbps: 9500, videoBitrateMaxKbps: 13000, audioBitrateKbps: 256),
        "1080p-hevc": OfflineStreamBitrates(videoBitrateKbps: 3000, videoBitrateMaxKbps: 4500, audioBitrateKbps: 192),
        "810p": OfflineStreamBitrates(videoBitrateKbps: 5500, videoBitrateMaxKbps: 7600, audioBitrateKbps: 192),
        "810p-hevc": OfflineStreamBitrates(videoBitrateKbps: 2500, videoBitrateMaxKbps: 3700, audioBitrateKbps: 192),
        "720p": OfflineStreamBitrates(videoBitrateKbps: 4500, videoBitrateMaxKbps: 6200, audioBitrateKbps: 192),
        "720p-hevc": OfflineStreamBitrates(videoBitrateKbps: 2000, videoBitrateMaxKbps: 3000, audioBitrateKbps: 192),
        "540p": OfflineStreamBitrates(videoBitrateKbps: 3000, videoBitrateMaxKbps: 4100, audioBitrateKbps: 192),
        "540p-hevc": OfflineStreamBitrates(videoBitrateKbps: 1400, videoBitrateMaxKbps: 2100, audioBitrateKbps: 192),
        "480p": OfflineStreamBitrates(videoBitrateKbps: 2000, videoBitrateMaxKbps: 2800, audioBitrateKbps: 192),
        "480p-hevc": OfflineStreamBitrates(videoBitrateKbps: 1050, videoBitrateMaxKbps: 1750, audioBitrateKbps: 192),
        "360p": OfflineStreamBitrates(videoBitrateKbps: 1100, videoBitrateMaxKbps: 1800, audioBitrateKbps: 128),
        "360p-hevc": OfflineStreamBitrates(videoBitrateKbps: 750, videoBitrateMaxKbps: 1250, audioBitrateKbps: 128),
        "240p": OfflineStreamBitrates(videoBitrateKbps: 550, videoBitrateMaxKbps: 650, audioBitrateKbps: 128),
        "240p-hevc": OfflineStreamBitrates(videoBitrateKbps: 450, videoBitrateMaxKbps: 650, audioBitrateKbps: 128),
    ]

    // MARK: - Quality names

    /// API quality of a save: `<base>[-hevc][-24fps]`.
    ///
    /// The same rule as the web client's `buildAPIQuality`; `-24fps` is never
    /// appended to `1080p-60fps`.
    public static func apiQuality(
        base: StreamQuality,
        dataSaver: Bool,
        use24fps: Bool
    ) -> String {
        StreamingProfile(
            quality: base.videoSafe,
            dataSaver: dataSaver,
            use24fps: use24fps
        ).apiQuality()
    }

    /// Bitrates of an API quality, or nil for an unknown one.
    ///
    /// `-10bit` / `-24fps` do not change the bitrate, so they are dropped before
    /// the lookup.
    public static func streamBitrates(apiQuality: String) -> OfflineStreamBitrates? {
        let lookup = apiQuality
            .replacingOccurrences(of: "-10bit", with: "")
            .replacingOccurrences(of: "-24fps", with: "")
        if let bitrates = bitrates[lookup] {
            return bitrates
        }
        let base = lookup.replacingOccurrences(of: "-hevc", with: "")
        return bitrates[base]
    }

    /// Average bitrate (video target × VBR ratio + audio) in kbps. 0 for an
    /// unknown quality.
    public static func effectiveTotalBitrateKbps(apiQuality: String) -> Double {
        guard let bitrates = streamBitrates(apiQuality: apiQuality) else { return 0 }
        let ratio = apiQuality.contains("-hevc")
            ? vbrEffectiveVideoBitrateRatioHEVC
            : vbrEffectiveVideoBitrateRatioAVC
        return Double(bitrates.videoBitrateKbps) * ratio + Double(bitrates.audioBitrateKbps)
    }

    // MARK: - Size estimates

    /// Bytes the progress bar counts against: the VBR average with the web's
    /// small margin. nil for an unknown quality.
    public static func estimateJobSizeBytes(durationSeconds: Double, apiQuality: String) -> Int? {
        let totalKbps = effectiveTotalBitrateKbps(apiQuality: apiQuality)
        guard totalKbps > 0 else { return nil }
        return Int(ceil(totalKbps * 1000 * durationSeconds / 8 * jobProgressSizeMargin))
    }

    /// Bytes the free space check requires: the bitrate ceiling with the web's
    /// margin. nil for an unknown quality.
    public static func estimateRequiredStorageBytes(durationSeconds: Double, apiQuality: String) -> Int? {
        guard let bitrates = streamBitrates(apiQuality: apiQuality),
              bitrates.videoBitrateMaxKbps > 0 else {
            return nil
        }
        let totalKbps = Double(bitrates.videoBitrateMaxKbps + bitrates.audioBitrateKbps)
        return Int(ceil(totalKbps * 1000 * durationSeconds / 8 * requiredStorageSizeMargin))
    }

    /// Bytes shown in the quality picker (average bitrate, no margin).
    public static func estimateDisplaySizeBytes(durationSeconds: Double, apiQuality: String) -> Int {
        Int(ceil(effectiveTotalBitrateKbps(apiQuality: apiQuality) * 1000 * durationSeconds / 8))
    }

    // MARK: - Labels

    /// `約 2.2GB` for estimates, `340MB` for measured sizes.
    public static func formatOfflineSize(bytes: Int, approximate: Bool) -> String {
        let value = formatOfflineSizeValue(bytes: bytes, approximate: approximate)
        return approximate ? "約\(value)" : value
    }

    /// `4.9Mbps`.
    public static func formatAverageBitrateLabel(apiQuality: String) -> String {
        let mbps = effectiveTotalBitrateKbps(apiQuality: apiQuality) / 1000
        return String(format: "%.1fMbps", mbps)
    }

    /// `720p (約 2.2GB / 平均3.9Mbps)`.
    public static func formatQualitySelectLabel(
        base: StreamQuality,
        durationSeconds: Double,
        dataSaver: Bool
    ) -> String {
        let apiQuality = dataSaver ? "\(base.videoSafe.rawValue)-hevc" : base.videoSafe.rawValue
        let size = formatOfflineSize(
            bytes: estimateDisplaySizeBytes(durationSeconds: durationSeconds, apiQuality: apiQuality),
            approximate: true
        )
        let bitrate = formatAverageBitrateLabel(apiQuality: apiQuality)
        return "\(base.displayName) (\(size) / 平均\(bitrate))"
    }

    /// Display label of a saved API quality (`720p` for `720p-hevc-24fps`).
    public static func formatQualityLabel(apiQuality: String) -> String {
        guard let quality = StreamQuality(apiQuality: apiQuality) else {
            return apiQuality
        }
        return quality.displayName
    }

    /// `約 1.1GB`: the default (720p) size shown before the picker is opened.
    public static func defaultMenuSizeLabel(durationSeconds: Double, dataSaver: Bool) -> String {
        let apiQuality = dataSaver ? "720p-hevc" : "720p"
        return formatOfflineSize(
            bytes: estimateDisplaySizeBytes(durationSeconds: durationSeconds, apiQuality: apiQuality),
            approximate: true
        )
    }

    /// `Utils.formatBytes`: unit steps of 1024 with a fixed number of decimals.
    public static func formatBytes(_ bytes: Int, decimalPlaces: Int) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var amount = Double(max(bytes, 0))
        var unitIndex = 0
        while amount >= 1024, unitIndex < units.count - 1 {
            amount /= 1024
            unitIndex += 1
        }
        return String(format: "%.\(decimalPlaces)f%@", amount, units[unitIndex])
    }

    private static func formatOfflineSizeValue(bytes: Int, approximate: Bool) -> String {
        let oneMB = 1024 * 1024
        let oneGB = oneMB * 1024

        if bytes >= oneGB {
            return formatBytes(bytes, decimalPlaces: approximate ? 1 : 2)
        }
        if bytes >= oneMB {
            let megabytes = Double(bytes) / Double(oneMB)
            guard approximate else {
                return "\(Int(megabytes.rounded()))MB"
            }
            // Estimates are rounded to 10MB so the picker does not show 344MB.
            return "\(Int((megabytes / 10).rounded()) * 10)MB"
        }
        return formatBytes(bytes, decimalPlaces: approximate ? 1 : 0)
    }
}
