import CoreGraphics
import Foundation
import KonomiKit
import Observation

extension Notification.Name {
    /// Posted when the データ放送 settings changed (the page uses them at start).
    static let dataBroadcastingSettingsDidChange = Notification.Name("DataBroadcastingSettingsDidChange")
}

/// Which of the EIT[p/f] programs an update belongs to.
enum DataBroadcastingProgramKind: Sendable {
    case present
    case following
}

/// Owns the data broadcasting (BML) page of the live player.
///
/// This is the app side of the web client's `LiveDataBroadcastingManager`
/// plus its `LivePSIArchivedDataDecoder`: it starts the page for a live
/// channel, keeps the native state (visibility, usable remote keys, video
/// plane) in sync with the page's messages and turns settings into the page
/// configuration. The page itself (web-bml in a WKWebView) is the only part of
/// the app that is not native; everything around it is native SwiftUI.
@MainActor
@Observable
final class DataBroadcastingController {
    /// Mirrors the page's `state` messages. `.off` and `.unavailable` are
    /// the states in which the app hides the feature (no data broadcasting in
    /// this channel, or the setting is off).
    enum State: String, Sendable {
        case off
        case loading
        case ready
        case visible
        case invisible
        case unavailable
        case error
    }

    /// Current state of the data broadcasting page.
    private(set) var state: State = .off {
        didSet {
            if state != oldValue {
                AppLog.dataBroadcasting.notice("state \(oldValue.rawValue, privacy: .public) -> \(self.state.rawValue, privacy: .public)")
            }
        }
    }
    /// Remote control keys the BML content accepts (web-bml's used-key-list).
    /// The data button (`d`) is always included.
    private(set) var enabledKeys: Set<String> = ["d"]
    /// Last error reported by the page (web-bml's showErrorMessage).
    private(set) var errorMessage: String?
    /// Rect of the BML video plane in the player host view's coordinates, or
    /// nil when the video fills the player.
    private(set) var videoRect: CGRect?

    /// Called when the video plane moved (nil = video fills the player).
    @ObservationIgnored var onVideoPlaneChanged: (@MainActor (CGRect?) -> Void)?
    /// Called for every EIT[p/f] program the PSI stream reports.
    @ObservationIgnored var onProgramUpdate: (@MainActor (DataBroadcastingProgramKind, Program) -> Void)?

    /// The page. Weak: the player host view owns it.
    @ObservationIgnored private weak var page: DataBroadcastingWebView?
    @ObservationIgnored private var session: LiveSession?
    @ObservationIgnored private var defaults: UserDefaults
    /// True between suspend() and resume() (picture in picture / background).
    @ObservationIgnored private var isSuspended = false
    /// Whether the page currently holds a started session.
    @ObservationIgnored private var isPageStarted = false
    /// Last size the page was told about (layout callbacks are frequent).
    @ObservationIgnored private var lastPageSize: CGSize = .zero

    private struct LiveSession {
        let channel: LiveChannel
        let client: APIClient
        let profile: StreamingProfile
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Derived state

    /// Whether the app shows the data broadcasting controls (toolbar toggle,
    /// remote). False when the setting is off or the channel has no BML.
    var isFeatureAvailable: Bool {
        switch state {
        case .off, .unavailable:
            return false
        case .loading, .ready, .visible, .invisible, .error:
            return true
        }
    }

    /// Whether the BML screen is on screen (the video is in the video plane).
    var isPageVisible: Bool {
        state == .ready || state == .visible
    }

    /// Whether the page is still preparing (the remote shows a spinner).
    var isLoading: Bool {
        state == .loading
    }

    /// The current data broadcasting settings.
    var settings: DataBroadcastingSettings {
        DataBroadcastingSettings.load(from: defaults)
    }

    // MARK: - Wiring

    /// Called once by the player host view, which owns the page view.
    ///
    /// Playback starts before the player screen exists (the screen only shows
    /// the player once libVLC has a media), so a session that was started
    /// without a page is started here.
    func attach(page: DataBroadcastingWebView) {
        self.page = page
        if session != nil, !isSuspended, !isPageStarted, settings.isEnabled {
            startPage()
        }
    }

    /// Starts data broadcasting for a live channel (channel or quality change).
    func begin(channel: LiveChannel, client: APIClient, profile: StreamingProfile) {
        end()
        // A radio channel has no video and no BML carousel.
        guard !channel.isRadioChannel else {
            state = .off
            return
        }
        session = LiveSession(channel: channel, client: client, profile: profile)
        startPage()
    }

    /// Stops the page (channel change, quality change, playback stopped).
    func end() {
        session = nil
        isSuspended = false
        stopPage()
    }

    /// Stops feeding the page while picture in picture or the background hides
    /// the player, keeping the channel so resume() can start it again.
    func suspend() {
        guard session != nil, !isSuspended else { return }
        isSuspended = true
        stopPage()
    }

    /// Restarts the page after picture in picture / background ended.
    func resume() {
        guard isSuspended, session != nil else { return }
        isSuspended = false
        startPage()
    }

    /// Re-reads the settings (the settings screen stores them in UserDefaults)
    /// and stops or restarts the page when the feature was turned on or off.
    func reloadSettings() {
        guard session != nil, !isSuspended else { return }
        if settings.isEnabled {
            if !isPageStarted {
                startPage()
            }
        } else {
            stopPage()
        }
    }

    // MARK: - Page input

    /// The toolbar toggle and the remote's d button: shows or hides the BML
    /// screen (the web client's d behaviour, with the video plane kept native).
    func toggleVisibility() {
        guard isFeatureAvailable else { return }
        page?.call("KonomiBML.toggle()")
    }

    /// Sends one remote control key (press and release, like the web client).
    func sendKey(_ name: String) {
        guard isFeatureAvailable else { return }
        // One round trip: press and release, like the web client's remote.
        page?.call("KonomiBML.key('\(name)', true); KonomiBML.key('\(name)', false)")
    }

    /// The player host view changed size (rotation, window resize).
    func pageSizeChanged(to size: CGSize) {
        guard size.width >= 1, size.height >= 1, size != lastPageSize else { return }
        lastPageSize = size
        page?.resize(to: size)
    }

    // MARK: - Page lifecycle

    private func startPage() {
        guard let session else {
            state = .off
            return
        }
        guard settings.isEnabled else {
            state = .off
            return
        }
        guard let page else {
            // The player screen (and with it the page view) does not exist
            // yet: attach() starts the page once it does.
            state = .loading
            return
        }

        isPageStarted = true
        state = .loading
        errorMessage = nil
        enabledKeys = ["d"]
        setVideoRect(nil)
        page.setInputEnabled(false)

        let settings = self.settings
        page.load(
            configuration: BMLPageConfiguration(
                channelID: session.channel.displayChannelID,
                networkID: session.channel.networkID,
                serviceID: session.channel.serviceID,
                quality: session.profile.apiQuality(isRadioChannel: session.channel.isRadioChannel),
                internetAccess: settings.allowsInternetAccess,
                receiverInfo: settings.nvramValues,
                serverBaseURL: session.client.baseURL,
                token: session.client.token
            )
        )
    }

    private func stopPage() {
        isPageStarted = false
        page?.unload()
        setVideoRect(nil)
        enabledKeys = ["d"]
        if state != .off {
            state = .off
        }
    }

    /// The page could not be loaded at all (a WebKit failure, not a BML error).
    func pageDidFail(_ message: String) {
        errorMessage = message
        state = .error
        setVideoRect(nil)
    }

    // MARK: - Page messages

    /// Handles one `window.webkit.messageHandlers.bml` message.
    func handle(message: [String: Any]) {
        guard let type = message["type"] as? String else { return }
        switch type {
        case "state":
            guard let raw = message["state"] as? String,
                  let newState = State(rawValue: raw) else { return }
            state = newState
            if !isPageVisible {
                setVideoRect(nil)
            }
            // The page only receives touches while the BML screen is on screen.
            page?.setInputEnabled(newState == .ready || newState == .visible)
        case "usedKeys":
            let keys = message["keys"] as? [String] ?? ["d"]
            enabledKeys = Set(keys)
        case "videoRect":
            applyVideoRect(message)
        case "programPF":
            applyProgramUpdate(message)
        case "error":
            errorMessage = [message["title"], message["message"], message["code"]]
                .compactMap { $0 as? String }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            state = .error
        case "log":
            break
        default:
            break
        }
    }

    private func applyVideoRect(_ message: [String: Any]) {
        guard let rect = message["rect"] as? [String: Any],
              let pageSize = message["pageSize"] as? [String: Any],
              let left = rect["left"] as? Double,
              let top = rect["top"] as? Double,
              let width = rect["width"] as? Double,
              let height = rect["height"] as? Double,
              let pageWidth = pageSize["width"] as? Double,
              let pageHeight = pageSize["height"] as? Double,
              pageWidth >= 1, pageHeight >= 1,
              width >= 1, height >= 1,
              let page = self.page else {
            setVideoRect(nil)
            return
        }
        // The page's CSS pixels and the view's points have the same size unless
        // the page is zoomed; scale anyway so a mismatch stays harmless.
        let hostSize = page.bounds.size
        let scaleX = hostSize.width / pageWidth
        let scaleY = hostSize.height / pageHeight
        let converted = CGRect(
            x: left * scaleX,
            y: top * scaleY,
            width: width * scaleX,
            height: height * scaleY
        )
        setVideoRect(converted.integral)
    }

    private func applyProgramUpdate(_ message: [String: Any]) {
        guard let name = message["presentOrFollowing"] as? String,
              let body = message["program"] as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: body),
              let program = try? JSONCoding.makeDecoder().decode(Program.self, from: data) else {
            return
        }
        onProgramUpdate?(name == "Following" ? .following : .present, program)
    }

    private func setVideoRect(_ rect: CGRect?) {
        guard videoRect != rect else { return }
        videoRect = rect
        onVideoPlaneChanged?(rect)
    }
}
