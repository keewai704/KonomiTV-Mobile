import SwiftUI
import UIKit

/// Supplies the interface orientations the app allows at the moment: all of
/// them, except while an iPhone shows the player in fullscreen (landscape).
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientationLock: UIInterfaceOrientationMask = .all

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        Self.orientationLock
    }
}

/// Turns an iPhone to landscape for the fullscreen player and back to
/// portrait afterwards. iPad windows keep whatever orientation they have.
@MainActor
enum PlayerOrientation {
    static func apply(fullscreen: Bool) {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }
        AppDelegate.orientationLock = fullscreen ? .landscape : .all
        let requested: UIInterfaceOrientationMask = fullscreen ? .landscape : .portrait
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows {
                window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: requested)) { error in
                AppLog.playback.debug("orientation request failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

extension View {
    /// The fullscreen player of a player screen: the bars, the tab bar, the
    /// status bar and the home indicator go away while the player fills the
    /// screen. Turning an iPhone to landscape enters it as well.
    func playerFullscreen(_ playback: PlaybackController) -> some View {
        modifier(PlayerFullscreenModifier(playback: playback))
    }
}

private struct PlayerFullscreenModifier: ViewModifier {
    let playback: PlaybackController

    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var isFullscreen: Bool { playback.isFullscreen }

    func body(content: Content) -> some View {
        content
            .toolbar(isFullscreen ? .hidden : .automatic, for: .navigationBar)
            .toolbar(isFullscreen ? .hidden : .automatic, for: .tabBar)
            .statusBarHidden(isFullscreen)
            .persistentSystemOverlays(isFullscreen ? .hidden : .automatic)
            .onChange(of: isFullscreen) { _, fullscreen in
                PlayerOrientation.apply(fullscreen: fullscreen)
            }
            .onChange(of: verticalSizeClass) { _, sizeClass in
                // An iPhone turned to landscape (the only compact height).
                if sizeClass == .compact, UIDevice.current.userInterfaceIdiom == .phone {
                    playback.isFullscreen = true
                }
            }
            .onDisappear {
                if playback.isFullscreen {
                    playback.isFullscreen = false
                    PlayerOrientation.apply(fullscreen: false)
                }
            }
    }
}
