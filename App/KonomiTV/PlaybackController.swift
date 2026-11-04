import AVFoundation
import AVKit
import Foundation
import KonomiKit
import KonomiStreaming
import Observation
import UIKit
import VLCKit

/// What the app wide player is currently playing.
///
/// Both models are Hashable, so a value identifies the screen that owns the
/// playback: returning to that screen can reuse the running player instead of
/// starting a new one.
enum PlaybackItem: Hashable, Sendable {
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

/// App wide owner of the single libVLC player used by every player screen.
///
/// Keeping playback here (instead of inside the detail views) is what makes
/// picture in picture and background playback work: leaving the screen while
/// PiP is active no longer tears the player down, the PiP restore button can
/// navigate back to the screen, and the Now Playing info has a title.
///
/// One VLCLibrary and one VLCMediaPlayer live as long as the app does; every
/// load replaces only the media. libVLC reports state, time, length and
/// snapshots from its own threads (PlayerDelegateProxy), so all of that is
/// funnelled through nonisolated methods that hop to the main actor.
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

    /// The long-lived player host: the drawable libVLC renders into plus the
    /// caption and danmaku overlays. Every player screen shows this exact view
    /// controller, so the video output is never recreated while the app moves
    /// between screens.
    let hostViewController: PlayerHostViewController

    /// "idle", "buffering", "playing", "paused" or "error".
    private(set) var state: String = "idle"
    /// Failure reason, surfaced to UI tests through the accessibility value.
    private(set) var errorDetail: String?
    /// Current playback position in whole seconds.
    private(set) var positionSeconds = 0
    /// Length of the current media in seconds (0 for live and while unknown).
    private(set) var durationSeconds: Double = 0
    private(set) var isPictureInPictureActive = false
    /// False on iPhone simulators, which do not implement PiP.
    let isPictureInPictureSupported = AVPictureInPictureController.isPictureInPictureSupported()
    /// Number of PiP sessions started since launch (UI tests assert on it).
    private(set) var pictureInPictureStartCount = 0
    /// Whether libVLC has a media attached to the player.
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
    /// playback. Changing it through switchQuality restarts the stream.
    private(set) var profile = StreamingProfile.default
    private(set) var isMuted = false
    /// True while the player is actually advancing. The comment overlay freezes
    /// its animations when playback pauses.
    private(set) var isPlaying = false

    /// Data broadcasting (BML) of the live player: the WKWebView page plus the
    /// native state around it (remote keys, video plane).
    let dataBroadcasting = DataBroadcastingController()

    /// Current / next program reported by the live stream's EIT[p/f]. They
    /// replace the values `GET /api/channels` returned while the stream runs
    /// (the web client does the same through its ChannelsStore).
    private(set) var liveProgramPresent: Program?
    private(set) var liveProgramFollowing: Program?

    /// Danmaku overlay state, shared with the live / recorded comment sessions.
    /// Created once so a channel switch keeps using the same renderer.
    let comments = CommentOverlayModel()

    /// ARIB caption (字幕・文字スーパー) pipeline and overlay state.
    let captions = CaptionController()

    /// Capture (キャプチャ) pipeline: frame grab, caption / comment compositing
    /// and saving. Reads the frame from the shared player.
    let capture = CaptureController()

    /// Whether the current item offers seeking (recorded and saved video).
    var canSeek: Bool { item?.isVideo == true }

    /// True while playing a live channel.
    var isLivePlayback: Bool {
        if case .live? = item { return true }
        return false
    }

    /// libVLC has handed its picture-in-picture window controller to the
    /// drawable, so the PiP button can start it.
    var isPictureInPictureAvailable: Bool {
        hostViewController.isPictureInPictureWindowAvailable
    }

    // MARK: - Private state

    /// Live network cache in milliseconds. The live playlist window is six
    /// one-second segments and libVLC's hls-live-start default is three
    /// segments, so the player sits about three seconds behind the encoder;
    /// a one second cache keeps that latency without stalling on jitter.
    private static let liveNetworkCaching = 1000
    /// Recorded video goes through the loopback proxy; a deeper buffer makes
    /// seeking smoother and costs nothing but memory.
    private static let videoNetworkCaching = 3000
    /// Saved videos come from disk through the loopback server.
    private static let offlineNetworkCaching = 300

    /// One libVLC instance for the whole app: an instance owns a full engine,
    /// so creating one per player would leak it on every re-play.
    private static let library: VLCLibrary = {
        let library = VLCLibrary(options: [
            "--no-video-title-show",
            "--no-snapshot-preview",
        ])
        library.setHumanReadableName("KonomiTV", withHTTPUserAgent: "KonomiTV")
        return library
    }()

    @ObservationIgnored private let player: VLCMediaPlayer
    @ObservationIgnored private let delegateProxy = PlayerDelegateProxy()
    @ObservationIgnored private let clock = PlaybackClock()
    @ObservationIgnored private let nowPlaying = NowPlayingCenter()

    @ObservationIgnored private var liveSession: LiveStreamSession?
    @ObservationIgnored private let liveEvents = LiveEventsMonitor()
    @ObservationIgnored private var keepAliveTask: Task<Void, Never>?
    @ObservationIgnored private var client: APIClient?

    /// Recorded-video HLS proxy (the video stream plus its caption extraction).
    @ObservationIgnored private var videoProxy: VideoHLSProxy?

    /// Loopback server of a saved (offline) video.
    @ObservationIgnored private var offlineServer: LocalHLSServer?
    /// Saved video and its directory, kept so a restart can rebuild the server.
    @ObservationIgnored private var offlineContent: (video: OfflineVideo, directory: URL)?

    /// Position to seek to once the recorded program's media is open.
    @ObservationIgnored private var pendingStartPosition: Double = 0
    /// A snapshot request waiting for libVLC's snapshot-taken callback.
    @ObservationIgnored private var snapshotWaiter: SnapshotWaiter?
    /// True once the live clock asked for the anchor of a served segment.
    @ObservationIgnored private var liveAnchorRequested = false
    /// Playback position the next served segment belongs to. 0 after a load
    /// (libVLC starts its timeline at the first segment it fetches); the
    /// current position after a live-edge seek.
    @ObservationIgnored private var liveAnchorPlaybackTime: Double = 0

    @ObservationIgnored private var interruptionObserver: NSObjectProtocol?
    @ObservationIgnored private var dataBroadcastingSettingsObserver: NSObjectProtocol?
    @ObservationIgnored private var backgroundObserver: NSObjectProtocol?
    @ObservationIgnored private var foregroundObserver: NSObjectProtocol?
    /// Delayed "no PiP is coming, stop decoding video" check.
    @ObservationIgnored private var backgroundTask: Task<Void, Never>?
    @ObservationIgnored private var didDisableVideoTracks = false

    /// Item whose detail screen is currently on screen.
    @ObservationIgnored private var visibleItem: PlaybackItem?
    /// Set between a PiP restore request and the resulting PiP stop, so the
    /// stop does not tear down the playback that was just restored.
    @ObservationIgnored private var isRestoringFromPictureInPicture = false

    init(options: LaunchOptions = LaunchOptions()) {
        let player = VLCMediaPlayer(library: Self.library)
        self.player = player
        self.hostViewController = PlayerHostViewController(
            captions: captions,
            comments: comments,
            dataBroadcasting: dataBroadcasting
        )

        delegateProxy.owner = self
        player.delegate = delegateProxy
        // libVLC renders into the drawable through its own sample buffer
        // layer; the overlays live above it in the host view.
        player.drawable = hostViewController.videoView
        player.minimalTimePeriod = 250_000
        player.timeChangeUpdateInterval = 0.25

        // libVLC's picture-in-picture module reads its snapshot from any
        // thread; these closures hop back to the main actor.
        let media = hostViewController.videoView.pipMedia
        media.setAllowsAutomaticPictureInPicture(!options.disablesAutomaticPictureInPicture)
        media.onPlay = { [weak self] in
            Task { @MainActor in self?.play() }
        }
        media.onPause = { [weak self] in
            Task { @MainActor in self?.pause() }
        }
        media.onSeek = { [weak self] offset in
            Task { @MainActor in self?.seek(by: Double(offset) / 1000) }
        }
        media.onStateChange = { [weak self] started in
            Task { @MainActor in
                guard let self else { return }
                if started {
                    self.pictureInPictureDidStart()
                } else {
                    self.pictureInPictureDidStop()
                }
            }
        }

        nowPlaying.onPlay = { [weak self] in self?.play() }
        nowPlaying.onPause = { [weak self] in self?.pause() }
        nowPlaying.onTogglePlayPause = { [weak self] in self?.togglePlayPause() }
        nowPlaying.onSkip = { [weak self] seconds in self?.seek(by: seconds) }
        nowPlaying.onChangePosition = { [weak self] position in self?.seek(to: position) }

        dataBroadcasting.onProgramUpdate = { [weak self] kind, program in
            guard let self else { return }
            switch kind {
            case .present:
                if self.liveProgramPresent != program {
                    self.liveProgramPresent = program
                }
            case .following:
                if self.liveProgramFollowing != program {
                    self.liveProgramFollowing = program
                }
            }
        }

        capture.playback = self
        observeSystemNotifications()
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
        if let current = item, current == playbackItem, isPlayerAttached || liveSession != nil {
            return
        }

        stop()

        item = playbackItem
        self.client = client
        self.profile = profile
        state = "buffering"
        errorDetail = nil
        positionSeconds = 0
        durationSeconds = 0
        liveErrorMessage = nil
        isMuted = false

        activateAudioSession()
        startCurrentItem(startAt: startAt)
    }

    /// Plays a saved video entirely from local storage.
    ///
    /// No server session is created: the stored playlist and segments are
    /// served by a loopback LocalHLSServer, so picture in picture, background
    /// playback and the ARIB caption overlay work the same way as online
    /// playback, without a network.
    func playOffline(_ video: OfflineVideo, directory: URL, startAt: Double = 0) {
        let playbackItem = PlaybackItem.offline(video.program)
        if let current = item, current == playbackItem, isPlayerAttached, offlineServer != nil {
            return
        }

        stop()

        item = playbackItem
        offlineContent = (video, directory)
        client = nil
        state = "buffering"
        errorDetail = nil
        positionSeconds = 0
        durationSeconds = 0
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

    /// Stops playback and releases every task and session.
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
        backgroundTask?.cancel()
        backgroundTask = nil

        stopPlayer()
        detachPipeline()
        nowPlaying.clear()

        item = nil
        client = nil
        state = "idle"
        errorDetail = nil
        positionSeconds = 0
        durationSeconds = 0
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
        didDisableVideoTracks = false
        liveAnchorRequested = false
        comments.isPlaying = false
        comments.isPictureInPictureActive = false
        comments.reset()

        captions.isPictureInPictureActive = false
        captions.end()
    }

    // MARK: - Player lifecycle

    /// Stops the current media without touching item or the pipeline.
    private func stopPlayer() {
        guard isPlayerAttached || player.media != nil else { return }
        isPlayerAttached = false
        snapshotWaiter?.resume(false)
        snapshotWaiter = nil
        player.stop()
        player.media = nil
        clock.reset()
        updatePictureInPictureSnapshot()
        hostViewController.invalidatePictureInPictureState()
    }

    /// Tears down the live / proxy / offline pipeline of the current item.
    private func detachPipeline() {
        dataBroadcasting.end()
        liveProgramPresent = nil
        liveProgramFollowing = nil

        liveSession?.onReady = nil
        liveSession?.onFailed = nil
        liveSession?.onAudioTrackChange = nil
        liveSession?.onCaption = nil
        liveSession?.onSegmentServed = nil
        liveSession?.stop()
        liveSession = nil

        videoProxy?.stop()
        videoProxy = nil

        offlineServer?.stop()
        offlineServer = nil

        liveEvents.onUpdate = nil
        liveEvents.stop()
    }

    private func updatePlaying(_ playing: Bool) {
        if isPlaying != playing {
            isPlaying = playing
        }
        if comments.isPlaying != playing {
            comments.isPlaying = playing
        }
        clock.update(position: clock.settledTime, isPlaying: playing)
    }

    // MARK: - Player controls

    /// Plays or resumes (Space shortcut, Now Playing, picture in picture).
    private func play() {
        guard item != nil else { return }
        player.play()
        invalidatePictureInPictureState()
    }

    /// Pauses (Space shortcut, Now Playing, picture in picture).
    private func pause() {
        guard item != nil else { return }
        player.pause()
        invalidatePictureInPictureState()
    }

    /// Toggles play / pause (Space shortcut).
    func togglePlayPause() {
        guard item != nil else { return }
        if player.isPlaying {
            player.pause()
        } else {
            player.play()
        }
        invalidatePictureInPictureState()
    }

    /// Shows or hides the data broadcasting screen (the live player's d
    /// button). The BML page keeps decoding while it is hidden, like the web
    /// client's container is only hidden.
    func toggleDataBroadcasting() {
        dataBroadcasting.toggleVisibility()
    }

    /// Toggles mute (Q shortcut). iOS has no per-app volume control, but
    /// muting libVLC's audio output is the equivalent of the web client's Q
    /// shortcut.
    func toggleMute() {
        isMuted.toggle()
        player.audio?.isMuted = isMuted
    }

    /// Seeks to an absolute position in seconds.
    func seek(to seconds: Double) {
        guard item != nil, player.isSeekable else { return }
        let target = max(seconds, 0)
        player.time = VLCTime(int: Int32(clamping: Int((target * 1000).rounded())))
        clock.noteSeek(to: target)
        captions.seek(to: target)
        positionSeconds = Int(target)
        invalidatePictureInPictureState()
        updateNowPlaying(force: true)
    }

    /// Seeks relative to the current position.
    func seek(by seconds: Double) {
        seek(to: clock.currentTime + seconds)
    }

    /// Jumps to the live edge (W shortcut, ライブ button).
    ///
    /// A live HLS window is usually not seekable in libVLC, so this restarts
    /// the stream: a fresh load starts at the live edge again.
    func seekToLiveEdge() {
        guard case .live? = item else { return }
        if player.isSeekable, clock.length > 2 {
            seek(to: max(clock.length - 1, 0))
            // libVLC fetches the segment that is on screen now, so the live
            // clock is re-anchored at the current position, not at 0.
            liveAnchorPlaybackTime = clock.currentTime
            liveAnchorRequested = false
            clock.setLiveMapping(nil)
        } else {
            reload(startAt: 0)
        }
    }

    /// Restarts the current item (R shortcut).
    func restart() {
        guard let current = item else { return }
        switch current {
        case .video, .offline:
            reload(startAt: clock.currentTime)
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
        reload(startAt: clock.currentTime)
    }

    /// Switches 主音声 / 副音声 of the live stream without restarting it.
    /// The loopback server filters the audio of the next segment; the caption
    /// extraction and the stream itself keep running.
    func selectLiveAudio(_ selection: AudioSelection) {
        liveAudioSelection = selection
        liveSession?.selectAudio(selection)
    }

    // MARK: - Screen visibility

    func viewAppeared(for playbackItem: PlaybackItem) {
        visibleItem = playbackItem
        // Coming back from picture in picture (or the background) restarts the
        // data broadcasting page.
        dataBroadcasting.resume()
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

    /// The client captures are uploaded with.
    var captureClient: APIClient? { client }

    /// The danmaku overlay view, whose layer tree is rendered into a comment
    /// capture.
    var commentOverlay: CommentOverlayUIView? { hostViewController.commentOverlay }

    /// Playback position in seconds, with sub-second precision for the EXIF
    /// metadata.
    var capturePosition: Double { clock.currentTime }

    /// Decoded video size in pixels (the reference for the capture size),
    /// corrected for anamorphic streams.
    var captureVideoSize: CGSize { displayVideoSize(for: player.videoSize) }

    /// VLCKit keeps the last snapshot it wrote as an image as well; used when
    /// the snapshot file cannot be decoded (the capture still works then).
    var captureLastSnapshot: UIImage? { player.lastSnapshot }

    /// Writes the current video frame to url in the source resolution and
    /// waits for libVLC's snapshot-taken callback.
    ///
    /// saveVideoSnapshotAt:withWidth:andHeight: is asynchronous; a 0 x 0 size
    /// keeps the decoded resolution.
    func saveSnapshot(to url: URL) async -> Bool {
        guard isPlayerAttached, player.hasVideoOut else { return false }

        if let snapshotWaiter {
            snapshotWaiter.resume(false)
        }
        let waiter = SnapshotWaiter()
        snapshotWaiter = waiter
        player.saveVideoSnapshot(at: url.path, withWidth: 0, andHeight: 0)
        let saved = await waiter.wait(timeout: .seconds(3))
        if snapshotWaiter === waiter {
            snapshotWaiter = nil
        }
        return saved
    }

    private var isPlayerScreenVisible: Bool {
        guard let current = item else { return false }
        return visibleItem == current
    }

    // MARK: - Picture in Picture

    /// Starts or stops picture in picture (the PiP button).
    func togglePictureInPicture() {
        guard isPictureInPictureSupported, item != nil, isPlayerAttached else { return }
        if isPictureInPictureActive {
            hostViewController.stopPictureInPicture()
        } else {
            hostViewController.startPictureInPicture()
        }
    }

    /// Called from libVLC's PiP window controller when PiP starts.
    private func pictureInPictureDidStart() {
        isPictureInPictureActive = true
        comments.isPictureInPictureActive = true
        captions.isPictureInPictureActive = true
        // The BML page is not visible in the PiP window: stop feeding it and
        // start it again when the player comes back.
        dataBroadcasting.suspend()
        pictureInPictureStartCount += 1
        // A background transition may have disabled the video output before PiP
        // asked for it; give libVLC its video track back.
        restoreVideoTracks()
        updatePictureInPictureSnapshot()
    }

    /// Called from libVLC's PiP window controller when PiP stops.
    ///
    /// libVLC does not tell us whether the user restored the app or closed the
    /// PiP window, so the app state decides: a foregrounded app was brought
    /// back by the restore button, a backgrounded one just had its window
    /// closed.
    private func pictureInPictureDidStop() {
        isPictureInPictureActive = false
        comments.isPictureInPictureActive = false
        captions.isPictureInPictureActive = false
        dataBroadcasting.resume()

        // Restoring brings the screen back; that must not stop playback.
        if isRestoringFromPictureInPicture {
            isRestoringFromPictureInPicture = false
            return
        }

        guard !isPlayerScreenVisible else { return }

        if UIApplication.shared.applicationState == .active {
            restoreFromPictureInPicture()
        } else {
            stop()
        }
    }

    private func restoreFromPictureInPicture() {
        guard let current = item else { return }
        isRestoringFromPictureInPicture = true
        onRestore?(current)
    }

    private func invalidatePictureInPictureState() {
        updatePictureInPictureSnapshot()
        hostViewController.invalidatePictureInPictureState()
    }

    /// Copies the live state into the lock protected snapshot AVKit reads.
    private func updatePictureInPictureSnapshot() {
        hostViewController.videoView.pipMedia.update(
            time: clock.currentTime,
            length: clock.length,
            isPlaying: clock.isPlaying,
            isSeekable: canSeek
        )
    }

    // MARK: - Item lifecycle

    private func startCurrentItem(startAt: Double) {
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

        stopPlayer()
        detachPipeline()

        captions.end()

        errorDetail = nil
        liveErrorMessage = nil
        liveStatus = ""
        liveDetail = ""
        hasSecondaryAudio = false
        state = "buffering"
        positionSeconds = Int(startAt)
        durationSeconds = 0
        isPlaying = false
        comments.isPlaying = false
        comments.reset()
        didDisableVideoTracks = false

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
        // libVLC never talks to the server directly: the loopback proxy
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
                self.attachPlayer(url: url, item: .video(video), startAt: startAt)
            } catch {
                guard !Task.isCancelled, self.videoProxy === proxy else { return }
                self.errorDetail = ErrorText.message(for: error)
                self.state = "error"
            }
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
                self.attachPlayer(url: url, item: .offline(video.program), startAt: startAt)
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
            self.attachPlayer(url: url, item: .live(channel), startAt: 0)
        }
        session.onFailed = { [weak self, weak session] message in
            guard let self, let session, self.liveSession === session else { return }
            self.liveErrorMessage = message
            self.state = "error"
            self.errorDetail = message
            self.updatePlaying(false)
        }
        session.onAudioTrackChange = { [weak self, weak session] hasSecondary in
            guard let self, let session, self.liveSession === session else { return }
            self.hasSecondaryAudio = hasSecondary
        }
        // The caption PTS is mapped onto the player's timeline with the live
        // clock, which the loopback server anchors to the segment libVLC
        // actually fetched first.
        session.onCaption = { [weak self, weak session] pes in
            guard let self, let session, self.liveSession === session else { return }
            guard let playbackTime = self.liveCaptionTime(for: pes) else { return }
            self.captions.feed(pes, at: playbackTime)
        }
        // The first segment the loopback server serves after a load is the
        // segment libVLC starts from: its PROGRAM-DATE-TIME and first video PTS
        // anchor the live clock.
        session.onSegmentServed = { [weak self, weak session] sequence in
            guard let self, let session, self.liveSession === session else { return }
            self.segmentServed(sequence)
        }

        liveSession = session
        hasSecondaryAudio = session.hasSecondaryAudio
        liveAudioSelection = .primary
        session.start()

        // The data broadcasting page is recreated for every channel / quality
        // change (the web client restarts its BML browser the same way).
        liveProgramPresent = nil
        liveProgramFollowing = nil
        dataBroadcasting.begin(channel: channel, client: client, profile: profile)

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

    /// Anchors the live clock to the first segment the loopback server served
    /// after this load.
    private func segmentServed(_ sequence: Int) {
        guard case .live? = item else { return }
        guard !liveAnchorRequested, clock.liveMapping == nil else { return }
        liveAnchorRequested = true
        guard let session = liveSession else { return }

        Task { [weak self, weak session] in
            guard let self, let session, self.liveSession === session else { return }
            guard let anchor = await session.segmentAnchor(sequence: sequence) else {
                self.liveAnchorRequested = false
                return
            }
            self.applyLiveAnchor(anchor)
        }
    }

    /// Playback position of a live caption packet.
    ///
    /// A packet whose PTS lands far away from the playhead means the stream
    /// restarted its clock (an encoder restart, or the discontinuity the mock
    /// live stream produces when it loops): the live clock is re-anchored at
    /// the current position so captions keep lining up.
    private func liveCaptionTime(for pes: CaptionPES) -> Double? {
        let now = clock.settledTime
        let fallback: Double? = clock.isPlaying || now > 0 ? clock.currentTime : nil
        guard let pts = pes.pts, let mapping = clock.liveMapping else {
            return fallback
        }
        let mapped = mapping.playbackTime(forPTS: pts)
        guard clock.isPlaying, mapped < now - 5 || mapped > now + 30 else {
            return mapped
        }
        clock.setLiveMapping(
            LivePlaybackClock(
                playbackTime: now,
                date: mapping.date(forPlaybackTime: now),
                pts: pts
            )
        )
        return now
    }

    private func applyLiveAnchor(_ anchor: SegmentAnchor) {
        let mapping = LivePlaybackClock(
            playbackTime: liveAnchorPlaybackTime,
            date: anchor.date,
            pts: anchor.firstPTS
        )
        clock.setLiveMapping(mapping)
        // Caption packets that arrived before the anchor wait for the next one;
        // the renderer timeline restarts from the anchored position.
        captions.seek(to: clock.currentTime)
    }

    // MARK: - Media

    /// Attaches a URL (live playlist, proxy playlist or offline playlist) to
    /// the long-lived player.
    private func attachPlayer(url: URL, item expected: PlaybackItem, startAt: Double) {
        guard let current = item, current == expected else { return }
        guard let media = makeMedia(url: url, item: expected) else {
            errorDetail = "再生に失敗しました。"
            state = "error"
            return
        }

        activateAudioSession()

        isPlayerAttached = true
        pendingStartPosition = startAt
        clock.begin(startAt: startAt, isSeekable: expected.isVideo)
        liveAnchorRequested = false
        liveAnchorPlaybackTime = 0
        clock.setLiveMapping(nil)
        updatePlaying(false)
        updatePictureInPictureSnapshot()
        hostViewController.invalidatePictureInPictureState()

        player.media = media
        player.play()

        captions.beginVideoOrLive(isLive: !expected.isVideo) { [weak self] in
            self?.clock.currentTime
        }

        updateVideoSize()
        updateNowPlaying(force: true)
    }

    /// Media options of one load.
    ///
    /// Subtitles stay off: the app extracts the ARIB caption PES packets itself
    /// (the proxies strip them from the segments VLC plays) and renders them
    /// with libaribcaption, so letting libVLC draw its own would double them.
    private func makeMedia(url: URL, item playbackItem: PlaybackItem) -> VLCMedia? {
        guard let media = VLCMedia(url: url) else { return nil }
        media.addOption(":no-spu")
        media.addOption(":no-sub-autodetect-file")
        // VideoToolbox hardware decoding; the app never needs software output.
        media.addOption(":avcodec-hw=any")
        switch playbackItem {
        case .live:
            media.addOption(":network-caching=\(Self.liveNetworkCaching)")
        case .video:
            media.addOption(":network-caching=\(Self.videoNetworkCaching)")
        case .offline:
            media.addOption(":network-caching=\(Self.offlineNetworkCaching)")
        }
        return media
    }

    private func activateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    private func currentLength() -> Double {
        guard item?.isVideo == true else { return 0 }
        let millis = player.media?.length.value?.doubleValue ?? 0
        guard millis.isFinite, millis > 0 else { return 0 }
        return millis / 1000
    }

    // MARK: - libVLC callbacks (main actor)

    /// libVLC changed its playback state.
    func playerStateChanged(_ newState: VLCMediaPlayerState) {
        guard item != nil else { return }

        switch newState {
        case .error:
            failWithCurrentError()
            return
        case .opening:
            state = "buffering"
        case .playing:
            errorDetail = nil
            state = "playing"
        case .paused:
            state = "paused"
        case .stopped, .stopping, .nothingSpecial:
            state = clock.settledTime > 0 ? "paused" : "buffering"
        @unknown default:
            break
        }

        let playing = newState == .playing
        updatePlaying(playing)
        clock.update(position: clock.settledTime, length: currentLength(), isPlaying: playing)
        durationSeconds = clock.length
        applyPendingStartPositionIfNeeded()
        updateVideoSize()
        invalidatePictureInPictureState()
        updateNowPlaying(force: true)
    }

    /// libVLC's buffering progress. VLCMediaPlayerState has no buffering case,
    /// so this is the only signal for a stalled live stream.
    func playerBufferingChanged(_ progress: Float) {
        guard item != nil else { return }
        if progress < 1, state != "paused", state != "error" {
            state = "buffering"
            updatePlaying(false)
        } else if progress >= 1, state == "buffering", player.state == .playing {
            state = "playing"
        }
    }

    /// libVLC reported the media length in milliseconds.
    func playerLengthChanged(milliseconds: Int64) {
        guard item != nil, milliseconds > 0 else { return }
        clock.update(
            position: clock.settledTime,
            length: Double(milliseconds) / 1000
        )
        durationSeconds = clock.length
        invalidatePictureInPictureState()
    }

    /// libVLC reported a new position in milliseconds.
    func playerTimeChanged(milliseconds: Double) {
        guard item != nil, player.media != nil else { return }
        let seconds = milliseconds / 1000
        let playing = player.state == .playing
        clock.update(position: seconds, length: currentLength(), isPlaying: playing)
        updatePlaying(playing)
        durationSeconds = clock.length
        positionSeconds = max(Int(seconds), 0)

        switch item {
        case .video(let video)?, .offline(let video)?:
            onVideoProgress?(video, max(seconds, 0))
        default:
            break
        }

        updateVideoSize()
        updatePictureInPictureSnapshot()
        updateNowPlaying(force: false)
    }

    /// libVLC wrote the snapshot requested by saveSnapshot(to:).
    func playerSnapshotTaken() {
        snapshotWaiter?.resume(true)
    }

    private func failWithCurrentError() {
        let message = VLCLibrary.currentErrorMessage ?? "再生に失敗しました。"
        errorDetail = message
        state = "error"
        updatePlaying(false)
        if case .live? = item {
            liveErrorMessage = message
        }
        updateNowPlaying(force: true)
    }

    private func applyPendingStartPositionIfNeeded() {
        guard pendingStartPosition > 0 else { return }
        guard player.state == .playing || player.state == .paused else { return }
        let target = pendingStartPosition
        pendingStartPosition = 0
        player.time = VLCTime(int: Int32(clamping: Int((target * 1000).rounded())))
        clock.noteSeek(to: target)
        captions.seek(to: target)
        invalidatePictureInPictureState()
    }

    private func updateVideoSize() {
        let size = displayVideoSize(for: player.videoSize)
        guard size.width >= 1, size.height >= 1 else { return }
        if size != hostViewController.videoSize {
            hostViewController.videoSize = size
        }
    }

    /// libVLC reports the coded video size. Anamorphic broadcasts (1440x1080
    /// with a 4:3 sample aspect ratio) are shown at 16:9, so the letterboxed
    /// rect of the overlays and the capture size need the sample aspect ratio
    /// of the video track, not the coded pixel count.
    private func displayVideoSize(for size: CGSize) -> CGSize {
        guard size.width >= 1, size.height >= 1,
              size.width.isFinite, size.height.isFinite else {
            return .zero
        }
        guard let video = player.videoTracks.first?.video,
              video.sourceAspectRatio > 0,
              video.sourceAspectRatioDenominator > 0 else {
            return size
        }
        let sar = Double(video.sourceAspectRatio) / Double(video.sourceAspectRatioDenominator)
        guard sar.isFinite, sar > 0, abs(sar - 1) > 0.01 else { return size }
        return CGSize(width: (size.width * sar).rounded(), height: size.height)
    }

    // MARK: - Now Playing

    private func updateNowPlaying(force: Bool) {
        guard let current = item else {
            nowPlaying.clear()
            return
        }
        nowPlaying.update(
            title: current.title,
            subtitle: current.subtitle,
            position: clock.currentTime,
            length: clock.length,
            isPlaying: clock.isPlaying,
            isLive: !current.isVideo,
            canSeek: canSeek,
            artworkURL: artworkURL(for: current),
            force: force
        )
    }

    /// Channel logo (live) or video thumbnail (recorded) for the lock screen.
    private func artworkURL(for playbackItem: PlaybackItem) -> URL? {
        guard let client else { return nil }
        switch playbackItem {
        case .live(let channel):
            return client.logoURL(channelID: channel.displayChannelID)
        case .video(let video):
            return client.thumbnailURL(videoID: video.id)
        case .offline:
            // Saved videos have no server to ask for their thumbnail.
            return nil
        }
    }

    // MARK: - System notifications

    private func observeSystemNotifications() {
        let center = NotificationCenter.default

        if interruptionObserver == nil {
            interruptionObserver = center.addObserver(
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

        if dataBroadcastingSettingsObserver == nil {
            dataBroadcastingSettingsObserver = center.addObserver(
                forName: .dataBroadcastingSettingsDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.dataBroadcasting.reloadSettings()
                }
            }
        }

        if backgroundObserver == nil {
            backgroundObserver = center.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.applicationDidEnterBackground()
                }
            }
        }

        if foregroundObserver == nil {
            foregroundObserver = center.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.applicationWillEnterForeground()
                }
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
        play()
    }

    /// Background audio keeps playing (the app declares the audio background
    /// mode and has an active playback session). Without picture in picture the
    /// video output is not visible anyway, so its tracks are dropped after a
    /// short grace period to save power - but only once it is clear that PiP
    /// did not start.
    private func applicationDidEnterBackground() {
        guard item != nil, isPlayerAttached else { return }
        // Nothing of the BML page is visible in the background; restart it on
        // return (the PSI stream would stall anyway).
        dataBroadcasting.suspend()
        backgroundTask?.cancel()
        backgroundTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            guard !self.isPictureInPictureActive, !self.didDisableVideoTracks else { return }
            guard self.player.hasVideoOut else { return }
            self.player.deselectAllVideoTracks()
            self.didDisableVideoTracks = true
        }
    }

    private func applicationWillEnterForeground() {
        backgroundTask?.cancel()
        backgroundTask = nil
        restoreVideoTracks()
        if !isPictureInPictureActive {
            dataBroadcasting.resume()
        }
    }

    private func restoreVideoTracks() {
        guard didDisableVideoTracks else { return }
        didDisableVideoTracks = false
        guard player.videoTracks.count > 0 else { return }
        player.selectTrack(at: 0, type: .video)
        updateVideoSize()
        invalidatePictureInPictureState()
    }
}

// MARK: - libVLC delegate bridge

/// Forwards libVLC's player callbacks to the controller.
///
/// libVLC invokes these from its own threads (the delegate is dispatched from
/// libVLC's event loop), so every method stays nonisolated and hops to the main
/// actor with plain values. No main-actor state is touched synchronously.
final class PlayerDelegateProxy: NSObject, VLCMediaPlayerDelegate {
    weak var owner: PlaybackController?

    func mediaPlayerStateChanged(_ newState: VLCMediaPlayerState) {
        Task { @MainActor [weak owner] in
            owner?.playerStateChanged(newState)
        }
    }

    func mediaPlayerBufferingChanged(_ progress: Float) {
        Task { @MainActor [weak owner] in
            owner?.playerBufferingChanged(progress)
        }
    }

    func mediaPlayerLengthChanged(_ length: Int64) {
        Task { @MainActor [weak owner] in
            owner?.playerLengthChanged(milliseconds: length)
        }
    }

    func mediaPlayerTimeChanged(_ aNotification: Notification) {
        // The time is read here, on libVLC's thread: only a Double crosses.
        let player = aNotification.object as? VLCMediaPlayer
        let milliseconds = player?.time.value?.doubleValue ?? 0
        Task { @MainActor [weak owner] in
            owner?.playerTimeChanged(milliseconds: milliseconds)
        }
    }

    func mediaPlayerSnapshot(_ aNotification: Notification) {
        Task { @MainActor [weak owner] in
            owner?.playerSnapshotTaken()
        }
    }
}

// MARK: - Snapshot waiting

/// Bridges libVLC's asynchronous snapshot callback into async code.
final class SnapshotWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    func wait(timeout: Duration) async -> Bool {
        await withCheckedContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()

            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.resume(false)
            }
        }
    }

    func resume(_ saved: Bool) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: saved)
    }
}
