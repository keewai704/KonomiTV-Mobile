import AVKit
import SwiftUI

/// The inline transport controls of the app-wide player.
///
/// `AVPlayerViewController` used to draw these. They are native SwiftUI on top
/// of the VLC drawable now: play / pause, ±10 s and ±30 s skips on recorded and
/// saved video, a seek bar with elapsed and remaining time, the ライブ button on
/// live channels (live shows no clock: it always plays the newest part), mute,
/// the AirPlay route picker, picture in picture and fullscreen.
/// Layout only depends on what the item offers, never on the device type.
struct PlayerTransportControls: View {
    let playback: PlaybackController
    /// Called for every interaction so the auto-hide timer restarts.
    let onInteraction: () -> Void

    @State private var isScrubbing = false
    @State private var scrubPosition: Double = 0

    var body: some View {
        VStack(spacing: 6) {
            topRow
            Spacer(minLength: 0)
            bottomRow
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background {
            LinearGradient(
                colors: [
                    .black.opacity(0.55),
                    .black.opacity(0.05),
                    .black.opacity(0.65),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)
        }
    }

    // MARK: - Rows

    private var topRow: some View {
        HStack(spacing: 18) {
            fullscreenButton
            Spacer(minLength: 0)
            muteButton
            airPlayPicker
            if playback.isPictureInPictureSupported {
                pictureInPictureButton
            }
        }
    }

    @ViewBuilder
    private var bottomRow: some View {
        if playback.canSeek {
            videoBottomRow
        } else {
            // Live: the ライブ button on the leading edge, play / pause in the
            // middle of the row.
            ZStack {
                playPauseButton
                HStack {
                    liveEdgeButton
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var videoBottomRow: some View {
        VStack(spacing: 6) {
            seekRow
            HStack(spacing: 16) {
                skipButton(
                    seconds: -30,
                    symbol: "gobackward.30",
                    identifier: "player.skipBack30",
                    label: "30秒戻る"
                )
                skipButton(
                    seconds: -10,
                    symbol: "gobackward.10",
                    identifier: "player.skipBack",
                    label: "10秒戻る"
                )

                Spacer(minLength: 0)
                playPauseButton
                Spacer(minLength: 0)

                skipButton(
                    seconds: 10,
                    symbol: "goforward.10",
                    identifier: "player.skipForward",
                    label: "10秒進む"
                )
                skipButton(
                    seconds: 30,
                    symbol: "goforward.30",
                    identifier: "player.skipForward30",
                    label: "30秒進む"
                )
            }
        }
    }

    private var seekRow: some View {
        HStack(spacing: 8) {
            Text(Self.timeLabel(scrubValue))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 52, alignment: .leading)
                .accessibilityHidden(true)

            Slider(
                value: Binding(
                    get: { scrubValue },
                    set: { value in
                        scrubPosition = value
                        // XCUITest's adjust(toNormalizedSliderPosition:) only
                        // sets the value, so seek here unless a drag is in
                        // progress (then onEditingChanged seeks at the end).
                        if !isScrubbing {
                            playback.seek(to: value)
                        }
                    }
                ),
                in: 0...max(playback.durationSeconds, 1),
                onEditingChanged: { editing in
                    if editing {
                        isScrubbing = true
                        scrubPosition = Double(playback.positionSeconds)
                    } else {
                        isScrubbing = false
                        playback.seek(to: scrubPosition)
                    }
                    onInteraction()
                }
            )
            .tint(.white)
            .accessibilityIdentifier("player.seekBar")
            .accessibilityLabel("再生位置")

            Text("-" + Self.timeLabel(remainingSeconds))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 56, alignment: .trailing)
                .accessibilityHidden(true)
        }
    }

    // MARK: - Buttons

    private var playPauseButton: some View {
        controlButton(
            symbol: playback.isPlaying ? "pause.fill" : "play.fill",
            identifier: "player.playPause",
            label: playback.isPlaying ? "一時停止" : "再生",
            size: 26
        ) {
            playback.togglePlayPause()
        }
    }

    private var muteButton: some View {
        controlButton(
            symbol: playback.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
            identifier: "player.mute",
            label: "ミュート"
        ) {
            playback.toggleMute()
        }
        .accessibilityValue(playback.isMuted ? "オン" : "オフ")
    }

    private var pictureInPictureButton: some View {
        controlButton(
            symbol: playback.isPictureInPictureActive ? "pip.exit" : "pip.enter",
            identifier: "player.pip",
            label: "ピクチャ・イン・ピクチャ"
        ) {
            playback.togglePictureInPicture()
        }
        .disabled(!playback.isPictureInPictureAvailable && !playback.isPictureInPictureActive)
    }

    private var fullscreenButton: some View {
        controlButton(
            symbol: playback.isFullscreen
                ? "arrow.down.right.and.arrow.up.left"
                : "arrow.up.left.and.arrow.down.right",
            identifier: "player.fullscreen",
            label: playback.isFullscreen ? "全画面表示を終了" : "全画面表示"
        ) {
            playback.toggleFullscreen()
        }
    }

    private var liveEdgeButton: some View {
        Button {
            onInteraction()
            playback.seekToLiveEdge()
        } label: {
            Text("ライブ")
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.white.opacity(0.18), in: Capsule())
                .foregroundStyle(.white)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("player.liveEdge")
        .accessibilityLabel("ライブ")
    }

    private var airPlayPicker: some View {
        AirPlayRoutePicker()
            .frame(width: 30, height: 30)
            .accessibilityIdentifier("player.airplay")
            .accessibilityLabel("AirPlay")
    }

    private func skipButton(
        seconds: Double,
        symbol: String,
        identifier: String,
        label: String
    ) -> some View {
        controlButton(symbol: symbol, identifier: identifier, label: label) {
            playback.seek(by: seconds)
        }
    }

    private func controlButton(
        symbol: String,
        identifier: String,
        label: String,
        size: CGFloat = 20,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            onInteraction()
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(label)
    }

    // MARK: - Values

    private var scrubValue: Double {
        isScrubbing ? scrubPosition : Double(playback.positionSeconds)
    }

    private var remainingSeconds: Double {
        max(playback.durationSeconds - scrubValue, 0)
    }

    /// `mm:ss`, with hours only when the media is longer than one.
    static func timeLabel(_ seconds: Double) -> String {
        let total = max(Int(seconds.rounded()), 0)
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

/// `AVRoutePickerView` is the only AirPlay button iOS offers; wrap it so the
/// SwiftUI player can show it next to the other controls.
private struct AirPlayRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .white
        view.activeTintColor = .white
        view.prioritizesVideoDevices = true
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        uiView.tintColor = .white
        uiView.activeTintColor = .white
    }
}
