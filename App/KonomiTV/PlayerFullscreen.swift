import SwiftUI

extension View {
    /// The fullscreen player of a player screen: the bars, the tab bar, the
    /// status bar and the home indicator go away while the player fills the
    /// screen. A landscape window below the large short side
    /// (`WindowLayout.forcesFullscreenPlayer`, an iPhone turned sideways or a low
    /// Stage Manager window) is always fullscreen, with no button to leave it;
    /// other windows use the button.
    func playerFullscreen(_ playback: PlaybackController) -> some View {
        modifier(PlayerFullscreenModifier(playback: playback))
    }
}

private struct PlayerFullscreenModifier: ViewModifier {
    let playback: PlaybackController

    @Environment(\.windowLayout) private var windowLayout

    private var isFullscreen: Bool { playback.isFullscreen }

    func body(content: Content) -> some View {
        content
            .toolbar(isFullscreen ? .hidden : .automatic, for: .navigationBar)
            .toolbar(isFullscreen ? .hidden : .automatic, for: .tabBar)
            .statusBarHidden(isFullscreen)
            .persistentSystemOverlays(isFullscreen ? .hidden : .automatic)
            .onAppear {
                playback.isFullscreenForced = windowLayout.forcesFullscreenPlayer
            }
            .onChange(of: windowLayout.forcesFullscreenPlayer) { _, forced in
                playback.isFullscreenForced = forced
            }
            .onDisappear {
                playback.isFullscreenRequested = false
                playback.isFullscreenForced = false
            }
    }
}
