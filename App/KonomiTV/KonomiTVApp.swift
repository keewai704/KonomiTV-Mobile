import SwiftUI
import AVFoundation
import UIKit
import KonomiKit

/// Values derived from the process launch arguments and environment.
struct LaunchOptions: Sendable {
    let isUITesting: Bool
    let showsSetup: Bool
    let serverURLOverride: URL?
    /// UI tests that check background playback without picture in picture pass
    /// `-UITestingDisableAutoPiP`.
    let disablesAutomaticPictureInPicture: Bool
    /// Shortens the watch history threshold (30 s) to a couple of seconds so a
    /// UI test does not have to keep a video playing for half a minute.
    let usesShortWatchedHistoryThreshold: Bool
    /// Replaces the Niconico `ASWebAuthenticationSession` sheet with a plain
    /// URLSession round trip, so the link flow runs on CI without a system sheet.
    let disablesASWebAuthentication: Bool
    /// UI tests that operate the player controls, rather than check that they
    /// hide, pass `-UITestingKeepControls`.
    let keepsPlayerControlsVisible: Bool
    /// How long the player controls stay on screen while playing, or nil when
    /// they stay until the picture is tapped. UI tests get longer than the 3 s
    /// users see: each query and tap of a test can take a second or more on
    /// CI, and the controls would hide between them.
    var controlsAutoHideDelay: Duration? {
        if keepsPlayerControlsVisible { return nil }
        return isUITesting ? .seconds(8) : .seconds(3)
    }

    init(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.isUITesting = arguments.contains("-UITesting")
        self.showsSetup = arguments.contains("-UITestingShowSetup")
        self.disablesAutomaticPictureInPicture = arguments.contains("-UITestingDisableAutoPiP")
        self.usesShortWatchedHistoryThreshold = arguments.contains("-UITestingShortHistoryThreshold")
        self.disablesASWebAuthentication = arguments.contains("-UITestingDisableASWebAuth")
        self.keepsPlayerControlsVisible = arguments.contains("-UITestingKeepControls")

        if let raw = environment["KONOMITV_SERVER_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty,
           let url = try? ServerURL(validating: raw).url {
            self.serverURLOverride = url
        } else {
            self.serverURLOverride = nil
        }
    }

    /// Applies the test hooks described in the spec: `-UITesting` wipes all
    /// persisted state, `KONOMITV_SERVER_URL` preselects a server unless
    /// `-UITestingShowSetup` is also passed.
    ///
    /// Not actor isolated: `UserDefaults` and the Keychain are both safe to
    /// touch from any thread.
    func preparePersistence(defaults: UserDefaults = .standard) {
        if isUITesting {
            defaults.removeObject(forKey: PreferenceKeys.serverURL)
            QualityPreferences.removeAll(defaults: defaults)
            defaults.removeObject(forKey: PreferenceKeys.clientSettings)
            defaults.removeObject(forKey: PreferenceKeys.syncSettings)
            for key in [
                PreferenceKeys.captionFont,
                PreferenceKeys.alwaysBorderCaptionText,
                PreferenceKeys.specifyCaptionOpacity,
                PreferenceKeys.captionOpacity,
                PreferenceKeys.tvShowSuperimpose,
                PreferenceKeys.videoShowSuperimpose,
                PreferenceKeys.tvShowDataBroadcasting,
                PreferenceKeys.enableInternetAccessFromDataBroadcasting,
                PreferenceKeys.dataBroadcastingZipCode,
                PreferenceKeys.dataBroadcastingPrefecture,
                PreferenceKeys.twitterPanelAccount,
                PreferenceKeys.twitterPanelPostTargets,
                PreferenceKeys.twitterReplyThreadStates,
                PreferenceKeys.blueskyReplyThreadStates,
            ] {
                defaults.removeObject(forKey: key)
            }
            KeychainStore.delete(account: KeychainStore.tokenAccount)
            // Saved offline videos outlive a normal launch; UI tests start from
            // an empty library so "save / play / delete" is deterministic.
            OfflineVideoManager.removeAllStorage()
        }

        if !showsSetup, let serverURLOverride {
            defaults.set(serverURLOverride.absoluteString, forKey: PreferenceKeys.serverURL)
        }
    }
}

@main
struct KonomiTVApp: App {
    /// Only supplies the orientation lock of the fullscreen player.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel

    init() {
        let options = LaunchOptions()
        options.preparePersistence()
        QualityPreferences.migrate()
        if options.isUITesting {
            MainActor.assumeIsolated {
                UIView.setAnimationsEnabled(false)
            }
        }
        Self.configureAudioSession()
        _model = State(initialValue: MainActor.assumeIsolated { AppModel() })
    }

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
        }
    }

    /// Playback category so video keeps playing with the mute switch on and
    /// can use AirPlay / picture in picture. PlaybackController activates it
    /// when playback starts, so launching the app does not stop audio from
    /// other apps.
    private static func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback)
        } catch {
            // The system default category still allows inline playback.
        }
    }
}
