import Foundation
import UIKit
import VLCKit

/// The block libVLC stores from `pictureInPictureReady`.
typealias PictureInPictureReadyHandler = @convention(block) (AnyObject) -> Void

/// Mirror of VLCKit's `VLCPictureInPictureDrawable` protocol.
///
/// It is declared here, with the same Objective-C name and the same selectors,
/// instead of using the imported protocol: a `UIView` subclass cannot witness
/// the imported requirements from the main actor, and the PiP-ready block's
/// imported convention depends on the `dispatch_block_t` typedef. libVLC only
/// looks the protocol up by name (`conformsToProtocol:`) and then sends the
/// selectors, so a local mirror is all it needs at runtime.
@objc(VLCPictureInPictureDrawable)
protocol PlayerPictureInPictureDrawable: NSObjectProtocol {
    /// The object that answers libVLC's PiP playback questions.
    @objc(mediaController)
    func mediaController() -> AnyObject

    /// Receives libVLC's PiP window controller once the video output is ready.
    @objc(pictureInPictureReady)
    func pictureInPictureReady() -> PictureInPictureReadyHandler

    /// Read by libVLC when it creates the PiP controller. Not part of the
    /// header; libVLC asks for it with `respondsToSelector:` and uses YES when
    /// the drawable does not implement it.
    @objc(canStartPictureInPictureAutomaticallyFromInline)
    func canStartPictureInPictureAutomaticallyFromInline() -> Bool
}

/// The playback snapshot picture in picture reads.
///
/// AVKit and libVLC call `mediaTime`, `mediaLength`, `isMediaPlaying` and
/// `isMediaSeekable` synchronously from whatever thread they are on, so they
/// are answered from this lock protected copy instead of main-actor state.
/// `play`, `pause` and `seekBy:completion:` forward to the main actor.
final class PlayerPictureInPictureMediaController: NSObject, @unchecked Sendable {
    private struct Snapshot {
        var time: Double = 0
        var length: Double = 0
        var isPlaying = false
        var isSeekable = false
        var allowsAutomaticPictureInPicture = false
    }

    private let lock = NSLock()
    private var snapshot = Snapshot()
    private var windowController: (any VLCPictureInPictureWindowControlling)?

    /// Hop to the main actor before touching the player.
    var onPlay: (@Sendable () -> Void)?
    var onPause: (@Sendable () -> Void)?
    /// The offset is in milliseconds, like libVLC's PiP contract.
    var onSeek: (@Sendable (Int64) -> Void)?
    /// Called with `true` when PiP starts and `false` when it stops.
    var onStateChange: (@Sendable (Bool) -> Void)?

    // MARK: - State (main actor)

    func update(time: Double, length: Double, isPlaying: Bool, isSeekable: Bool) {
        lock.lock()
        snapshot.time = time.isFinite ? max(time, 0) : 0
        snapshot.length = length.isFinite ? max(length, 0) : 0
        snapshot.isPlaying = isPlaying
        snapshot.isSeekable = isSeekable
        lock.unlock()
    }

    func setAllowsAutomaticPictureInPicture(_ allowed: Bool) {
        lock.lock()
        snapshot.allowsAutomaticPictureInPicture = allowed
        lock.unlock()
    }

    var allowsAutomaticPictureInPicture: Bool {
        lock.lock()
        defer { lock.unlock() }
        return snapshot.allowsAutomaticPictureInPicture
    }

    var hasWindowController: Bool {
        lock.lock()
        defer { lock.unlock() }
        return windowController != nil
    }

    // MARK: - libVLC's window controller

    /// Called from `pictureInPictureReady` (main thread, libVLC prepares the
    /// video output there).
    func attach(pictureInPictureController controller: AnyObject) {
        guard let window = controller as? any VLCPictureInPictureWindowControlling else {
            return
        }
        window.stateChangeEventHandler = { [weak self] started in
            self?.onStateChange?(started)
        }
        lock.lock()
        windowController = window
        lock.unlock()
    }

    @MainActor
    func startPictureInPicture() {
        currentWindowController?.startPictureInPicture()
    }

    @MainActor
    func stopPictureInPicture() {
        currentWindowController?.stopPictureInPicture()
    }

    /// Must follow every play / pause / seek / length change, otherwise the PiP
    /// window keeps showing the old position and time range.
    @MainActor
    func invalidatePlaybackState() {
        currentWindowController?.invalidatePlaybackState()
    }

    private var currentWindowController: (any VLCPictureInPictureWindowControlling)? {
        lock.lock()
        defer { lock.unlock() }
        return windowController
    }

    // MARK: - VLCPictureInPictureMediaControlling selectors

    @objc func play() {
        onPlay?()
    }

    @objc func pause() {
        onPause?()
    }

    /// libVLC and AVKit expect the completion block to be called; the seek is
    /// applied right afterwards on the main actor.
    @objc(seekBy:completion:)
    func seekBy(_ offset: Int64, completion: (() -> Void)?) {
        completion?()
        onSeek?(offset)
    }

    /// Milliseconds, or `Int64.max` (`VLC_TICK_INVALID`) for live media so
    /// AVKit shows the live time range.
    @objc func mediaLength() -> Int64 {
        let snapshot = currentSnapshot()
        guard snapshot.isSeekable, snapshot.length > 0 else { return Int64.max }
        return Int64((snapshot.length * 1000).rounded())
    }

    @objc func mediaTime() -> Int64 {
        Int64((currentSnapshot().time * 1000).rounded())
    }

    @objc func isMediaSeekable() -> Bool {
        currentSnapshot().isSeekable
    }

    @objc func isMediaPlaying() -> Bool {
        currentSnapshot().isPlaying
    }

    private func currentSnapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }
}

/// The view libVLC renders the video into.
///
/// libVLC adds its `AVSampleBufferDisplayLayer` view as a subview and positions
/// it itself (letterboxing included), so this is a plain container. It also
/// carries the picture-in-picture selectors libVLC looks for.
@MainActor
final class PlayerDrawableView: UIView, @preconcurrency VLCDrawable,
                               PlayerPictureInPictureDrawable {
    /// Shared with libVLC's PiP window controller.
    let pipMedia = PlayerPictureInPictureMediaController()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - PlayerPictureInPictureDrawable (VLCPictureInPictureDrawable)

    nonisolated func mediaController() -> AnyObject {
        pipMedia
    }

    nonisolated func pictureInPictureReady() -> PictureInPictureReadyHandler {
        // The block is called on libVLC's main-thread video output setup; the
        // media controller stores the window controller behind its lock.
        let media = pipMedia
        return { controller in
            media.attach(pictureInPictureController: controller)
        }
    }

    nonisolated func canStartPictureInPictureAutomaticallyFromInline() -> Bool {
        pipMedia.allowsAutomaticPictureInPicture
    }
}
