import AVFoundation
import UIKit

/// Draws ARIB captions over the video.
///
/// It is added to the player host view above libVLC's video output, so captions
/// appear inline and in the picture-in-picture window's source alike. The
/// rendered images are plain `CGImage`s on `CALayer`s: the renderer already
/// produced the bitmap, so nothing is redrawn here.
@MainActor
final class CaptionOverlayUIView: UIView {
    private let controller: CaptionController
    /// Decoded video size in pixels (`VLCMediaPlayer.videoSize`).
    private let videoSize: @MainActor () -> CGSize

    private var captionLayers: [CALayer] = []
    private var displayLink: CADisplayLink?
    private var lastGeneration = -1
    private var lastVideoRect: CGRect = .zero

    init(controller: CaptionController, videoSize: @escaping @MainActor () -> CGSize) {
        self.controller = controller
        self.videoSize = videoSize
        super.init(frame: .zero)

        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        clipsToBounds = true
        isAccessibilityElement = false
        accessibilityElementsHidden = true

        let link = CADisplayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        update()
    }

    @objc private func step(_ link: CADisplayLink) {
        update()
    }

    // MARK: - Update

    private func update() {
        let hidden = !controller.isVisible || controller.isPictureInPictureActive
        if isHidden != hidden {
            isHidden = hidden
        }

        let rect = videoRect()
        if rect != lastVideoRect {
            lastVideoRect = rect
            let scale = max(traitCollection.displayScale, 1)
            controller.setRenderSize(
                CGSize(width: rect.width * scale, height: rect.height * scale)
            )
        }

        guard !hidden else {
            if !captionLayers.isEmpty {
                removeCaptionLayers()
            }
            lastGeneration = controller.framesGeneration
            return
        }

        if controller.framesGeneration != lastGeneration {
            lastGeneration = controller.framesGeneration
            drawFrames(in: rect)
        }
    }

    private func drawFrames(in videoRect: CGRect) {
        removeCaptionLayers()
        guard videoRect.width > 0, videoRect.height > 0 else { return }

        let renderSize = controller.renderSize
        let scaleX = renderSize.width > 0 ? renderSize.width / videoRect.width : 1
        let scaleY = renderSize.height > 0 ? renderSize.height / videoRect.height : 1
        let contentsScale = max(traitCollection.displayScale, 1)

        for frame in controller.frames {
            let layer = CALayer()
            layer.contents = frame.image
            layer.contentsScale = contentsScale
            layer.isOpaque = false
            layer.magnificationFilter = .linear
            let destination = frame.destinationRect
            layer.frame = CGRect(
                x: videoRect.minX + destination.minX / scaleX,
                y: videoRect.minY + destination.minY / scaleY,
                width: destination.width / scaleX,
                height: destination.height / scaleY
            )
            self.layer.addSublayer(layer)
            captionLayers.append(layer)
        }
    }

    private func removeCaptionLayers() {
        for layer in captionLayers {
            layer.removeFromSuperlayer()
        }
        captionLayers.removeAll(keepingCapacity: true)
    }

    // MARK: - Geometry

    /// Video rect in this overlay's coordinates.
    ///
    /// libVLC letterboxes the picture inside its drawable, so the video rect is
    /// the decoded size fitted into the overlay. Japanese broadcasts are 16:9;
    /// before libVLC has decoded the first frame the aspect ratio falls back to
    /// that shape.
    private func videoRect() -> CGRect {
        let container = bounds
        guard container.width > 1, container.height > 1 else { return .zero }

        var size = videoSize()
        if size.width < 1 || size.height < 1 || !size.width.isFinite || !size.height.isFinite {
            size = CGSize(width: 16, height: 9)
        }
        let rect = AVMakeRect(aspectRatio: size, insideRect: container)
        guard rect.width > 1, rect.height > 1 else { return .zero }
        return rect
    }
}
