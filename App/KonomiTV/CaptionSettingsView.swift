import SwiftUI

/// 設定 → 字幕 (the web client's Settings/Caption.vue).
///
/// These are local-only settings, so they are stored with `@AppStorage` under
/// the web client's key names instead of the synced `ClientSettings`.
struct CaptionSettingsView: View {
    @AppStorage(PreferenceKeys.captionFont)
    private var captionFont = CaptionFont.hiraginoMaruGothic.rawValue
    @AppStorage(PreferenceKeys.alwaysBorderCaptionText)
    private var alwaysBorderCaptionText = true
    @AppStorage(PreferenceKeys.specifyCaptionOpacity)
    private var specifyCaptionOpacity = false
    @AppStorage(PreferenceKeys.captionOpacity)
    private var captionOpacity = 0.5
    @AppStorage(PreferenceKeys.tvShowSuperimpose)
    private var tvShowSuperimpose = true
    @AppStorage(PreferenceKeys.videoShowSuperimpose)
    private var videoShowSuperimpose = false

    var body: some View {
        Form {
            Section {
                Picker("字幕のフォント", selection: $captionFont) {
                    ForEach(CaptionFont.allCases) { font in
                        Text(font.title).tag(font.rawValue)
                    }
                }
                .accessibilityIdentifier("settings.captionFont")

                Toggle("常に字幕を縁取る", isOn: $alwaysBorderCaptionText)
                    .accessibilityIdentifier("settings.alwaysBorderCaptionText")
            }

            Section {
                Toggle("字幕の不透明度を指定する", isOn: $specifyCaptionOpacity)
                    .accessibilityIdentifier("settings.specifyCaptionOpacity")

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("字幕の不透明度")
                        Spacer(minLength: 0)
                        Text(captionOpacity.formatted(.percent.precision(.fractionLength(0))))
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $captionOpacity, in: 0...1, step: 0.05)
                        .accessibilityIdentifier("settings.captionOpacity")
                        .accessibilityLabel("字幕の不透明度")
                }
                .disabled(!specifyCaptionOpacity)
            }

            Section {
                Toggle("テレビで文字スーパーを表示する", isOn: $tvShowSuperimpose)
                    .accessibilityIdentifier("settings.tvShowSuperimpose")

                Toggle("ビデオで文字スーパーを表示する", isOn: $videoShowSuperimpose)
                    .accessibilityIdentifier("settings.videoShowSuperimpose")
            }
        }
        .navigationTitle("字幕")
        .navigationBarTitleDisplayMode(.inline)
    }
}
