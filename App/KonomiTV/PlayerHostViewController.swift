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
        // The picture is 16:9 in the middle of the view: the view is larger
        // than the picture in fullscreen (the whole screen), and comments and
        // captions belong on the picture, not on the black bars.
        var target = Self.pictureRect(in: bounds)
        if let videoPlaneRect {
            let rect = videoPlaneRect.intersection(bounds)
            if rect.width >= 1, rect.height >= 1 {
                target = rect
            }
        }
        if videoView.frame != target {
            if videoView.frame.size != target.size {
                // The drawable stretches libVLC's window view to the new size
                // in its own layout pass (and libVLC then re-places the picture
                // inside it); ask for that pass now, so the picture never keeps
                // the size of the previous window.
                videoView.setNeedsLayout()
            }
            videoView.frame = target
        }
        // Both overlays lay themselves out from their bounds (captions and
        // danmaku follow the letterboxed picture).
        let overlays: [UIView?] = [captionOverlay, commentOverlay]
        for overlay in overlays {
            guard let overlay, overlay.frame != target else { continue }
            overlay.frame = target
        }
    }

    /// The largest 16:9 rect centered in bounds.
    static func pictureRect(in bounds: CGRect) -> CGRect {
        guard bounds.width > 0, bounds.height > 0 else { return bounds }
        let ratio: CGFloat = 16.0 / 9.0
        var size = CGSize(width: bounds.width, height: bounds.width / ratio)
        if size.height > bounds.height {
            size = CGSize(width: bounds.height * ratio, height: bounds.height)
        }
        return CGRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        ).integral
    }

    // MARK: - Video output

    /// Size of libVLC's picture view, next to the size of the drawable it is
    /// drawn into ("1280x720/1280x720"; "-" before libVLC added its views).
    ///
    /// `PlayerDrawableView` keeps libVLC's window view at its own size, so the
    /// drawable's subview is always the drawable and says nothing about the
    /// picture. The picture is the view libVLC frames inside that window view,
    /// one level further down, and it is letterboxed there. The layout UI test
    /// reads this through `playback.videoOutput` and asserts that a window
    /// resize (rotation, Split View, Stage Manager, fullscreen) resizes the
    /// picture with the player.
    var videoOutputDescription: String {
        let picture = videoView.subviews
            .flatMap(\.subviews)
            .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
        guard let picture else { return "-" }
        let frame = picture.convert(picture.bounds, to: videoView)
        let drawable = videoView.bounds.size
        return "\(Int(frame.width.rounded()))x\(Int(frame.height.rounded()))"
            + "/\(Int(drawable.width.rounded()))x\(Int(drawable.height.rounded()))"
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
