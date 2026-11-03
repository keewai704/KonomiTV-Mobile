import SwiftUI
import KonomiKit

/// 画質: the local-only streaming quality profile settings, split into テレビ
/// and ビデオ groups and their モバイル回線 variants (Settings/Quality.vue).
struct QualitySettingsView: View {
    @AppStorage(PreferenceKeys.tvStreamingQuality)
    private var tvQuality = QualityPreferences.defaultTVQuality.rawValue
    @AppStorage(PreferenceKeys.tvDataSaverMode)
    private var tvDataSaver = QualityPreferences.defaultTVDataSaver
    @AppStorage(PreferenceKeys.tvLowLatencyMode)
    private var tvLowLatency = QualityPreferences.defaultTVLowLatency
    @AppStorage(PreferenceKeys.tv24fpsMode)
    private var tv24fps = QualityPreferences.defaultTV24fps

    @AppStorage(PreferenceKeys.tvStreamingQualityCellular)
    private var tvQualityCellular = QualityPreferences.defaultTVCellularQuality.rawValue
    @AppStorage(PreferenceKeys.tvDataSaverModeCellular)
    private var tvDataSaverCellular = QualityPreferences.defaultTVDataSaverCellular
    @AppStorage(PreferenceKeys.tvLowLatencyModeCellular)
    private var tvLowLatencyCellular = QualityPreferences.defaultTVLowLatencyCellular
    @AppStorage(PreferenceKeys.tv24fpsModeCellular)
    private var tv24fpsCellular = QualityPreferences.defaultTV24fpsCellular

    @AppStorage(PreferenceKeys.videoStreamingQuality)
    private var videoQuality = QualityPreferences.defaultVideoQuality.rawValue
    @AppStorage(PreferenceKeys.videoDataSaverMode)
    private var videoDataSaver = QualityPreferences.defaultVideoDataSaver
    @AppStorage(PreferenceKeys.video24fpsMode)
    private var video24fps = QualityPreferences.defaultVideo24fps

    @AppStorage(PreferenceKeys.videoStreamingQualityCellular)
    private var videoQualityCellular = QualityPreferences.defaultVideoCellularQuality.rawValue
    @AppStorage(PreferenceKeys.videoDataSaverModeCellular)
    private var videoDataSaverCellular = QualityPreferences.defaultVideoDataSaverCellular
    @AppStorage(PreferenceKeys.video24fpsModeCellular)
    private var video24fpsCellular = QualityPreferences.defaultVideo24fpsCellular

    var body: some View {
        Form {
            Section("テレビ") {
                qualityPicker(
                    "画質",
                    selection: $tvQuality,
                    qualities: StreamQuality.liveQualities,
                    identifier: "settings.tvQuality"
                )
                Toggle("データ節約モード", isOn: $tvDataSaver)
                    .accessibilityIdentifier("settings.tvDataSaver")
                Toggle("低遅延モード", isOn: $tvLowLatency)
                    .accessibilityIdentifier("settings.tvLowLatency")
                Toggle("24fps モード", isOn: $tv24fps)
                    .accessibilityIdentifier("settings.tv24fps")
            }

            Section("テレビ（モバイル回線）") {
                qualityPicker(
                    "画質",
                    selection: $tvQualityCellular,
                    qualities: StreamQuality.liveQualities,
                    identifier: "settings.tvQualityCellular"
                )
                Toggle("データ節約モード", isOn: $tvDataSaverCellular)
                    .accessibilityIdentifier("settings.tvDataSaverCellular")
                Toggle("低遅延モード", isOn: $tvLowLatencyCellular)
                    .accessibilityIdentifier("settings.tvLowLatencyCellular")
                Toggle("24fps モード", isOn: $tv24fpsCellular)
                    .accessibilityIdentifier("settings.tv24fpsCellular")
            }

            Section("ビデオ") {
                qualityPicker(
                    "画質",
                    selection: $videoQuality,
                    qualities: StreamQuality.videoQualities,
                    identifier: "settings.videoQuality"
                )
                Toggle("データ節約モード", isOn: $videoDataSaver)
                    .accessibilityIdentifier("settings.videoDataSaver")
                Toggle("24fps モード", isOn: $video24fps)
                    .accessibilityIdentifier("settings.video24fps")
            }

            Section("ビデオ（モバイル回線）") {
                qualityPicker(
                    "画質",
                    selection: $videoQualityCellular,
                    qualities: StreamQuality.videoQualities,
                    identifier: "settings.videoQualityCellular"
                )
                Toggle("データ節約モード", isOn: $videoDataSaverCellular)
                    .accessibilityIdentifier("settings.videoDataSaverCellular")
                Toggle("24fps モード", isOn: $video24fpsCellular)
                    .accessibilityIdentifier("settings.video24fpsCellular")
            }
        }
        .navigationTitle("画質")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: tvDataSaver) { _, enabled in
            // Data saver has no HEVC variant of Original (MPEG-2).
            if enabled, tvQuality == StreamQuality.original.rawValue {
                tvQuality = StreamQuality.p1080p60.rawValue
            }
        }
        .onChange(of: tvQuality) { _, raw in
            if tvDataSaver, raw == StreamQuality.original.rawValue {
                tvQuality = StreamQuality.p1080p60.rawValue
            }
        }
        .onChange(of: tvQualityCellular) { _, raw in
            if tvDataSaverCellular, raw == StreamQuality.original.rawValue {
                tvQualityCellular = StreamQuality.p1080p60.rawValue
            }
        }
    }

    private func qualityPicker(
        _ title: String,
        selection: Binding<String>,
        qualities: [StreamQuality],
        identifier: String
    ) -> some View {
        Picker(title, selection: selection) {
            ForEach(qualities, id: \.self) { quality in
                Text(quality.displayName).tag(quality.rawValue)
            }
        }
        .pickerStyle(.navigationLink)
        .accessibilityIdentifier(identifier)
    }
}
