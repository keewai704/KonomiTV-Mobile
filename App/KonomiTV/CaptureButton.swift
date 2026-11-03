import KonomiKit
import SwiftUI

/// Player toolbar capture control: a tap captures the frame, a long press
/// offers the capture with the comments burned in (the web client's two
/// capture buttons, folded into one toolbar item).
struct CaptureButton: View {
    let playback: PlaybackController
    let settings: ClientSettings

    var body: some View {
        Menu {
            Button {
                playback.capture.capture(includeComments: true, settings: settings)
            } label: {
                Label("コメント付きでキャプチャ", systemImage: "text.bubble")
            }
            .accessibilityIdentifier("player.capture.comments")
        } label: {
            Label("キャプチャ", systemImage: "camera")
        } primaryAction: {
            playback.capture.capture(includeComments: false, settings: settings)
        }
        .accessibilityIdentifier("player.capture")
    }
}
