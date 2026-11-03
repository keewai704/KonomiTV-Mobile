import Foundation

/// Video quality names accepted by KonomiTV's streaming endpoints.
///
/// Live streaming additionally accepts `original`; recorded-video playback
/// does not.
public enum StreamQuality: String, Codable, CaseIterable, Sendable, Hashable {
    case original = "original"

    case p1080p60 = "1080p-60fps"
    case p1080p60HEVC = "1080p-60fps-hevc"

    case p1080 = "1080p"
    case p1080HEVC = "1080p-hevc"

    case p720 = "720p"
    case p720HEVC = "720p-hevc"

    case p480 = "480p"
    case p480HEVC = "480p-hevc"

    case p360 = "360p"
    case p360HEVC = "360p-hevc"

    case p240 = "240p"
    case p240HEVC = "240p-hevc"

    public var isHEVC: Bool {
        rawValue.hasSuffix("-hevc")
    }

    public var isHighFrameRate: Bool {
        rawValue.contains("-60fps")
    }

    /// `original` is a live-only quality. Recorded-video URLs fall back to
    /// 1080p when `original` is requested.
    public var videoSafe: StreamQuality {
        self == .original ? .p1080 : self
    }

    public static var liveQualities: [StreamQuality] {
        allCases
    }

    public static var videoQualities: [StreamQuality] {
        allCases.filter { $0 != .original }
    }

    public var displayName: String {
        rawValue
    }
}
