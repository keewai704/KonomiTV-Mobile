import Foundation

/// Base video quality names accepted by KonomiTV's streaming endpoints.
///
/// The API path component is not just this name: HEVC (data saver) and 24fps
/// mode append `-hevc` / `-24fps`. Use `StreamingProfile.apiQuality(isRadioChannel:)`
/// to build the value the server expects.
///
/// `original` is a live-only quality (the untouched MPEG-2 transport stream);
/// recorded-video playback falls back to 1080p when it is requested.
public enum StreamQuality: String, Codable, CaseIterable, Sendable, Hashable {
    case original = "original"

    case p1080p60 = "1080p-60fps"
    case p1080 = "1080p"
    case p810 = "810p"
    case p720 = "720p"
    case p540 = "540p"
    case p480 = "480p"
    case p360 = "360p"
    case p240 = "240p"

    /// True for the 60fps quality, which never gets the `-24fps` suffix.
    public var isHighFrameRate: Bool {
        self == .p1080p60
    }

    /// `original` is a live-only quality. Recorded-video URLs fall back to
    /// 1080p when `original` is requested.
    public var videoSafe: StreamQuality {
        self == .original ? .p1080 : self
    }

    /// Qualities offered for live playback, in server order.
    public static var liveQualities: [StreamQuality] {
        allCases
    }

    /// Qualities offered for recorded-video playback, in server order.
    public static var videoQualities: [StreamQuality] {
        allCases.filter { $0 != .original }
    }

    /// Label shown in the quality picker (the web client shows "1080p (60fps)").
    public var displayName: String {
        self == .p1080p60 ? "1080p (60fps)" : rawValue
    }

    /// Parses an API quality path component such as `720p-hevc-24fps` back to
    /// its base quality. Returns nil for unknown names.
    public init?(apiQuality: String) {
        var name = apiQuality
        for suffix in ["-24fps", "-10bit", "-hevc"] where name.hasSuffix(suffix) {
            name.removeLast(suffix.count)
        }
        self.init(rawValue: name)
    }
}

/// Everything that turns a base quality into the API quality path component.
///
/// Mirrors `build_api_quality` in the web client's PlayerController:
/// `<base>[-hevc][-24fps]`, where `-24fps` is never appended to
/// `1080p-60fps` and `original` never gets any suffix. `lowLatency` is a
/// client-side playback setting and is not part of the API name.
public struct StreamingProfile: Codable, Sendable, Hashable {
    public var quality: StreamQuality
    /// Data saver mode: request the HEVC variant (`-hevc`).
    public var dataSaver: Bool
    /// 24fps mode (`-24fps`), ignored for `1080p-60fps`.
    public var use24fps: Bool
    /// Low latency playback. Live only; consumed by the app, not the API.
    public var lowLatency: Bool

    public init(
        quality: StreamQuality = .p1080,
        dataSaver: Bool = false,
        use24fps: Bool = false,
        lowLatency: Bool = false
    ) {
        self.quality = quality
        self.dataSaver = dataSaver
        self.use24fps = use24fps
        self.lowLatency = lowLatency
    }

    public static let `default` = StreamingProfile()

    /// The quality path component the server expects.
    ///
    /// Radio channels have no video and the server only accepts 1080p for them
    /// (the actual stream is 48kHz/192kbps audio), so they always get `1080p`
    /// without any suffix.
    public func apiQuality(isRadioChannel: Bool = false) -> String {
        if isRadioChannel {
            return StreamQuality.p1080.rawValue
        }
        guard quality != .original else {
            return StreamQuality.original.rawValue
        }
        var name = quality.rawValue
        if dataSaver {
            name += "-hevc"
        }
        if use24fps, quality != .p1080p60 {
            name += "-24fps"
        }
        return name
    }
}

/// Playlist variant of `GET /api/streams/video/{id}/{quality}/playlist`.
///
/// `master` exposes 主音声 / 副音声 as an `EXT-X-MEDIA` audio group, which
/// the player can show natively.
public enum VideoPlaylistType: String, Codable, CaseIterable, Sendable, Hashable {
    case master
    case primaryAudio = "primary-audio"
    case secondaryAudio = "secondary-audio"
}

/// Audio track selector used by the video segment endpoint and by the live
/// transport-stream filter.
public enum AudioSelection: String, Codable, CaseIterable, Sendable, Hashable {
    case primary
    case secondary
}
