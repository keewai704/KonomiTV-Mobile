import Foundation
import SwiftUI
import KonomiKit

/// バージョン情報: the server version, the latest release and the update
/// notice of the web client's VersionStore.
struct AboutScreen: View {
    let model: AppModel

    @State private var isRefreshing = false

    var body: some View {
        Form {
            if let version = model.version {
                Section("バージョン") {
                    LabeledContent("サーバーのバージョン", value: version.version)
                        .accessibilityIdentifier("settings.about.version")

                    LabeledContent(
                        "最新バージョン",
                        value: version.latestVersion ?? "不明"
                    )
                    .accessibilityIdentifier("settings.about.latestVersion")

                    if version.isUpdateAvailable {
                        Label(
                            "アップデートがあります (version \(version.latestVersion ?? ""))",
                            systemImage: "arrow.down.circle"
                        )
                        .font(.footnote)
                        .foregroundStyle(.tint)
                        .accessibilityIdentifier("settings.about.update")
                    }
                }

                Section("サーバー") {
                    LabeledContent("環境", value: version.environment)
                    LabeledContent("バックエンド", value: version.backend)
                    LabeledContent("エンコーダー", value: version.encoder)
                }
            } else {
                Section {
                    ProgressView("読み込み中…")
                }
            }

            // Third-party components that are copied into the app bundle.
            Section("ライセンス") {
                LabeledContent("libaribcaption", value: "MIT")
                    .accessibilityIdentifier("settings.about.license.aribcaption")

                LabeledContent("VLCKit 4 / libVLC", value: "LGPL-2.1（動的リンク）")
                    .accessibilityIdentifier("settings.about.license.vlckit")
            }

            Section {
                Button {
                    Task { await refresh() }
                } label: {
                    HStack(spacing: 8) {
                        Text("最新のバージョン情報を取得")
                        if isRefreshing {
                            Spacer(minLength: 0)
                            ProgressView()
                        }
                    }
                }
                .disabled(isRefreshing)
                .accessibilityIdentifier("settings.about.refresh")
            }
        }
        .navigationTitle("バージョン情報")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refresh() }
    }

    private func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await model.refreshVersion()
    }
}
