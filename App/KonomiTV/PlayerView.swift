import SwiftUI
import Foundation

/// Thin UIViewControllerRepresentable around the app wide
/// PlayerHostViewController, so the VLC drawable, the caption / comment
/// overlays and libVLC's picture-in-picture window are available.
///
/// It returns the existing controller instance instead of creating a new one:
/// that is what keeps picture in picture alive while the user moves between
/// screens.
struct PlayerRepresentable: UIViewControllerRepresentable {
    let playback: PlaybackController

    func makeUIViewController(context: Context) -> PlayerHostViewController {
        playback.hostViewController
    }

    func updateUIViewController(_ uiViewController: PlayerHostViewController, context: Context) {
        // The controller configures its shared host view controller itself.
    }
}

/// Player plus the transport controls and an invisible status label that UI
/// tests can read.
///
/// Tapping the picture shows and hides the controls; they hide themselves
/// after a few seconds while playback runs (`LaunchOptions.controlsAutoHideDelay`),
/// and stay on screen while paused.
struct PlayerView: View {
    let playback: PlaybackController

    @State private var areControlsVisible = true
    @State private var autoHideTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            // In fullscreen the picture extends under the status bar, the
            // Dynamic Island and the home indicator; the controls stay inside
            // the safe area.
            PlayerRepresentable(playback: playback)
                .ignoresSafeArea(edges: playback.isFullscreen ? .all : [])
                .accessibilityIdentifier("player.view")

            tapSurface

            if areControlsVisible, !playback.isPictureInPictureActive {
                PlayerTransportControls(playback: playback, onInteraction: revealControls)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("player.controls")
                    .transition(.opacity)
            }

            captureNotice

            statusLabel
        }
        .background {
            Color.black.ignoresSafeArea(edges: playback.isFullscreen ? .all : [])
        }
        .animation(.easeInOut(duration: 0.2), value: areControlsVisible)
        .onAppear { scheduleAutoHide() }
        .onDisappear { autoHideTask?.cancel() }
        .onChange(of: playback.isPlaying) { _, isPlaying in
            if isPlaying {
                scheduleAutoHide()
            } else {
                autoHideTask?.cancel()
                areControlsVisible = true
            }
        }
    }

    /// Tapping the picture toggles the controls. It sits below them, so a tap
    /// on a button never reaches it.
    private var tapSurface: some View {
        Button {
            if areControlsVisible {
                autoHideTask?.cancel()
                areControlsVisible = false
            } else {
                revealControls()
            }
        } label: {
            Color.clear
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("player.surface")
        .accessibilityLabel("再生コントロール")
    }

    /// Transient message of the capture pipeline ("保存しました", "ラジオ
    /// チャンネルはキャプチャできません。" and so on).
    @ViewBuilder
    private var captureNotice: some View {
        if let notice = playback.capture.notice {
            VStack {
                Spacer(minLength: 0)
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.black.opacity(0.7), in: Capsule())
                    .padding(.bottom, 16)
            }
            .allowsHitTesting(false)
            .accessibilityIdentifier("capture.notice")
            .accessibilityLabel(notice)
        }
    }

    private var statusLabel: some View {
        Text(playback.state)
            .font(.system(size: 1))
            .opacity(0.01)
            .accessibilityLabel(playback.state)
            .accessibilityValue(playback.errorDetail ?? playback.state)
            .accessibilityIdentifier("player.state")
            .allowsHitTesting(false)
    }

    // MARK: - Controls visibility

    private func revealControls() {
        areControlsVisible = true
        scheduleAutoHide()
    }

    private func scheduleAutoHide() {
        autoHideTask?.cancel()
        guard playback.isPlaying, let delay = playback.controlsAutoHideDelay else { return }
        autoHideTask = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            areControlsVisible = false
        }
    }
}
