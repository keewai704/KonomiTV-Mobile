import SwiftUI
import AVKit
import Foundation
import UIKit

/// Thin UIViewControllerRepresentable around the app wide
/// AVPlayerViewController, so the standard playback controls, AirPlay, Now
/// Playing info and picture in picture are available.
///
/// It returns the existing controller instance instead of creating a new one:
/// that is what keeps picture in picture alive while the user moves between
/// screens.
struct PlayerRepresentable: UIViewControllerRepresentable {
    let playback: PlaybackController

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        playback.playerViewController
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        // The controller configures its shared player view controller itself.
    }
}

/// Player plus an invisible status label that UI tests can read.
struct PlayerView: View {
    let playback: PlaybackController

    var body: some View {
        ZStack {
            PlayerRepresentable(playback: playback)
                .accessibilityIdentifier("player.view")

            captureNotice

            Text(playback.state)
                .font(.system(size: 1))
                .opacity(0.01)
                .accessibilityLabel(playback.state)
                .accessibilityValue(playback.errorDetail ?? playback.state)
                .accessibilityIdentifier("player.state")
                .allowsHitTesting(false)
        }
        .background(Color.black)
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
}

