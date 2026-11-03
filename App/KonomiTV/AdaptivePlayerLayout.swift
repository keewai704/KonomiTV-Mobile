import SwiftUI

/// Arranges a video player and its program information.
///
/// Wide windows put the player on the left (about two thirds of the width)
/// with the information beside it; narrow windows stack the player above the
/// information. The available width is measured from the background, so the
/// layout follows window resizing (Split View, Stage Manager, rotation) even
/// when the size class does not change.
struct AdaptivePlayerLayout<Player: View, Info: View>: View {
    private let threshold: CGFloat
    private let player: Player
    private let info: Info

    @State private var width: CGFloat = 0

    init(
        threshold: CGFloat = 900,
        @ViewBuilder player: () -> Player,
        @ViewBuilder info: () -> Info
    ) {
        self.threshold = threshold
        self.player = player()
        self.info = info()
    }

    private var isWide: Bool { width >= threshold }

    var body: some View {
        Group {
            if isWide {
                wideLayout
            } else {
                narrowLayout
            }
        }
        .background(widthReader)
    }

    private var wideLayout: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 0) {
                player
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .background(Color.black)
                Spacer(minLength: 0)
            }
            .frame(width: max(width * 0.65, 320))

            Divider()

            ScrollView {
                info
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
        }
    }

    private var narrowLayout: some View {
        ScrollView {
            VStack(spacing: 16) {
                player
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .background(Color.black)

                info
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
            }
        }
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
