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

    init(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.isUITesting = arguments.contains("-UITesting")
        self.showsSetup = arguments.contains("-UITestingShowSetup")
        self.disablesAutomaticPictureInPicture = arguments.contains("-UITestingDisableAutoPiP")
        self.usesShortWatchedHistoryThreshold = arguments.contains("-UITestingShortHistoryThreshold")

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
            defaults.removeObject(forKey: PreferenceKeys.liveQuality)
            defaults.removeObject(forKey: PreferenceKeys.videoQuality)
            defaults.removeObject(forKey: PreferenceKeys.clientSettings)
            defaults.removeObject(forKey: PreferenceKeys.syncSettings)
            KeychainStore.delete(account: KeychainStore.tokenAccount)
        }

        if !showsSetup, let serverURLOverride {
            defaults.set(serverURLOverride.absoluteString, forKey: PreferenceKeys.serverURL)
        }
    }
}

@main
struct KonomiTVApp: App {
    @State private var model: AppModel

    init() {
        let options = LaunchOptions()
        options.preparePersistence()
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
    /// can use AirPlay / picture in picture. The session is activated by
    /// AVPlayer when playback starts, so launching the app does not stop audio
    /// from other apps.
    private static func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback)
        } catch {
            // The system default category still allows inline playback.
        }
    }
}
