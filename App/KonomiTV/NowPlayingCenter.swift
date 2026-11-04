import Foundation
import MediaPlayer
import UIKit

/// Lock screen / Control Center metadata and remote commands of the app-wide
/// player.
///
/// `AVPlayerViewController` used to fill `MPNowPlayingInfoCenter` itself
/// (`updatesNowPlayingInfoCenter`). With libVLC the app owns that: this class
/// keeps the title, the channel / program line, elapsed time, duration, rate
/// and the artwork from the channel logo (live) or the video thumbnail
/// (recorded), and routes the remote commands back into `PlaybackController`.
@MainActor
final class NowPlayingCenter {
    /// Commands the player screen also offers.
    var onPlay: (@MainActor () -> Void)?
    var onPause: (@MainActor () -> Void)?
    var onTogglePlayPause: (@MainActor () -> Void)?
    /// Skip by a number of seconds (positive = forward).
    var onSkip: (@MainActor (Double) -> Void)?
    /// Absolute position in seconds (seekable media only).
    var onChangePosition: (@MainActor (Double) -> Void)?

    private let infoCenter = MPNowPlayingInfoCenter.default()
    private let commandCenter = MPRemoteCommandCenter.shared()

    private var artwork: MPMediaItemArtwork?
    private var artworkURL: URL?
    private var artworkTask: Task<Void, Never>?
    private var lastRefreshAt = Date.distantPast
    private var isCleared = true

    /// Seconds between two Now Playing updates; libVLC reports the position
    /// four times a second, which is far more often than the lock screen needs.
    private static let refreshInterval: TimeInterval = 1

    init() {
        configureCommands()
    }

    // MARK: - Metadata

    /// Publishes the playback state. Cheap to call on every VLC callback: the
    /// info center is refreshed at most once per second unless `force` is set
    /// (a new item, a play / pause, a seek).
    func update(
        title: String,
        subtitle: String,
        position: Double,
        length: Double,
        isPlaying: Bool,
        isLive: Bool,
        canSeek: Bool,
        artworkURL: URL?,
        force: Bool = false
    ) {
        loadArtworkIfNeeded(url: artworkURL)

        commandCenter.changePlaybackPositionCommand.isEnabled = canSeek
        commandCenter.skipBackwardCommand.isEnabled = true
        commandCenter.skipForwardCommand.isEnabled = true

        let now = Date()
        guard force || now.timeIntervalSince(lastRefreshAt) >= Self.refreshInterval else {
            return
        }
        lastRefreshAt = now
        isCleared = false

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: subtitle,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: max(position, 0),
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
        ]
        if isLive {
            info[MPNowPlayingInfoPropertyIsLiveStream] = true
        } else if length > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = length
        }
        if let artwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }

        infoCenter.nowPlayingInfo = info
        infoCenter.playbackState = isPlaying ? .playing : .paused
    }

    /// Drops the lock screen entry when playback stops.
    func clear() {
        guard !isCleared else { return }
        isCleared = true
        lastRefreshAt = .distantPast
        infoCenter.nowPlayingInfo = nil
        infoCenter.playbackState = .stopped
        artworkTask?.cancel()
        artworkTask = nil
        artwork = nil
        artworkURL = nil
    }

    // MARK: - Artwork

    /// Loads the channel logo / video thumbnail once per item.
    private func loadArtworkIfNeeded(url: URL?) {
        guard let url else {
            if artwork != nil {
                artwork = nil
                artworkURL = nil
            }
            return
        }
        guard url != artworkURL else { return }
        artworkURL = url
        artwork = nil
        artworkTask?.cancel()
        artworkTask = Task { [weak self] in
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
                  let image = UIImage(data: data),
                  !Task.isCancelled
            else {
                return
            }
            guard let self, self.artworkURL == url else { return }
            self.artwork = Self.makeArtwork(image)
        }
    }

    /// MediaPlayer calls the artwork's request handler on its own queue. A
    /// closure written in this main-actor class would be main-actor isolated
    /// and trap there, so it is made in a nonisolated context.
    private nonisolated static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in image }
    }

    // MARK: - Remote commands

    private func configureCommands() {
        let center = commandCenter

        // Only the commands this player implements are enabled; AVKit used to
        // register its own set.
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.skipBackwardCommand.isEnabled = true
        center.skipBackwardCommand.preferredIntervals = [10]
        center.skipForwardCommand.isEnabled = true
        center.skipForwardCommand.preferredIntervals = [10]
        center.changePlaybackPositionCommand.isEnabled = false
        center.nextTrackCommand.isEnabled = false
        center.previousTrackCommand.isEnabled = false

        // @Sendable keeps the handlers nonisolated: MediaPlayer may call them
        // off the main thread, where a main-actor closure would trap.
        center.playCommand.addTarget { @Sendable [weak self] _ in
            self?.hop { $0.onPlay?() }
            return .success
        }
        center.pauseCommand.addTarget { @Sendable [weak self] _ in
            self?.hop { $0.onPause?() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { @Sendable [weak self] _ in
            self?.hop { $0.onTogglePlayPause?() }
            return .success
        }
        center.skipBackwardCommand.addTarget { @Sendable [weak self] event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 10
            self?.hop { $0.onSkip?(-abs(interval)) }
            return .success
        }
        center.skipForwardCommand.addTarget { @Sendable [weak self] event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 10
            self?.hop { $0.onSkip?(abs(interval)) }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { @Sendable [weak self] event in
            guard let position = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime else {
                return .commandFailed
            }
            self?.hop { $0.onChangePosition?(position) }
            return .success
        }
    }

    /// Remote command handlers are not guaranteed to run on the main actor.
    private nonisolated func hop(_ action: @escaping @MainActor (NowPlayingCenter) -> Void) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                action(self)
            }
        }
    }
}
