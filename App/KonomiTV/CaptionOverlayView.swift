import AVKit
import UIKit

/// Draws ARIB captions over the video.
///
/// It is added to `AVPlayerViewController.contentOverlayView` below the
/// comment overlay, so captions appear inline and in fullscreen alike. The
/// rendered images are plain `CGImage`s on `CALayer`s: the renderer already
/// produced the bitmap, so nothing is redrawn here.
@MainActor
final class CaptionOverlayUIView: UIView {
    private let controller: CaptionController
    private weak var playerViewController: AVPlayerViewController?

    private var captionLayers: [CALayer] = []
    private var displayLink: CADisplayLink?
    private var lastGeneration = -1
    private var lastVideoRect: CGRect = .zero

    init(controller: CaptionController, playerViewController: AVPlayerViewController) {
        self.controller = controller
        self.playerViewController = playerViewController
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
    /// `AVPlayerViewController.videoBounds` accounts for the actual video
    /// gravity and letterboxing; before it is available the overlay falls back
    /// to an aspect-fit 16:9 rect, which is the shape of Japanese broadcasts.
    private func videoRect() -> CGRect {
        if let controller = playerViewController,
           let bounds = Self.videoBounds(of: controller) {
            let converted = convert(bounds, from: controller.view)
            if converted.width > 1, converted.height > 1 {
                return converted
            }
        }

        let container = bounds
        guard container.width > 0, container.height > 0 else { return .zero }
        let aspect: CGFloat = 16.0 / 9.0
        var size = CGSize(width: container.width, height: container.width / aspect)
        if size.height > container.height {
            size = CGSize(width: container.height * aspect, height: container.height)
        }
        return CGRect(
            x: (container.width - size.width) / 2,
            y: (container.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    /// `AVPlayerViewController.videoBounds` is the video rect the player
    /// currently shows. It is read through KVC so the overlay still builds
    /// against SDKs that do not expose it; nil means "use aspect fit".
    private static func videoBounds(of controller: AVPlayerViewController) -> CGRect? {
        let selector = NSSelectorFromString("videoBounds")
        guard controller.responds(to: selector),
              let value = controller.value(forKey: "videoBounds") as? NSValue else {
            return nil
        }
        let bounds = value.cgRectValue
        guard bounds.width > 1, bounds.height > 1 else { return nil }
        return bounds
    }
}
