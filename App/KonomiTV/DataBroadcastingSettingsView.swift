import SwiftUI
import KonomiKit

/// 設定 → データ放送 (the web client's Settings/DataBroadcasting.vue).
///
/// Like the web client, none of these settings are synced with the server:
/// web-bml reads them from the client's local storage (`tv_show_data_broadcasting`
/// and `enable_internet_access_from_data_broadcasting` are 同期無効 in the web
/// client's SettingsStore), so the app keeps them in `UserDefaults` under the
/// same keys. The receiver information (ZIP code / prefecture) becomes web-bml's
/// NVRAM values, the same encoding the web client writes.
struct DataBroadcastingSettingsView: View {
    @AppStorage(PreferenceKeys.tvShowDataBroadcasting)
    private var isEnabled = DataBroadcastingSettings.defaults.isEnabled
    @AppStorage(PreferenceKeys.enableInternetAccessFromDataBroadcasting)
    private var allowsInternetAccess = DataBroadcastingSettings.defaults.allowsInternetAccess
    @AppStorage(PreferenceKeys.dataBroadcastingPrefecture)
    private var prefectureValue = DataBroadcastingSettings.defaults.prefecture.valueString

    @State private var zipCode = ""

    private var prefecture: DataBroadcastingPrefecture {
        DataBroadcastingPrefecture(valueString: prefectureValue)
            ?? DataBroadcastingSettings.defaults.prefecture
    }

    private var isZipCodeValid: Bool {
        DataBroadcastingSettings.isValidZipCode(zipCode)
    }

    var body: some View {
        Form {
            Section {
                Toggle("テレビをみるときにデータ放送を利用する", isOn: $isEnabled)
                    .accessibilityIdentifier("settings.dataBroadcasting.enabled")

                Toggle("データ放送からのインターネットアクセスを有効にする", isOn: $allowsInternetAccess)
                    .accessibilityIdentifier("settings.dataBroadcasting.internetAccess")
            } footer: {
                Text("オンにすると、双方向番組に参加できます。その一方で、視聴データがテレビ局に送信されることがあります。")
            }

            Section("受信機情報") {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("郵便番号", text: $zipCode)
                        .keyboardType(.numbersAndPunctuation)
                        .textContentType(.postalCode)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("settings.dataBroadcasting.zipCode")
                        .onAppear { zipCode = storedZipCode }
                        .onChange(of: zipCode) { _, newValue in
                            applyZipCode(newValue)
                        }
                    if !isZipCodeValid {
                        Text("郵便番号は「000-0000」の形式で入力してください。")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Picker("都道府県", selection: $prefectureValue) {
                    ForEach(DataBroadcastingPrefecture.all) { item in
                        Text(item.name).tag(item.valueString)
                    }
                }
                .accessibilityIdentifier("settings.dataBroadcasting.prefecture")
            }
        }
        .navigationTitle("データ放送")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: isEnabled) { _, _ in
            notifyChange()
        }
        .onChange(of: allowsInternetAccess) { _, _ in
            notifyChange()
        }
        .onChange(of: prefectureValue) { _, _ in
            notifyChange()
        }
    }

    // MARK: - ZIP code

    private var storedZipCode: String {
        UserDefaults.standard.string(forKey: DataBroadcastingSettings.Key.zipCode) ?? ""
    }

    /// Stores the ZIP code only while it is valid, so the page never gets a
    /// half typed value (the web client validates the same format).
    private func applyZipCode(_ value: String) {
        guard DataBroadcastingSettings.isValidZipCode(value) else { return }
        let defaults = UserDefaults.standard
        if value.isEmpty {
            defaults.removeObject(forKey: DataBroadcastingSettings.Key.zipCode)
        } else {
            defaults.set(value, forKey: DataBroadcastingSettings.Key.zipCode)
        }
        notifyChange()
    }

    /// Lets the running live player pick the change up.
    private func notifyChange() {
        NotificationCenter.default.post(name: .dataBroadcastingSettingsDidChange, object: nil)
    }
}
