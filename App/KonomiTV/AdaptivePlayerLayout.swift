import SwiftUI

/// Arranges a video player, optional content directly below it (the recorded
/// video scene strip) and its program information.
///
/// Wide windows put the player on the left (about two thirds of the width)
/// with the information beside it; narrow windows keep the player on top and
/// scroll the information below it. The available width is measured from the
/// background, so the layout follows window resizing (Split View, Stage
/// Manager, rotation) even when the size class does not change.
///
/// Both arrangements share one `AnyLayout`, so switching between them keeps
/// the player's identity: the `AVPlayerViewController` is not recreated and
/// playback continues while the window is resized.
struct AdaptivePlayerLayout<Player: View, BelowPlayer: View, Info: View>: View {
    private let threshold: CGFloat
    private let player: Player
    private let belowPlayer: BelowPlayer
    private let info: Info

    @State private var width: CGFloat = 0

    init(
        threshold: CGFloat = 900,
        @ViewBuilder player: () -> Player,
        @ViewBuilder belowPlayer: () -> BelowPlayer,
        @ViewBuilder info: () -> Info
    ) {
        self.threshold = threshold
        self.player = player()
        self.belowPlayer = belowPlayer()
        self.info = info()
    }

    private var isWide: Bool { width >= threshold }

    private var layout: AnyLayout {
        isWide
            ? AnyLayout(HStackLayout(alignment: .top, spacing: 0))
            : AnyLayout(VStackLayout(spacing: 0))
    }

    var body: some View {
        layout {
            VStack(spacing: 0) {
                player
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .background(Color.black)

                belowPlayer
            }
            .frame(width: isWide ? max(width * 0.65, 320) : nil)

            ScrollView {
                info
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(isWide ? 20 : 16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(widthReader)
    }

    private var widthReader: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear {
                    width = proxy.size.width
                }
                .onChange(of: proxy.size.width) { _, newValue in
                    width = newValue
                }
        }
    }
}
