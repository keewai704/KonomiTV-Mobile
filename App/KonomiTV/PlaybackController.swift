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
    /// A saved video played from local storage (no server involved).
    case offline(RecordedProgram)

    /// Title shown in the Now Playing / lock screen info.
    var title: String {
        switch self {
        case .video(let video), .offline(let video):
            return video.title
        case .live(let channel):
            return channel.programPresent?.title ?? channel.name
        }
    }

    /// Secondary line for the Now Playing info (channel name).
    var subtitle: String {
        switch self {
        case .video(let video), .offline(let video):
            return video.channel?.name ?? "KonomiTV"
        case .live(let channel):
            return channel.name
        }
    }

    var isVideo: Bool {
        switch self {
        case .video, .offline: return true
        case .live: return false
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

    /// Called for every position tick of a recorded program, so AppModel can
    /// keep the watch history up to date.
    @ObservationIgnored var onVideoProgress: (@MainActor (RecordedProgram, Double) -> Void)?

    /// Called when playback stops, with the position it stopped at.
    @ObservationIgnored var onVideoPlaybackStopped: (@MainActor (RecordedProgram, Double) -> Void)?

    /// Position to seek to once the recorded program's item is ready.
    @ObservationIgnored private var pendingStartPosition: Double = 0

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
    /// False on iPhone simulators, which do not implement PiP.
    let isPictureInPictureSupported = AVPictureInPictureController.isPictureInPictureSupported()
    /// Number of PiP sessions started since launch (UI tests assert on it).
    private(set) var pictureInPictureStartCount = 0
    /// Whether an AVPlayer is attached to playerViewController.
    private(set) var isPlayerAttached = false
    /// Live pipeline failure message (nil while the stream is healthy).
    private(set) var liveErrorMessage: String?

    /// Live stream status reported by the SSE event API ("ONAir", "Standby",
    /// ...). Empty before the first event or outside live playback.
    private(set) var liveStatus = ""
    /// Detail text shown over the player while the status is not ONAir.
    private(set) var liveDetail = ""
    /// Viewers of this live channel across all qualities.
    private(set) var liveViewerCount = 0
    /// True when the live stream offers 主音声 / 副音声.
    private(set) var hasSecondaryAudio = false
    /// Selected live audio track.
    private(set) var liveAudioSelection: AudioSelection = .primary

    /// Profile (quality, data saver, 24fps, low latency) of the current
    /// playback. Changing it through `switchQuality` restarts the stream.
    private(set) var profile = StreamingProfile.default
    private(set) var isMuted = false
    /// True while the player is actually advancing. The comment overlay freezes
    /// its animations when playback pauses.
    private(set) var isPlaying = false

    /// Danmaku overlay state, shared with the live / recorded comment sessions.
    /// Created once so a channel switch keeps using the same renderer.
    let comments = CommentOverlayModel()

    /// ARIB caption (字幕・文字スーパー) pipeline and overlay state.
    let captions = CaptionController()

    /// Capture (キャプチャ) pipeline: frame grab, caption / comment compositing
    /// and saving. Reads the frame from the shared player.
    let capture = CaptureController()

    @ObservationIgnored private var delegateProxy = PlayerViewControllerDelegate()
    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var liveSession: LiveStreamSession?
    @ObservationIgnored private let liveEvents = LiveEventsMonitor()
    @ObservationIgnored private var keepAliveTask: Task<Void, Never>?
    @ObservationIgnored private var client: APIClient?

    @ObservationIgnored private weak var commentOverlayView: CommentOverlayUIView?
    @ObservationIgnored private weak var captionOverlayView: CaptionOverlayUIView?
    /// Recorded-video HLS proxy (the video stream plus its caption extraction).
    @ObservationIgnored private var videoProxy: VideoHLSProxy?

    /// Loopback server of a saved (offline) video.
    @ObservationIgnored private var offlineServer: LocalHLSServer?
    /// Saved video and its directory, kept so a restart can rebuild the server.
    @ObservationIgnored private var offlineContent: (video: OfflineVideo, directory: URL)?

    @ObservationIgnored private var timeControlObservation: NSKeyValueObservation?
    @ObservationIgnored private var itemStatusObservation: NSKeyValueObservation?
    @ObservationIgnored private var periodicTimeObserver: Any?
    @ObservationIgnored private var interruptionObserver: NSObjectProtocol?

    /// Extra player layer used to start picture in picture from the E shortcut.

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

        capture.playback = self

        attachOverlays()
        observeAudioSessionInterruptions()
    }

    // MARK: - Playback

    /// Prepares playback for the given item.
    ///
    /// Reuses the running player when the same item is requested again, which
    /// is what makes returning to the screen during PiP seamless.
    /// - Parameter startAt: position (seconds) playback should start at, used
    ///   to resume a recorded program from the watch history.
    func play(
        _ playbackItem: PlaybackItem,
        client: APIClient,
        profile: StreamingProfile,
        startAt: Double = 0
    ) {
        if let current = item, current == playbackItem, player != nil || liveSession != nil {
            return
        }

        stop()

        item = playbackItem
        self.client = client
        self.profile = profile
        state = "buffering"
        errorDetail = nil
        positionSeconds = 0
        liveErrorMessage = nil
        isMuted = false

        activateAudioSession()
        startCurrentItem(startAt: startAt)
    }

    /// Plays a saved video entirely from local storage.
    ///
    /// No server session is created: the stored playlist and segments are
    /// served by a loopback `LocalHLSServer`, so picture in picture, background
    /// playback and the ARIB caption overlay work the same way as online
    /// playback, without a network.
    func playOffline(_ video: OfflineVideo, directory: URL, startAt: Double = 0) {
        let playbackItem = PlaybackItem.offline(video.program)
        if let current = item, current == playbackItem, player != nil, offlineServer != nil {
            return
        }

        stop()

        item = playbackItem
        offlineContent = (video, directory)
        client = nil
        state = "buffering"
        errorDetail = nil
        positionSeconds = 0
        liveErrorMessage = nil
        isMuted = false

        activateAudioSession()
        startOffline(video, directory: directory, startAt: startAt)
    }

    /// Restarts the live pipeline after a failure.
    func retry() {
        guard let current = item else { return }
        switch current {
        case .live:
            guard client != nil else { return }
            reload(startAt: 0)
        case .video, .offline:
            reload(startAt: Double(positionSeconds))
        }
    }

    /// Stops playback and releases every observer, task and session.
    func stop() {
        // Store the final position of the recorded program that is stopping.
        switch item {
        case .video(let video)?, .offline(let video)?:
            onVideoPlaybackStopped?(video, Double(positionSeconds))
        default:
            break
        }

        pendingStartPosition = 0
        keepAliveTask?.cancel()
        keepAliveTask = nil

        detachPlayerObservers()
        capture.detach()
        player?.pause()
        player = nil
        playerViewController.player = nil
        isPlayerAttached = false

        liveSession?.onReady = nil
        liveSession?.onFailed = nil
        liveSession?.onAudioTrackChange = nil
        liveSession?.onCaption = nil
        liveSession?.stop()
        liveSession = nil

        videoProxy?.stop()
        videoProxy = nil

        offlineServer?.stop()
        offlineServer = nil
        offlineContent = nil

        liveEvents.onUpdate = nil
        liveEvents.stop()

        item = nil
        client = nil
        state = "idle"
        errorDetail = nil
        positionSeconds = 0
        liveErrorMessage = nil
        liveStatus = ""
        liveDetail = ""
        liveViewerCount = 0
        hasSecondaryAudio = false
        liveAudioSelection = .primary
        isMuted = false
        isPlaying = false
        isPictureInPictureActive = false
        isRestoringFromPictureInPicture = false
        comments.isPlaying = false
        comments.isPictureInPictureActive = false
        comments.reset()

        captions.isPictureInPictureActive = false
        captions.end()
    }

    // MARK: - Overlays

    /// Adds the caption and danmaku renderers to the player's content overlay
    /// view, which is drawn above the video inline and in the fullscreen
    /// presentation alike. Captions go first so comments stay on top.
    private func attachOverlays() {
        playerViewController.loadViewIfNeeded()
        guard let contentOverlay = playerViewController.contentOverlayView else { return }

        if captionOverlayView == nil {
            let overlay = CaptionOverlayUIView(
                controller: captions,
                playerViewController: playerViewController
            )
            overlay.frame = contentOverlay.bounds
            overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            contentOverlay.insertSubview(overlay, at: 0)
            captionOverlayView = overlay
        }

        if commentOverlayView == nil {
            let overlay = CommentOverlayUIView(model: comments)
            overlay.frame = contentOverlay.bounds
            overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            contentOverlay.addSubview(overlay)
            commentOverlayView = overlay
        }
    }

    private func updatePlaying(_ playing: Bool) {
        if isPlaying != playing {
            isPlaying = playing
        }
        if comments.isPlaying != playing {
            comments.isPlaying = playing
        }
    }

    // MARK: - Player controls

    /// Toggles play / pause (Space shortcut).
    func togglePlayPause() {
        guard let player else { return }
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            player.play()
        }
    }

    /// Toggles mute (Q shortcut). iOS has no per-app volume control, but
    /// muting the AVPlayer is the equivalent of the web client's Q shortcut.
    func toggleMute() {
        isMuted.toggle()
        player?.isMuted = isMuted
    }

    /// Seeks to an absolute position in seconds.
    func seek(to seconds: Double) {
        guard let player else { return }
        let target = max(seconds, 0)
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: CMTime(seconds: 0.5, preferredTimescale: 600),
            toleranceAfter: CMTime(seconds: 0.5, preferredTimescale: 600)
        )
        captions.seek(to: target)
    }

    /// Seeks relative to the current position.
    func seek(by seconds: Double) {
        seek(to: currentPosition + seconds)
    }

    /// Jumps to the live edge (W shortcut).
    func seekToLiveEdge() {
        guard case .live? = item, let player, let currentItem = player.currentItem else { return }
        guard let range = currentItem.seekableTimeRanges.last?.timeRangeValue else { return }
        let end = range.start.seconds + range.duration.seconds
        guard end.isFinite else { return }
        let target = max(end - 1, 0)
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .positiveInfinity,
            toleranceAfter: .zero
        )
        captions.seek(to: target)
    }

    /// Restarts the current item (R shortcut).
    func restart() {
        guard let current = item else { return }
        switch current {
        case .video, .offline:
            reload(startAt: currentPosition)
        case .live:
            reload(startAt: 0)
        }
    }

    /// Switches the base quality and restarts the stream with the new profile.
    /// Recorded video resumes at the current position with a new session id.
    func switchQuality(_ quality: StreamQuality) {
        guard item != nil else { return }
        // A saved video holds exactly one quality; switching needs the server.
        if case .offline = item { return }
        var updated = profile
        updated.quality = quality
        profile = updated
        reload(startAt: currentPosition)
    }

    /// Switches 主音声 / 副音声 of the live stream without restarting it.
    func selectLiveAudio(_ selection: AudioSelection) {
        liveAudioSelection = selection
        liveSession?.selectAudio(selection)
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

    // MARK: - Capture inputs

    /// The AVPlayer the capture pipeline reads frames from (nil when idle).
    var capturePlayer: AVPlayer? { player }

    /// The client captures are uploaded with.
    var captureClient: APIClient? { client }

    /// The danmaku overlay view, whose layer tree is rendered into a comment
    /// capture.
    var commentOverlay: CommentOverlayUIView? { commentOverlayView }

    /// Playback position in seconds, with sub-second precision for the EXIF
    /// metadata.
    var capturePosition: Double { currentPosition }

    private var isPlayerScreenVisible: Bool {
        guard let current = item else { return false }
        return visibleItem == current
    }

    private var currentPosition: Double {
        guard let player else { return Double(positionSeconds) }
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? max(seconds, 0) : Double(positionSeconds)
    }

    // MARK: - Picture in Picture

    /// Called by the delegate proxy when PiP starts.
    func pictureInPictureDidStart() {
        isPictureInPictureActive = true
        comments.isPictureInPictureActive = true
        captions.isPictureInPictureActive = true
        pictureInPictureStartCount += 1
    }

    /// Called by the delegate proxy when PiP stops.
    func pictureInPictureDidStop() {
        isPictureInPictureActive = false
        comments.isPictureInPictureActive = false
        captions.isPictureInPictureActive = false

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

    // MARK: - Item lifecycle

    private func startCurrentItem(startAt: Double) {
        // AVPlayerViewController creates its content overlay view lazily; by
        // the first play it exists, so this is a second chance to attach.
        attachOverlays()
        guard let item else { return }
        switch item {
        case .video(let video):
            guard let client else { return }
            startVideo(video, client: client, profile: profile, startAt: startAt)
        case .live(let channel):
            guard let client else { return }
            startLive(channel, client: client, profile: profile)
        case .offline:
            guard let content = offlineContent else { return }
            startOffline(content.video, directory: content.directory, startAt: startAt)
        }
    }

    /// Tears down the player and the live pipeline, then starts the current
    /// item again with the current profile.
    private func reload(startAt: Double) {
        guard let item else { return }
        // Offline items are served locally and need no API client.
        if case .offline = item {
            // Nothing to check.
        } else if client == nil {
            return
        }

        keepAliveTask?.cancel()
        keepAliveTask = nil

        detachPlayerObservers()
        capture.detach()
        player?.pause()
        player = nil
        playerViewController.player = nil
        isPlayerAttached = false

        liveSession?.onReady = nil
        liveSession?.onFailed = nil
        liveSession?.onAudioTrackChange = nil
        liveSession?.onCaption = nil
        liveSession?.stop()
        liveSession = nil

        videoProxy?.stop()
        videoProxy = nil

        offlineServer?.stop()
        offlineServer = nil

        liveEvents.onUpdate = nil
        liveEvents.stop()

        captions.end()

        errorDetail = nil
        liveErrorMessage = nil
        liveStatus = ""
        liveDetail = ""
        hasSecondaryAudio = false
        state = "buffering"
        positionSeconds = Int(startAt)
        isPlaying = false
        comments.isPlaying = false
        comments.reset()

        activateAudioSession()

        switch item {
        case .video(let video):
            guard let client else { return }
            startVideo(video, client: client, profile: profile, startAt: startAt)
        case .live(let channel):
            guard let client else { return }
            startLive(channel, client: client, profile: profile)
        case .offline:
            guard let content = offlineContent else { return }
            startOffline(content.video, directory: content.directory, startAt: startAt)
        }
    }

    // MARK: - Video

    private func startVideo(
        _ video: RecordedProgram,
        client: APIClient,
        profile: StreamingProfile,
        startAt: Double
    ) {
        let sessionID = String(UUID().uuidString.prefix(8)).lowercased()
        // AVPlayer never talks to the server directly: the loopback proxy
        // forwards the playlists and segments (and extracts their captions).
        let masterURL = client.videoPlaylistURL(
            videoID: video.id,
            profile: profile,
            sessionID: sessionID,
            playlistType: .master
        )

        let proxy = VideoHLSProxy(
            masterURL: masterURL,
            token: client.token
        ) { [weak self] pes, playbackTime in
            Task { @MainActor in
                self?.captions.feed(pes, at: playbackTime)
            }
        }
        videoProxy?.stop()
        videoProxy = proxy

        startKeepAlive(client: client, videoID: video.id, profile: profile, sessionID: sessionID)

        Task { [weak self, weak proxy] in
            guard let self, let proxy else { return }
            do {
                let url = try await proxy.start()
                guard !Task.isCancelled, self.videoProxy === proxy else {
                    proxy.stop()
                    return
                }
                self.attachVideoPlayer(
                    url: url,
                    item: .video(video),
                    startAt: startAt
                )
            } catch {
                guard !Task.isCancelled, self.videoProxy === proxy else { return }
                self.errorDetail = ErrorText.message(for: error)
                self.state = "error"
            }
        }
    }

    private func attachVideoPlayer(
        url: URL,
        item expected: PlaybackItem,
        startAt: Double
    ) {
        guard let current = item, current == expected, player == nil else { return }

        activateAudioSession()

        let playerItem = AVPlayerItem(url: url)
        capture.attach(to: playerItem)
        let newPlayer = AVPlayer(playerItem: playerItem)
        configure(newPlayer, item: expected)
        attach(newPlayer)
        // Resuming from the watch history: seeking before the item is ready
        // can be ignored, so refreshState() seeks once it is.
        pendingStartPosition = startAt
        newPlayer.play()

        captions.beginVideo { [weak newPlayer] in
            guard let seconds = newPlayer?.currentTime().seconds, seconds.isFinite else {
                return nil
            }
            return max(seconds, 0)
        }
    }

    // MARK: - Offline video

    /// Serves a saved video from a loopback server and attaches the player.
    private func startOffline(_ video: OfflineVideo, directory: URL, startAt: Double) {
        let source = OfflinePlaybackSource(
            playlist: OfflineHLSPlaylist.mediaPlaylist(for: video),
            directory: directory,
            segmentDirectoryName: OfflineHLSPlaylist.segmentDirectoryName,
            segmentFileExtension: video.container.fileExtension,
            segmentContentType: video.container.contentType,
            initSegmentFile: video.initSegmentFile
        ) { [weak self] pes, playbackTime in
            Task { @MainActor in
                self?.captions.feed(pes, at: playbackTime)
            }
        }

        let server = LocalHLSServer(offline: source)
        offlineServer?.stop()
        offlineServer = server

        Task { [weak self, weak server] in
            guard let self, let server else { return }
            do {
                let url = try await server.startURL(path: "/offline/playlist.m3u8")
                guard !Task.isCancelled, self.offlineServer === server else {
                    server.stop()
                    return
                }
                self.attachVideoPlayer(
                    url: url,
                    item: .offline(video.program),
                    startAt: startAt
                )
            } catch {
                guard !Task.isCancelled, self.offlineServer === server else { return }
                self.errorDetail = ErrorText.message(for: error)
                self.state = "error"
            }
        }
    }

    /// KonomiTV stops a recording session that stops sending keep-alives.
    private func startKeepAlive(
        client: APIClient,
        videoID: Int,
        profile: StreamingProfile,
        sessionID: String
    ) {
        keepAliveTask?.cancel()
        keepAliveTask = Task {
            while !Task.isCancelled {
                try? await client.keepAlive(
                    videoID: videoID,
                    profile: profile,
                    sessionID: sessionID
                )
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    // MARK: - Live

    private func startLive(_ channel: LiveChannel, client: APIClient, profile: StreamingProfile) {
        let session = LiveStreamSession(channel: channel, client: client, profile: profile)

        session.onReady = { [weak self, weak session] url in
            guard let self, let session, self.liveSession === session else { return }
            self.hasSecondaryAudio = session.hasSecondaryAudio
            self.attachLivePlayer(url: url, channel: channel)
        }
        session.onFailed = { [weak self, weak session] message in
            guard let self, let session, self.liveSession === session else { return }
            self.liveErrorMessage = message
            self.state = "error"
            self.errorDetail = message
        }
        session.onAudioTrackChange = { [weak self, weak session] hasSecondary in
            guard let self, let session, self.liveSession === session else { return }
            self.hasSecondaryAudio = hasSecondary
        }
        session.onCaption = { [weak self, weak session] pes in
            guard let self, let session, self.liveSession === session else { return }
            guard let anchor = session.dateTimeAnchor else { return }
            let playbackTime: Double
            if let pts = pes.pts {
                playbackTime = anchor.seconds(forPTS: pts)
            } else if let now = self.captions.currentPlaybackTime() {
                playbackTime = now
            } else {
                return
            }
            self.captions.feed(pes, at: playbackTime)
        }

        liveSession = session
        hasSecondaryAudio = session.hasSecondaryAudio
        liveAudioSelection = .primary
        session.start()

        let eventsURL = client.liveEventsURL(
            displayChannelID: channel.displayChannelID,
            profile: profile,
            isRadioChannel: channel.isRadioChannel
        )
        liveEvents.onUpdate = { [weak self, weak session] status in
            guard let self, let session, self.liveSession === session else { return }
            self.applyLiveStatus(status)
        }
        liveEvents.start(url: eventsURL)
    }

    private func applyLiveStatus(_ status: LiveStreamStatus) {
        liveStatus = status.status.rawValue
        liveDetail = status.detail
        liveViewerCount = status.clientCount

        switch status.status {
        case .offline:
            // Offline with a detail means the stream will not come back on its
            // own; surface it as a playback error with the server's message.
            if !status.detail.isEmpty {
                liveErrorMessage = status.detail
                state = "error"
                errorDetail = status.detail
            }
        case .onAir:
            liveErrorMessage = nil
            if state == "error" {
                state = "buffering"
            }
        case .standby, .idling, .restart:
            break
        }
    }

    private func attachLivePlayer(url: URL, channel: LiveChannel) {
        guard let current = item, current == .live(channel), player == nil else { return }

        activateAudioSession()

        let item = AVPlayerItem(url: url)
        capture.attach(to: item)
        if profile.lowLatency {
            // Keep playback close to the live edge and let AVPlayer speed up
            // slightly when it falls behind.
            item.configuredTimeOffsetFromLive = CMTime(seconds: 3, preferredTimescale: 600)
            item.automaticallyPreservesTimeOffsetFromLive = true
        }

        let newPlayer = AVPlayer(playerItem: item)
        configure(newPlayer, item: .live(channel))
        attach(newPlayer)
        newPlayer.play()

        // PROGRAM-DATE-TIME makes `currentDate()` the live wall clock; the
        // anchor turns it back into seconds on the caption timeline.
        captions.beginLive { [weak self, weak newPlayer] in
            guard let self,
                  let anchor = self.liveSession?.dateTimeAnchor else {
                return nil
            }
            if let date = newPlayer?.currentItem?.currentDate() {
                return date.timeIntervalSince(anchor.anchorDate)
            }
            // Before AVPlayer has mapped the playlist's PROGRAM-DATE-TIME (or
            // on a server that omits it) the wall clock is the same broadcast
            // clock the captions were stamped with.
            return Date().timeIntervalSince(anchor.anchorDate)
        }
    }

    // MARK: - Player configuration

    private func configure(_ newPlayer: AVPlayer, item playbackItem: PlaybackItem) {
        // Background audio keeps playing when the app is not frontmost.
        newPlayer.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        newPlayer.allowsExternalPlayback = true
        newPlayer.automaticallyWaitsToMinimizeStalling = true
        newPlayer.isMuted = isMuted

        // Speeds for recorded programs; an empty list hides the menu for live.
        playerViewController.speeds = playbackItem.isVideo
            ? [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0].map { rate in
                AVPlaybackSpeed(rate: Float(rate), localizedName: "\(rate.formatted())x")
            }
            : []

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
        newPlayer.isMuted = isMuted

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

        switch item {
        case .video(let video)?, .offline(let video)?:
            onVideoProgress?(video, seconds > 0 ? seconds : 0)
        default:
            break
        }
    }

    private func refreshState() {
        if pendingStartPosition > 0, let player, player.currentItem?.status == .readyToPlay {
            let position = pendingStartPosition
            pendingStartPosition = 0
            player.seek(
                to: CMTime(seconds: position, preferredTimescale: 600),
                toleranceBefore: CMTime(seconds: 1, preferredTimescale: 600),
                toleranceAfter: CMTime(seconds: 1, preferredTimescale: 600)
            )
        }

        // Late callbacks may arrive after stop(); keep the last state.
        guard let player else {
            updatePlaying(false)
            return
        }

        if let currentItem = player.currentItem, currentItem.status == .failed {
            updatePlaying(false)
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

        updatePlaying(player.timeControlStatus == .playing)

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
