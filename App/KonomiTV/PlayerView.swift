import SwiftUI
import Foundation

/// Thin UIViewControllerRepresentable around the app wide
/// PlayerHostViewController, so the VLC drawable, the caption / comment
/// overlays and libVLC's picture-in-picture window are available.
///
/// Every player screen shows the one shared host view controller instead of
/// creating its own: that is what keeps picture in picture alive while the user
/// moves between screens. UIKit only allows one parent, so each representable
/// gets a small container that adopts the shared controller (and takes it over
/// from the container of an older screen when the two overlap during a layout
/// change).
struct PlayerRepresentable: UIViewControllerRepresentable {
    let playback: PlaybackController

    func makeUIViewController(context: Context) -> PlayerHostContainerViewController {
        PlayerHostContainerViewController(host: playback.hostViewController)
    }

    func updateUIViewController(_ uiViewController: PlayerHostContainerViewController, context: Context) {
        // The controller configures its shared host view controller itself.
    }

    static func dismantleUIViewController(
        _ uiViewController: PlayerHostContainerViewController,
        coordinator: ()
    ) {
        // Only detach when this container still owns it: during a layout change
        // the next screen's container may have taken it over already. SwiftUI
        // tears the view controller down on the main thread.
        MainActor.assumeIsolated {
            uiViewController.detachHostIfNeeded()
        }
    }
}

/// A container that adopts the app wide player host view controller.
///
/// SwiftUI creates one per player screen. Both screens of a layout change (the
/// tab bar and the sidebar interface, a rotation that replaces the navigation)
/// exist for one layout pass, so the new container takes the shared controller
/// over from the old one instead of asking UIKit to parent it twice (which is a
/// hard error) or leaving it in the old parent (which hides the video).
@MainActor
final class PlayerHostContainerViewController: UIViewController {
    private(set) var host: PlayerHostViewController?

    init(host: PlayerHostViewController) {
        self.host = host
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        // Transparent: the host's own view (and libVLC's video output) is what
        // the user sees.
        let root = UIView()
        root.backgroundColor = .clear
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        adoptHost()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        host?.view.frame = view.bounds
    }

    /// Takes the shared host view controller over from whichever parent it has.
    private func adoptHost() {
        guard let host else { return }
        if host.parent === self, host.view.superview === view {
            return
        }
        host.willMove(toParent: nil)
        host.view.removeFromSuperview()
        host.removeFromParent()

        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }

    /// Removes the shared host view controller from this container, unless a
    /// newer container already took it over.
    func detachHostIfNeeded() {
        guard let host = self.host else { return }
        self.host = nil
        guard host.parent === self else { return }
        host.willMove(toParent: nil)
        host.view.removeFromSuperview()
        host.removeFromParent()
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
