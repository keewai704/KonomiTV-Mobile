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
/// sample buffer layer there), the data broadcasting page sits above it, the
/// caption overlay above that and the danmaku overlay on top. The transport
/// controls are a SwiftUI overlay in `PlayerView`.
///
/// When the BML content places its video plane somewhere else than the full
/// screen, the video, the captions and the comments are laid out in that rect
/// instead (the page reports it through `DataBroadcastingController`).
@MainActor
final class PlayerHostViewController: UIViewController {
    /// The drawable libVLC renders into.
    let videoView = PlayerDrawableView()
    /// The data broadcasting (BML) page, transparent except for its content.
    private(set) var dataBroadcastingView: DataBroadcastingWebView!
    /// ARIB captions, above the video and below the comments.
    private(set) var captionOverlay: CaptionOverlayUIView!
    /// Niconico comments.
    private(set) var commentOverlay: CommentOverlayUIView!

    private let captions: CaptionController
    private let comments: CommentOverlayModel
    private let dataBroadcasting: DataBroadcastingController
    /// Rect of the BML video plane (nil = full screen).
    private var videoPlaneRect: CGRect?

    /// Decoded video size in pixels, updated from libVLC. The overlays use it
    /// to place captions and comments inside the letterboxed picture.
    var videoSize: CGSize = .zero {
        didSet {
            guard videoSize != oldValue else { return }
            captionOverlay?.setNeedsLayout()
        }
    }

    init(
        captions: CaptionController,
        comments: CommentOverlayModel,
        dataBroadcasting: DataBroadcastingController
    ) {
        self.captions = captions
        self.comments = comments
        self.dataBroadcasting = dataBroadcasting
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

        // The frames are managed by applyVideoPlaneLayout() (the BML page may
        // move the video into its own video plane), so no autoresizing masks.
        videoView.frame = view.bounds
        view.addSubview(videoView)

        let dataBroadcastingView = DataBroadcastingWebView(controller: dataBroadcasting)
        dataBroadcastingView.frame = view.bounds
        view.addSubview(dataBroadcastingView)
        self.dataBroadcastingView = dataBroadcastingView
        dataBroadcasting.attach(page: dataBroadcastingView)
        dataBroadcasting.onVideoPlaneChanged = { [weak self] rect in
            self?.setVideoPlaneRect(rect)
        }

        let captionOverlay = CaptionOverlayUIView(controller: captions) { [weak self] in
            self?.videoSize ?? .zero
        }
        captionOverlay.frame = view.bounds
        view.addSubview(captionOverlay)
        self.captionOverlay = captionOverlay

        let commentOverlay = CommentOverlayUIView(model: comments)
        commentOverlay.frame = view.bounds
        view.addSubview(commentOverlay)
        self.commentOverlay = commentOverlay
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        applyVideoPlaneLayout()
        dataBroadcasting.pageSizeChanged(to: view.bounds.size)
    }

    // MARK: - Video plane

    /// The BML content moved its video plane (nil = the video fills the view).
    func setVideoPlaneRect(_ rect: CGRect?) {
        videoPlaneRect = rect
        applyVideoPlaneLayout()
    }

    private func applyVideoPlaneLayout() {
        let bounds = view.bounds
        var target = bounds
        if let videoPlaneRect {
            let rect = videoPlaneRect.intersection(bounds)
            if rect.width >= 1, rect.height >= 1 {
                target = rect
            }
        }
        let subviews: [UIView?] = [videoView, captionOverlay, commentOverlay]
        for subview in subviews {
            guard let subview, subview.frame != target else { continue }
            subview.frame = target
        }
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
