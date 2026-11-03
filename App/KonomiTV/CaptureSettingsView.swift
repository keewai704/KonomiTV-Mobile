import SwiftUI
import KonomiKit

/// 設定 → キャプチャ (the web client's Settings/Capture.vue).
///
/// The save mode, the caption mode and the filename pattern are synced client
/// settings; the clipboard option is local only (the web client has it
/// commented out of the synced keys too).
struct CaptureSettingsView: View {
    let model: AppModel

    @State private var filenamePattern = ""

    var body: some View {
        Form {
            Section {
                Picker("保存先", selection: saveModeBinding) {
                    Text("端末").tag(CaptureSaveMode.browser)
                    Text("KonomiTV サーバー").tag(CaptureSaveMode.uploadServer)
                    Text("両方").tag(CaptureSaveMode.both)
                }
                .accessibilityIdentifier("settings.capture.saveMode")

                Picker("字幕付きキャプチャ", selection: captionModeBinding) {
                    Text("映像のみ").tag(CaptureCaptionMode.videoOnly)
                    Text("字幕付き").tag(CaptureCaptionMode.compositingCaption)
                    Text("両方").tag(CaptureCaptionMode.both)
                }
                .accessibilityIdentifier("settings.capture.captionMode")

                Toggle("キャプチャをクリップボードにコピーする", isOn: copyToClipboardBinding)
                    .accessibilityIdentifier("settings.capture.copyToClipboard")
            }

            Section {
                TextField("Capture_%date%-%time%", text: $filenamePattern)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                    .accessibilityIdentifier("settings.capture.filename")

                Text(previewFilename)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings.capture.filenamePreview")
            } header: {
                Text("ファイル名")
            } footer: {
                Text("%date% %time% %channel-name% %event-name% などの置換語を使えます。")
            }
        }
        .navigationTitle("キャプチャ")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            filenamePattern = model.settings.captureFilenamePattern
        }
        .onChange(of: filenamePattern) { _, newValue in
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            model.mutateSettings { settings in
                settings.captureFilenamePattern = trimmed.isEmpty
                    ? CaptureSettingsDefaults.captureFilenamePattern
                    : trimmed
            }
        }
    }

    // MARK: - Bindings

    private var saveModeBinding: Binding<CaptureSaveMode> {
        Binding(
            get: { model.settings.captureSaveMode },
            set: { newValue in
                model.mutateSettings { settings in
                    settings.captureSaveMode = newValue
                }
            }
        )
    }

    private var captionModeBinding: Binding<CaptureCaptionMode> {
        Binding(
            get: { model.settings.captureCaptionMode },
            set: { newValue in
                model.mutateSettings { settings in
                    settings.captureCaptionMode = newValue
                }
            }
        )
    }

    private var copyToClipboardBinding: Binding<Bool> {
        Binding(
            get: { model.settings.captureCopyToClipboard },
            set: { newValue in
                model.mutateSettings { settings in
                    settings.captureCopyToClipboard = newValue
                }
            }
        )
    }

    /// Preview of the filename with the web client's sample program.
    private var previewFilename: String {
        let pattern = model.settings.captureFilenamePattern
        let start = Date(timeIntervalSince1970: 1711940400)   // 2024-04-01T12:00:00+09:00
        let context = CaptureFilenameContext(
            capturedAt: Date(),
            channelName: "アフリカ中央テレビ",
            serviceID: 1024,
            remoconID: 9,
            eventID: 65535,
            eventTitle: "[二][字]今日のニュース",
            eventStartTime: start,
            eventEndTime: start.addingTimeInterval(15 * 60)
        )
        return CaptureFilename.make(pattern: pattern, context: context) + ".jpg"
    }
}
