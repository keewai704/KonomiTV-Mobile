
import AVFoundation
import AVKit
import Foundation
import KonomiKit
import Observation
import UIKit

/// What the app wide player is currently playing.
///
/// Both models are Hashable, so a value identifies the screen that owns the
/// playback: returning to that screen can reuse the running player instead of
/// starting a new one.
enum PlaybackItem: Hashable {
    case video(RecordedProgram)
    case live(LiveChannel)

    /// Title shown in the Now Playing / lock screen info.
    var title: String {
        switch self {
        case .video(let video):
            return video.title
        case .live(let channel):
            return channel.programPresent?.title ?? channel.name
        }
    }

    /// Secondary line for the Now Playing info (channel name).
    var subtitle: String {
        switch self {
        case .video(let video):
            return video.channel?.name ?? "KonomiTV"
        case .live(let channel):
            return channel.name
        }
    }
}

/// App wide owner of the single AVPlayerViewController used by every player
/// screen.
///
/// Keeping playback here (instead of inside the detail views) is what makes
/// picture in picture and background playback work: leaving the screen while
/// PiP is active no longer tears the player down, the PiP "restore" button can
/// navigate back to the screen, and the Now Playing info has a title.
@MainActor
@Observable
final class PlaybackController {
    /// The item the player is preparing or playing. nil when idle.
    var item: PlaybackItem?

    /// Called when picture in picture asks to bring the user back to the app.
    /// AppModel uses it to select the section and push the matching screen.
    @ObservationIgnored var onRestore: (@MainActor (PlaybackItem) -> Void)?

    /// Shared player view controller. Created once and reused by every player
    /// screen so that PiP survives navigation inside the app.
    let playerViewController = AVPlayerViewController()

    /// "idle", "buffering", "playing" or "error".
    private(set) var state: String = "idle"
    /// Failure reason, surfaced to UI tests through the accessibility value.
    private(set) var errorDetail: String?
    /// Current playback position in whole seconds.
    private(set) var positionSeconds = 0
    private(set) var isPictureInPictureActive = false
    /// Number of PiP sessions started since launch (UI tests assert on it).
    private(set) var pictureInPictureStartCount = 0
    /// Whether an AVPlayer is attached to playerViewController.
    private(set) var isPlayerAttached = false
    /// Live pipeline failure message (nil while the stream is healthy).
    private(set) var liveErrorMessage: String?

    @ObservationIgnored private var delegateProxy = PlayerViewControllerDelegate()
    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var liveSession: LiveStreamSession?
    @ObservationIgnored private var keepAliveTask: Task<Void, Never>?
    @ObservationIgnored private var client: APIClient?
    @ObservationIgnored private var quality: StreamQuality = .p1080

    @ObservationIgnored private var timeControlObservation: NSKeyValueObservation?
    @ObservationIgnored private var itemStatusObservation: NSKeyValueObservation?
    @ObservationIgnored private var periodicTimeObserver: Any?
    @ObservationIgnored private var interruptionObserver: NSObjectProtocol?

    /// Item whose detail screen is currently on screen.
    @ObservationIgnored private var visibleItem: PlaybackItem?
    /// Set between a PiP restore request and the resulting PiP stop, so the
    /// stop does not tear down the playback that was just restored.
    @ObservationIgnored private var isRestoringFromPictureInPicture = false

    init(options: LaunchOptions = LaunchOptions()) {
        playerViewController.showsPlaybackControls = true
        playerViewController.allowsPictureInPicturePlayback = true
        playerViewController.canStartPictureInPictureAutomaticallyFromInline =
            !options.disablesAutomaticPictureInPicture
        playerViewController.updatesNowPlayingInfoCenter = true
        playerViewController.entersFullScreenWhenPlaybackBegins = false
        playerViewController.view.backgroundColor = .black
        playerViewController.view.accessibilityIdentifier = "player.view"

        delegateProxy.owner = self
        playerViewController.delegate = delegateProxy

        observeAudioSessionInterruptions()
    }

    // MARK: - Playback

    /// Prepares playback for the given item.
    ///
    /// Reuses the running player when the same item is requested again, which
    /// is what makes returning to the screen during PiP seamless.
    func play(_ playbackItem: PlaybackItem, client: APIClient, quality: StreamQuality) {
        if let current = item, current == playbackItem, player != nil || liveSession != nil {
            return
        }

        stop()

        item = playbackItem
        self.client = client
        self.quality = quality
        state = "buffering"
        errorDetail = nil
        positionSeconds = 0
        liveErrorMessage = nil

        activateAudioSession()

        switch playbackItem {
        case .video(let video):
            startVideo(video, client: client, quality: quality)
        case .live(let channel):
            startLive(channel, client: client, quality: quality)
        }
    }

    /// Restarts the live pipeline after a failure.
    func retry() {
        guard let current = item, case .live(let channel) = current else { return }
        guard let client else { return }

        liveSession?.onReady = nil
        liveSession?.onFailed = nil
        liveSession?.stop()
        liveSession = nil

        detachPlayerObservers()
        player?.pause()
        player = nil
        playerViewController.player = nil
        isPlayerAttached = false

        liveErrorMessage = nil
        errorDetail = nil
        state = "buffering"
        positionSeconds = 0

        activateAudioSession()
        startLive(channel, client: client, quality: quality)
    }

    /// Stops playback and releases every observer, task and session.
    func stop() {
        keepAliveTask?.cancel()
        keepAliveTask = nil

        detachPlayerObservers()
        player?.pause()
        player = nil
        playerViewController.player = nil
        isPlayerAttached = false

        liveSession?.onReady = nil
        liveSession?.onFailed = nil
        liveSession?.stop()
        liveSession = nil

        item = nil
        client = nil
        state = "idle"
        errorDetail = nil
        positionSeconds = 0
        liveErrorMessage = nil
        isPictureInPictureActive = false
        isRestoringFromPictureInPicture = false
    }

    // MARK: - Screen visibility

    func viewAppeared(for playbackItem: PlaybackItem) {
        visibleItem = playbackItem
    }

    /// Called when the detail screen goes away.
    ///
    /// Playback keeps running while PiP is active; otherwise it is stopped.
    /// The guard ignores the disappear of a screen that is no longer the
    /// current item (SwiftUI can deliver it after the next screen appeared).
    func viewDisappeared(for playbackItem: PlaybackItem) {
        guard let current = item, current == playbackItem else { return }
        if visibleItem == playbackItem {
            visibleItem = nil
        }
        guard !isPictureInPictureActive else { return }
        stop()
    }

    private var isPlayerScreenVisible: Bool {
        guard let current = item else { return false }
        return visibleItem == current
    }

    // MARK: - Picture in Picture

    /// Called by the delegate proxy when PiP starts.
    func pictureInPictureDidStart() {
        isPictureInPictureActive = true
        pictureInPictureStartCount += 1
    }

    /// Called by the delegate proxy when PiP stops.
    func pictureInPictureDidStop() {
        isPictureInPictureActive = false

        // Restoring brings the screen back; that must not stop playback.
        if isRestoringFromPictureInPicture {
            isRestoringFromPictureInPicture = false
            return
        }

        if !isPlayerScreenVisible {
            stop()
        }
    }

    /// Called by the delegate proxy when the user taps the PiP restore button.
    func restoreFromPictureInPicture() {
        guard let current = item else { return }
        isRestoringFromPictureInPicture = true
        onRestore?(current)
    }

    // MARK: - Video

    private func startVideo(_ video: RecordedProgram, client: APIClient, quality: StreamQuality) {
        let sessionID = String(UUID().uuidString.prefix(8)).lowercased()
        let url = client.videoPlaylistURL(
            videoID: video.id,
            quality: quality.videoSafe,
            sessionID: sessionID
        )

        let playerItem = AVPlayerItem(url: url)
        let newPlayer = AVPlayer(playerItem: playerItem)
        configure(newPlayer, item: .video(video))
        attach(newPlayer)
        newPlayer.play()

        startKeepAlive(client: client, videoID: video.id, quality: quality, sessionID: sessionID)
    }

    /// KonomiTV stops a recording session that stops sending keep-alives.
    private func startKeepAlive(
        client: APIClient,
        videoID: Int,
        quality: StreamQuality,
        sessionID: String
    ) {
        keepAliveTask?.cancel()
        keepAliveTask = Task {
            while !Task.isCancelled {
                try? await client.keepAlive(
                    videoID: videoID,
                    quality: quality,
                    sessionID: sessionID
                )
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    // MARK: - Live

    private func startLive(_ channel: LiveChannel, client: APIClient, quality: StreamQuality) {
        let session = LiveStreamSession(channel: channel, client: client, quality: quality)

        session.onReady = { [weak self, weak session] url in
            guard let self, let session, self.liveSession === session else { return }
            self.attachLivePlayer(url: url, channel: channel)
        }
        session.onFailed = { [weak self, weak session] message in
            guard let self, let session, self.liveSession === session else { return }
            self.liveErrorMessage = message
            self.state = "error"
            self.errorDetail = message
        }

        liveSession = session
        session.start()
    }

    private func attachLivePlayer(url: URL, channel: LiveChannel) {
        guard let current = item, current == .live(channel), player == nil else { return }

        activateAudioSession()

        let newPlayer = AVPlayer(url: url)
        configure(newPlayer, item: .live(channel))
        attach(newPlayer)
        newPlayer.play()
    }

    // MARK: - Player configuration

    private func configure(_ newPlayer: AVPlayer, item playbackItem: PlaybackItem) {
        // Background audio keeps playing when the app is not frontmost.
        newPlayer.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        newPlayer.allowsExternalPlayback = true
        newPlayer.automaticallyWaitsToMinimizeStalling = true

        let title = AVMutableMetadataItem()
        title.identifier = .commonIdentifierTitle
        title.value = playbackItem.title as NSString
        title.extendedLanguageTag = "und"

        let artist = AVMutableMetadataItem()
        artist.identifier = .commonIdentifierArtist
        artist.value = playbackItem.subtitle as NSString
        artist.extendedLanguageTag = "und"

        newPlayer.currentItem?.externalMetadata = [title, artist]
    }

    private func activateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    // MARK: - Player observation

    private func attach(_ newPlayer: AVPlayer) {
        detachPlayerObservers()

        player = newPlayer
        playerViewController.player = newPlayer
        isPlayerAttached = true

        timeControlObservation = newPlayer.observe(
            \.timeControlStatus,
            options: [.initial, .new]
        ) { [weak self] _, _ in
            Task { @MainActor in
                self?.refreshState()
            }
        }

        if let currentItem = newPlayer.currentItem {
            itemStatusObservation = currentItem.observe(
                \.status,
                options: [.initial, .new]
            ) { [weak self] _, _ in
                Task { @MainActor in
                    self?.refreshState()
                }
            }
        }

        periodicTimeObserver = newPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            let seconds = time.seconds
            Task { @MainActor in
                self?.applyPosition(seconds)
                // The position crossing zero is what turns "buffering" into
                // "playing", so refresh on every tick as well.
                self?.refreshState()
            }
        }

        refreshState()
    }

    /// Invalidates every observation. Called from the main actor because
    /// deinit cannot touch main-actor state.
    private func detachPlayerObservers() {
        timeControlObservation?.invalidate()
        timeControlObservation = nil
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil

        if let periodicTimeObserver, let player {
            player.removeTimeObserver(periodicTimeObserver)
        }
        periodicTimeObserver = nil
    }

    private func applyPosition(_ seconds: Double) {
        guard seconds.isFinite else { return }
        let position = Int(seconds)
        positionSeconds = position > 0 ? position : 0
    }

    private func refreshState() {
        // Late callbacks may arrive after stop(); keep the last state.
        guard let player else { return }

        if let currentItem = player.currentItem, currentItem.status == .failed {
            state = "error"
            errorDetail = currentItem.error.map { error in
                let nsError = error as NSError
                return "\(nsError.domain) \(nsError.code): \(nsError.localizedDescription)"
            } ?? "再生に失敗しました。"
            return
        }

        errorDetail = nil

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

    // MARK: - Audio interruptions

    private func observeAudioSessionInterruptions() {
        guard interruptionObserver == nil else { return }

        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // Only Sendable values cross into the main-actor hop.
            let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            Task { @MainActor in
                self?.handleInterruption(typeRawValue: rawType, optionsRawValue: rawOptions)
            }
        }
    }

    private func handleInterruption(typeRawValue: UInt?, optionsRawValue: UInt?) {
        guard let typeRawValue,
              let type = AVAudioSession.InterruptionType(rawValue: typeRawValue),
              type == .ended else {
            return
        }

        let options = AVAudioSession.InterruptionOptions(rawValue: optionsRawValue ?? 0)
        guard options.contains(.shouldResume) else { return }
        player?.play()
    }
}

/// Forwards AVPlayerViewController PiP callbacks to the controller.
///
/// AVKit calls these on the main thread. The `@preconcurrency` conformance
/// lets the main-actor isolated methods witness the protocol requirements
/// (with a runtime isolation check) without sending the non-Sendable
/// completion handler across isolation domains.
@MainActor
final class PlayerViewControllerDelegate: NSObject, @preconcurrency AVPlayerViewControllerDelegate {
    weak var owner: PlaybackController?

    func playerViewControllerDidStartPictureInPicture(
        _ playerViewController: AVPlayerViewController
    ) {
        owner?.pictureInPictureDidStart()
    }

    func playerViewControllerDidStopPictureInPicture(
        _ playerViewController: AVPlayerViewController
    ) {
        owner?.pictureInPictureDidStop()
    }

    func playerViewController(
        _ playerViewController: AVPlayerViewController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        owner?.restoreFromPictureInPicture()
        completionHandler(true)
    }
}
