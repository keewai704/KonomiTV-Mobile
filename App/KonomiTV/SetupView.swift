import SwiftUI
import KonomiKit

/// First run flow: enter the KonomiTV server URL and verify it via
/// `/api/version` before continuing.
struct SetupView: View {
    let model: AppModel

    @State private var urlText = ""
    @State private var isConnecting = false
    @State private var errorMessage: String?
    @FocusState private var isURLFieldFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("http://example.local:7000", text: $urlText)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .focused($isURLFieldFocused)
                        .onSubmit { connect() }
                        .accessibilityIdentifier("setup.urlField")

                    Button {
                        connect()
                    } label: {
                        HStack(spacing: 8) {
                            Text("接続")
                            if isConnecting {
                                Spacer(minLength: 0)
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isConnecting || trimmedURL.isEmpty)
                    .accessibilityIdentifier("setup.connectButton")
                } header: {
                    Text("サーバー")
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("setup.error")
                    }
                }

                // Saved videos do not need a server: keep them reachable from
                // the first run screen as well (only when there are any, so an
                // empty library does not add a row to the setup form).
                if model.offline.hasContent {
                    Section {
                        NavigationLink {
                            OfflineVideosScreen(model: model)
                        } label: {
                            Label("オフライン保存", systemImage: "arrow.down.circle")
                        }
                        .accessibilityIdentifier("setup.offline")
                    }
                }
            }
            .navigationTitle("KonomiTV")
            .navigationDestination(for: SectionRoute.self) { route in
                switch route {
                case .offline(let video):
                    OfflineVideoPlayerView(model: model, program: video)
                case .offlineList:
                    OfflineVideosScreen(model: model)
                default:
                    EmptyView()
                }
            }
        }
    }

    private var trimmedURL: String {
        urlText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func connect() {
        guard !isConnecting, !trimmedURL.isEmpty else { return }
        isURLFieldFocused = false
        isConnecting = true
        errorMessage = nil

        Task {
            do {
                try await model.connect(rawURL: trimmedURL)
            } catch {
                errorMessage = ErrorText.message(for: error)
            }
            isConnecting = false
        }
    }
}
