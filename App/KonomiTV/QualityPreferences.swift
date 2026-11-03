import Foundation
import KonomiKit

/// Reads the local-only quality profile settings and turns them into a
/// `StreamingProfile` for a playback session.
///
/// The keys mirror the web client's Settings/Quality.vue and are intentionally
/// not synced with the server (ClientSettings has no fields for them).
enum QualityPreferences {
    // Web defaults (SettingsStore.ts).
    static let defaultTVQuality = StreamQuality.p1080
    static let defaultTVCellularQuality = StreamQuality.p480
    static let defaultTVDataSaver = false
    static let defaultTVDataSaverCellular = true
    static let defaultTVLowLatency = true
    static let defaultTVLowLatencyCellular = false
    static let defaultTV24fps = false
    static let defaultTV24fpsCellular = false

    static let defaultVideoQuality = StreamQuality.p1080
    static let defaultVideoCellularQuality = StreamQuality.p480
    static let defaultVideoDataSaver = false
    static let defaultVideoDataSaverCellular = true
    static let defaultVideo24fps = false
    static let defaultVideo24fpsCellular = false

    // MARK: - Profiles

    static func liveProfile(cellular: Bool, defaults: UserDefaults = .standard) -> StreamingProfile {
        StreamingProfile(
            quality: quality(
                forKey: cellular ? PreferenceKeys.tvStreamingQualityCellular : PreferenceKeys.tvStreamingQuality,
                fallback: cellular ? defaultTVCellularQuality : defaultTVQuality,
                allowingOriginal: true,
                defaults: defaults
            ),
            dataSaver: boolean(
                forKey: cellular ? PreferenceKeys.tvDataSaverModeCellular : PreferenceKeys.tvDataSaverMode,
                fallback: cellular ? defaultTVDataSaverCellular : defaultTVDataSaver,
                defaults: defaults
            ),
            use24fps: boolean(
                forKey: cellular ? PreferenceKeys.tv24fpsModeCellular : PreferenceKeys.tv24fpsMode,
                fallback: cellular ? defaultTV24fpsCellular : defaultTV24fps,
                defaults: defaults
            ),
            lowLatency: boolean(
                forKey: cellular ? PreferenceKeys.tvLowLatencyModeCellular : PreferenceKeys.tvLowLatencyMode,
                fallback: cellular ? defaultTVLowLatencyCellular : defaultTVLowLatency,
                defaults: defaults
            )
        )
    }

    static func videoProfile(cellular: Bool, defaults: UserDefaults = .standard) -> StreamingProfile {
        StreamingProfile(
            quality: quality(
                forKey: cellular ? PreferenceKeys.videoStreamingQualityCellular : PreferenceKeys.videoStreamingQuality,
                fallback: cellular ? defaultVideoCellularQuality : defaultVideoQuality,
                allowingOriginal: false,
                defaults: defaults
            ),
            dataSaver: boolean(
                forKey: cellular ? PreferenceKeys.videoDataSaverModeCellular : PreferenceKeys.videoDataSaverMode,
                fallback: cellular ? defaultVideoDataSaverCellular : defaultVideoDataSaver,
                defaults: defaults
            ),
            use24fps: boolean(
                forKey: cellular ? PreferenceKeys.video24fpsModeCellular : PreferenceKeys.video24fpsMode,
                fallback: cellular ? defaultVideo24fpsCellular : defaultVideo24fps,
                defaults: defaults
            )
        )
    }

    // MARK: - Migration

    /// Migrates the two legacy keys (`liveQuality` / `videoQuality`, which may
    /// be API names such as `1080p-hevc`) to the web key names and removes
    /// them.
    static func migrate(defaults: UserDefaults = .standard) {
        migrate(
            legacyKey: PreferenceKeys.legacyLiveQuality,
            qualityKey: PreferenceKeys.tvStreamingQuality,
            dataSaverKey: PreferenceKeys.tvDataSaverMode,
            fallback: defaultTVQuality,
            defaults: defaults
        )
        migrate(
            legacyKey: PreferenceKeys.legacyVideoQuality,
            qualityKey: PreferenceKeys.videoStreamingQuality,
            dataSaverKey: PreferenceKeys.videoDataSaverMode,
            fallback: defaultVideoQuality,
            defaults: defaults
        )
    }

    /// Removes every quality key (used together with the UI-testing reset).
    static func removeAll(defaults: UserDefaults = .standard) {
        for key in [
            PreferenceKeys.tvStreamingQuality,
            PreferenceKeys.tvStreamingQualityCellular,
            PreferenceKeys.tvDataSaverMode,
            PreferenceKeys.tvDataSaverModeCellular,
            PreferenceKeys.tvLowLatencyMode,
            PreferenceKeys.tvLowLatencyModeCellular,
            PreferenceKeys.tv24fpsMode,
            PreferenceKeys.tv24fpsModeCellular,
            PreferenceKeys.videoStreamingQuality,
            PreferenceKeys.videoStreamingQualityCellular,
            PreferenceKeys.videoDataSaverMode,
            PreferenceKeys.videoDataSaverModeCellular,
            PreferenceKeys.video24fpsMode,
            PreferenceKeys.video24fpsModeCellular,
            PreferenceKeys.legacyLiveQuality,
            PreferenceKeys.legacyVideoQuality,
        ] {
            defaults.removeObject(forKey: key)
        }
    }

    private static func migrate(
        legacyKey: String,
        qualityKey: String,
        dataSaverKey: String,
        fallback: StreamQuality,
        defaults: UserDefaults
    ) {
        guard let raw = defaults.string(forKey: legacyKey) else { return }
        if defaults.object(forKey: qualityKey) == nil {
            let base = StreamQuality(apiQuality: raw) ?? fallback
            defaults.set(base.rawValue, forKey: qualityKey)
            defaults.set(raw.contains("-hevc"), forKey: dataSaverKey)
        }
        defaults.removeObject(forKey: legacyKey)
    }

    // MARK: - Value readers

    private static func quality(
        forKey key: String,
        fallback: StreamQuality,
        allowingOriginal: Bool,
        defaults: UserDefaults
    ) -> StreamQuality {
        let raw = defaults.string(forKey: key)
        var value = raw.flatMap { StreamQuality(rawValue: $0) } ?? fallback
        if !allowingOriginal, value == .original {
            value = .p1080
        }
        return value
    }

    private static func boolean(
        forKey key: String,
        fallback: Bool,
        defaults: UserDefaults
    ) -> Bool {
        guard defaults.object(forKey: key) != nil else { return fallback }
        return defaults.bool(forKey: key)
    }
}
