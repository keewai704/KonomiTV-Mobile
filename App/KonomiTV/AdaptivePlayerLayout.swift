import SwiftUI

/// Arranges a video player, optional content directly below it (the recorded
/// video scene strip) and its program information.
///
/// The arrangement follows the aspect ratio of the space this view measures
/// (the detail area, which is narrower than the window while the sidebar is
/// visible), never the device:
///
/// - An area wider than tall keeps the player on the left and the information
///   beside it, as long as the player keeps at least 55% of the width and the
///   information at least `minimumInfoWidth`. The player column is only as wide
///   as the height allows, so the 16:9 picture always fits.
/// - Otherwise (an area taller than wide, or too narrow for both) the player
///   goes on top and the information scrolls below it.
/// - Fullscreen leaves the information out and gives the player the whole
///   window; the player itself extends the picture under the bars and keeps
///   its controls inside the safe area.
///
/// The size is measured from the background, so the layout follows window
/// resizing (Split View, Stage Manager, rotation) even when the size class does
/// not change. Every arrangement shares one `AnyLayout` and one modifier chain
/// on the player, so switching keeps the player's identity: the player host
/// view controller is not recreated and playback continues.
struct AdaptivePlayerLayout<Player: View, BelowPlayer: View, Info: View>: View {
    private let isFullscreen: Bool
    private let player: Player
    private let belowPlayer: BelowPlayer
    private let info: Info

    @State private var size: CGSize = .zero

    init(
        isFullscreen: Bool = false,
        @ViewBuilder player: () -> Player,
        @ViewBuilder belowPlayer: () -> BelowPlayer,
        @ViewBuilder info: () -> Info
    ) {
        self.isFullscreen = isFullscreen
        self.player = player()
        self.belowPlayer = belowPlayer()
        self.info = info()
    }

    // Computed, because a generic type cannot hold a static stored property.
    private static var videoAspectRatio: CGFloat { 16.0 / 9.0 }
    /// Narrowest information column worth putting beside the player.
    private static var minimumInfoWidth: CGFloat { 300 }
    /// Share of the width the player keeps when the information sits beside it.
    private static var minimumPlayerWidthRatio: CGFloat { 0.55 }

    /// Side by side: the area is wider than tall and still leaves the
    /// information its minimum width beside a player of at least
    /// `minimumPlayerWidthRatio` of the width.
    private var isWide: Bool {
        guard !isFullscreen, size.width > 0, size.height > 0 else { return false }
        guard size.width > size.height else { return false }
        return size.width * (1 - Self.minimumPlayerWidthRatio) >= Self.minimumInfoWidth
    }

    /// The player column: its preferred share of the width, but never so wide
    /// that the 16:9 picture stops fitting the height or the information loses
    /// its minimum width.
    private var playerColumnWidth: CGFloat? {
        guard isWide else { return nil }
        let preferred = max(size.width * 0.65, 320)
        return min(preferred, size.height * Self.videoAspectRatio, size.width - Self.minimumInfoWidth)
    }

    /// Fullscreen fills the window; otherwise the player is 16:9.
    private var playerAspectRatio: CGFloat {
        guard isFullscreen, size.width > 0, size.height > 0 else {
            return Self.videoAspectRatio
        }
        return size.width / size.height
    }

    private var layout: AnyLayout {
        isWide
            ? AnyLayout(HStackLayout(alignment: .top, spacing: 0))
            : AnyLayout(VStackLayout(spacing: 0))
    }

    var body: some View {
        layout {
            VStack(spacing: 0) {
                player
                    .aspectRatio(playerAspectRatio, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .background(Color.black)

                if !isFullscreen {
                    belowPlayer
                }
            }
            .frame(width: playerColumnWidth)

            if !isFullscreen {
                ScrollView {
                    info
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(isWide ? 20 : 16)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: isFullscreen ? .center : .top)
        .background {
            if isFullscreen {
                Color.black.ignoresSafeArea()
            }
        }
        .background(sizeReader)
    }

    private var sizeReader: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear {
                    size = proxy.size
                }
                .onChange(of: proxy.size) { _, newValue in
                    size = newValue
                }
        }
    }
}
