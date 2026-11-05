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

    /// Returns whether the playing state, seekability or length changed:
    /// AVKit only reads those again after `invalidatePlaybackState`.
    @discardableResult
    func update(time: Double, length: Double, isPlaying: Bool, isSeekable: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let length = length.isFinite ? max(length, 0) : 0
        let changed = snapshot.isPlaying != isPlaying
            || snapshot.isSeekable != isSeekable
            || snapshot.length != length
        snapshot.time = time.isFinite ? max(time, 0) : 0
        snapshot.length = length
        snapshot.isPlaying = isPlaying
        snapshot.isSeekable = isSeekable
        return changed
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
            AppLog.playback.error("pip ready with an unexpected controller \(String(describing: type(of: controller)), privacy: .public)")
            return
        }
        AppLog.playback.notice("pip window controller ready (auto=\(self.allowsAutomaticPictureInPicture, privacy: .public))")
        window.stateChangeEventHandler = { [weak self] started in
            AppLog.playback.notice("pip state change \(started, privacy: .public)")
            self?.onStateChange?(started)
        }
        lock.lock()
        windowController = window
        lock.unlock()
        // AVKit read the playback state when libVLC created the controller,
        // often while buffering. It does not ask again by itself, and
        // automatic PiP only starts for media it believes is playing.
        Task { @MainActor [weak self] in
            self?.invalidatePlaybackState()
        }
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
/// libVLC adds its own window view (`VLCVideoUIView`) as a subview of this
/// drawable and places the letterboxed picture inside it. That window view is
/// created when the video output opens, with the bounds this drawable had at
/// that moment, and is only added to the hierarchy later; its autoresizing mask
/// therefore cannot repair a resize in between, so this container stretches it
/// to its own bounds (see `didAddSubview(_:)` and `layoutSubviews()`). It also
/// carries the picture-in-picture selectors libVLC looks for.
///
/// It does not declare `VLCDrawable`: that protocol's `bounds` is a method,
/// which UIView's `bounds` property cannot witness in Swift. libVLC never
/// checks the conformance; it only sends `addSubview:` and `bounds`, which
/// every UIView answers.
@MainActor
final class PlayerDrawableView: UIView, PlayerPictureInPictureDrawable {
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

    /// Stretches libVLC's window view, which libVLC creates with the bounds
    /// this drawable had when the video output opened and only adds here later
    /// (the drawable is usually resized in between, e.g. from zero to the final
    /// size). Its autoresizing mask only follows deltas from the moment it
    /// becomes a subview, so the stale frame has to be replaced here.
    override func didAddSubview(_ subview: UIView) {
        super.didAddSubview(subview)
        stretch(subview)
    }

    /// Keeps libVLC's window view at the size of this drawable.
    ///
    /// libVLC's window view reports `bounds.size * contentScaleFactor` from its
    /// own layout to the video output, which computes the letterboxed place and
    /// frames its picture view from it. Stretching the window view to these
    /// bounds is therefore what makes the picture follow a fullscreen toggle, a
    /// window resize in Split View or Stage Manager, and a rotation; the picture
    /// stays where libVLC put it inside the window view. No sublayers are
    /// touched: the picture is a view, nested one level deeper.
    override func layoutSubviews() {
        super.layoutSubviews()
        for subview in subviews where subview.frame != bounds {
            stretch(subview)
        }
    }

    /// Fills these bounds with `subview` without animating the change, and asks
    /// it to lay its own contents out again at the new size.
    private func stretch(_ subview: UIView) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        subview.frame = bounds
        CATransaction.commit()
        subview.setNeedsLayout()
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
