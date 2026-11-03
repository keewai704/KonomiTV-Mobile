import SwiftUI
import AVKit
import AVFoundation
import Foundation
import Observation
import UIKit

/// Thin `UIViewControllerRepresentable` around `AVPlayerViewController` so the
/// app gets the standard playback controls, AirPlay and picture in picture.
struct PlayerRepresentable: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = true
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.entersFullScreenWhenPlaybackBegins = false
        controller.view.backgroundColor = .black
        controller.view.accessibilityIdentifier = "player.view"
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        if uiViewController.player !== player {
            uiViewController.player = player
        }
    }
}

/// Player plus an invisible status label that UI tests can read.
struct PlayerView: View {
    let player: AVPlayer

    @State private var observer = PlayerStateObserver()

    var body: some View {
        ZStack {
            PlayerRepresentable(player: player)
                .accessibilityIdentifier("player.view")

            Text(observer.state)
                .font(.system(size: 1))
                .opacity(0.01)
                .accessibilityLabel(observer.state)
                .accessibilityValue(observer.state)
                .accessibilityIdentifier("player.state")
                .allowsHitTesting(false)
        }
        .background(Color.black)
        .task {
            observer.attach(to: player)
        }
        .onDisappear {
            observer.stop()
        }
    }
}

/// Observes an `AVPlayer` and publishes a simple string state that the UI test
/// suite understands: `buffering`, `playing` or `error`.
///
/// `playing` requires both `timeControlStatus == .playing` and a playback
/// position greater than zero, so the test only passes once media is actually
/// being rendered.
@MainActor
@Observable
final class PlayerStateObserver {
    private(set) var state: String = "buffering"

    @ObservationIgnored private weak var player: AVPlayer?
    @ObservationIgnored private var timeControlObservation: NSKeyValueObservation?
    @ObservationIgnored private var itemStatusObservation: NSKeyValueObservation?
    @ObservationIgnored private var periodicTimeObserver: Any?

    /// Starts observing. Safe to call more than once with the same player.
    func attach(to player: AVPlayer) {
        if self.player === player, periodicTimeObserver != nil {
            refresh()
            return
        }
        stop()
        self.player = player

        timeControlObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor in
                self?.refresh()
            }
        }

        if let item = player.currentItem {
            itemStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor in
                    self?.refresh()
                }
            }
        }

        periodicTimeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }

        refresh()
    }

    /// Invalidates every observation. Must be called from the view lifecycle
    /// (`onDisappear`) because `deinit` cannot touch main-actor state.
    func stop() {
        timeControlObservation?.invalidate()
        timeControlObservation = nil
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil

        if let periodicTimeObserver, let player {
            player.removeTimeObserver(periodicTimeObserver)
        }
        periodicTimeObserver = nil
        player = nil
    }

    private func refresh() {
        guard let player else {
            state = "error"
            return
        }

        if let item = player.currentItem, item.status == .failed {
            state = "error"
            return
        }

        let seconds = player.currentTime().seconds
        let position = seconds.isFinite ? seconds : 0

        switch player.timeControlStatus {
        case .playing, .paused:
            state = position > 0.001 ? "playing" : "buffering"
        case .waitingToPlayAtSpecifiedRate:
            state = "buffering"
        @unknown default:
            state = "buffering"
        }
    }
}
