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
            }
            .navigationTitle("KonomiTV")
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
