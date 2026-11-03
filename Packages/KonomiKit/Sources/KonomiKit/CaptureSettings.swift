import Foundation

/// Where the web client saves a capture (capture_save_mode).
///
/// Synced through client settings (SYNCABLE_SETTINGS_KEYS).
public enum CaptureSaveMode: String, Codable, CaseIterable, Sendable, Hashable {
    /// Download in the browser / save to the photo library / Files on iOS.
    case browser = "Browser"
    /// Upload to the KonomiTV server (POST /api/captures).
    case uploadServer = "UploadServer"
    /// Both.
    case both = "Both"

    public var savesToDevice: Bool { self == .browser || self == .both }
    public var uploadsToServer: Bool { self == .uploadServer || self == .both }
}

/// Which images are produced when a caption is on screen
/// (capture_caption_mode).
///
/// Synced through client settings.
public enum CaptureCaptionMode: String, Codable, CaseIterable, Sendable, Hashable {
    /// Only the video without the caption burned in. The caption text is still
    /// stored in the image metadata and returned as caption_text.
    case videoOnly = "VideoOnly"
    /// Only the image with the caption composited into it.
    case compositingCaption = "CompositingCaption"
    /// Both images (the web client's default).
    case both = "Both"

    public var producesVideoOnly: Bool { self == .videoOnly || self == .both }
    public var producesCaptionComposite: Bool { self == .compositingCaption || self == .both }
}

// MARK: - Client settings

extension ClientSettings {
    /// Where to save captures. Web default: .uploadServer. Synced.
    public var captureSaveMode: CaptureSaveMode {
        get {
            let raw = values["capture_save_mode"]?.stringValue ?? ""
            return CaptureSaveMode(rawValue: raw) ?? CaptureSettingsDefaults.captureSaveMode
        }
        set { self["capture_save_mode"] = .string(newValue.rawValue) }
    }

    /// Which images to produce when a caption is showing. Web default: .both.
    /// Synced.
    public var captureCaptionMode: CaptureCaptionMode {
        get {
            let raw = values["capture_caption_mode"]?.stringValue ?? ""
            return CaptureCaptionMode(rawValue: raw) ?? CaptureSettingsDefaults.captureCaptionMode
        }
        set { self["capture_caption_mode"] = .string(newValue.rawValue) }
    }

    /// Capture filename pattern. Web default: "Capture_%date%-%time%". Synced.
    /// Expand it with CaptureFilename.make(pattern:context:).
    public var captureFilenamePattern: String {
        get {
            values["capture_filename_pattern"]?.stringValue
                ?? CaptureSettingsDefaults.captureFilenamePattern
        }
        set { self["capture_filename_pattern"] = .string(newValue) }
    }

    /// Copy captures to the clipboard after saving. Web default: false.
    /// NOT synced (capture_copy_to_clipboard is commented out of
    /// SYNCABLE_SETTINGS_KEYS) - it is a per-device preference.
    public var captureCopyToClipboard: Bool {
        get {
            values["capture_copy_to_clipboard"]?.boolValue
                ?? CaptureSettingsDefaults.captureCopyToClipboard
        }
        set { self["capture_copy_to_clipboard"] = .bool(newValue) }
    }
}

/// Web client defaults for the capture settings keys.
public enum CaptureSettingsDefaults {
    public static let captureSaveMode: CaptureSaveMode = .uploadServer
    public static let captureCaptionMode: CaptureCaptionMode = .both
    public static let captureFilenamePattern = "Capture_%date%-%time%"
    public static let captureCopyToClipboard = false
}
