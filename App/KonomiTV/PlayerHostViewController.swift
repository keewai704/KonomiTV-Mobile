import SwiftUI
import UIKit

/// The single long-lived player view controller of the app.
///
/// `PlaybackController` owns one instance and `PlayerRepresentable` returns that
/// instance instead of creating a new one, so the video output, the overlays
/// and libVLC's picture-in-picture window survive navigation and layout
/// changes.
///
/// Hierarchy: libVLC renders into `videoView` (it adds and positions its own
/// sample buffer layer there), the caption overlay sits directly above it and
/// the danmaku overlay on top of that. The transport controls are a SwiftUI
/// overlay in `PlayerView`.
@MainActor
final class PlayerHostViewController: UIViewController {
    /// The drawable libVLC renders into.
    let videoView = PlayerDrawableView()
    /// ARIB captions, above the video and below the comments.
    private(set) var captionOverlay: CaptionOverlayUIView!
    /// Niconico comments.
    private(set) var commentOverlay: CommentOverlayUIView!

    private let captions: CaptionController
    private let comments: CommentOverlayModel

    /// Decoded video size in pixels, updated from libVLC. The overlays use it
    /// to place captions and comments inside the letterboxed picture.
    var videoSize: CGSize = .zero {
        didSet {
            guard videoSize != oldValue else { return }
            captionOverlay?.setNeedsLayout()
        }
    }

    init(captions: CaptionController, comments: CommentOverlayModel) {
        self.captions = captions
        self.comments = comments
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = UIView()
        root.backgroundColor = .black
        // The UI tests wait for this identifier before reading player.state.
        root.accessibilityIdentifier = "player.view"
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        videoView.frame = view.bounds
        videoView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(videoView)

        let captionOverlay = CaptionOverlayUIView(controller: captions) { [weak self] in
            self?.videoSize ?? .zero
        }
        captionOverlay.frame = view.bounds
        captionOverlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(captionOverlay)
        self.captionOverlay = captionOverlay

        let commentOverlay = CommentOverlayUIView(model: comments)
        commentOverlay.frame = view.bounds
        commentOverlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(commentOverlay)
        self.commentOverlay = commentOverlay
    }

    // MARK: - Picture in picture

    var isPictureInPictureWindowAvailable: Bool {
        videoView.pipMedia.hasWindowController
    }

    func startPictureInPicture() {
        videoView.pipMedia.startPictureInPicture()
    }

    func stopPictureInPicture() {
        videoView.pipMedia.stopPictureInPicture()
    }

    func invalidatePictureInPictureState() {
        videoView.pipMedia.invalidatePlaybackState()
    }
}
