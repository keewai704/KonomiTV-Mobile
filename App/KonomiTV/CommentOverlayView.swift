import UIKit
import KonomiKit
import Observation

/// State shared by the comment sessions and the danmaku overlay.
///
/// The overlay renderer lives in `PlaybackController` so it survives switching
/// between the live player and the recorded video screen and stays attached to
/// the single `AVPlayerViewController`.
@MainActor
@Observable
final class CommentOverlayModel {
    /// Number of comments handed to the renderer since playback started. Also
    /// exposed to the UI tests through an invisible label in `RootView`.
    private(set) var drawnCount = 0
    /// Whether the overlay is drawn (web shortcut D / the toolbar button).
    private(set) var isVisible = true
    /// Bumped whenever the renderer has to drop everything on screen.
    private(set) var generation = 0

    /// Playback is advancing. Pausing freezes the comments in place.
    var isPlaying = false
    /// The overlay is not part of the picture in picture window.
    var isPictureInPictureActive = false

    private(set) var speedRate: Double = 1
    private(set) var baseFontSize: Double = 34

    @ObservationIgnored private var pending: [CommentDanmaku] = []

    /// Queues a comment for the renderer. Comments that arrive while the
    /// overlay is hidden are not drawn (DPlayer behaves the same way).
    func emit(_ danmaku: CommentDanmaku) {
        guard isVisible, !isPictureInPictureActive else { return }
        pending.append(danmaku)
    }

    func drainPending() -> [CommentDanmaku] {
        let drained = pending
        pending.removeAll(keepingCapacity: true)
        return drained
    }

    func markDrawn() {
        drawnCount += 1
    }

    /// Clears the comments on screen (seek, reconnect, fullscreen transition).
    func clear() {
        pending.removeAll()
        generation &+= 1
    }

    /// Starts a new playback: clears the screen and the test hook counter.
    func reset() {
        clear()
        drawnCount = 0
    }

    func toggleVisibility() {
        isVisible.toggle()
        if !isVisible {
            pending.removeAll()
            generation &+= 1
        }
    }

    func apply(settings: ClientSettings) {
        speedRate = min(max(settings.commentSpeedRate, 0.5), 2)
        baseFontSize = min(max(settings.commentFontSize, 20), 60)
    }
}

// MARK: - Renderer

/// Positions the danmaku. Plain class (not observable) so the 60 fps render
/// loop never invalidates SwiftUI views.
///
/// Each comment is rendered to an image once, when it appears, and shown by
/// its own CALayer; every frame only moves layers, which Core Animation
/// composites on the GPU. Redrawing the whole overlay with Core Graphics each
/// frame would cost CPU time proportional to the screen size.
@MainActor
final class CommentDanmakuEngine {
    private struct ActiveComment {
        let danmaku: CommentDanmaku
        let lane: Int
        let start: Double
        let duration: Double
        let width: CGFloat
        let itemHeight: CGFloat
        let layer: CALayer

        var end: Double { start + duration }
    }

    /// DPlayer's scroll duration (5 s inline, 5.5 s in fullscreen) divided by
    /// `commentSpeedRate`.
    private static let scrollDuration: Double = 5
    /// DPlayer's fixed comment duration (4 s inline, 4.5 s in fullscreen).
    private static let fixedDuration: Double = 4
    /// Room around the text for the outline and the own-comment border.
    private static let padding: CGFloat = 4

    private var active: [ActiveComment] = []
    /// Monotonic render clock in seconds. It stops while playback is paused so
    /// the comments freeze instead of jumping.
    private var now: Double = 0
    private var lastFrame: Double?

    var isPaused = false
    var isVisible = true
    var speedRate: Double = 1
    var baseFontSize: Double = 34

    var isEmpty: Bool { active.isEmpty }

    func clear() {
        for item in active {
            item.layer.removeFromSuperlayer()
        }
        active.removeAll()
        lastFrame = nil
    }

    /// Advances the clock; returns whether time moved.
    @discardableResult
    func advance(to frameTime: Double) -> Bool {
        defer { lastFrame = frameTime }
        guard let lastFrame else { return false }
        let delta = frameTime - lastFrame
        guard !isPaused, isVisible, delta > 0, delta < 1 else { return false }
        now += delta
        return true
    }

    func add(
        _ danmaku: CommentDanmaku,
        in hostLayer: CALayer,
        containerSize: CGSize,
        scale: CGFloat,
        didDraw: () -> Void
    ) {
        guard containerSize.width > 0, containerSize.height > 0 else { return }

        discardFinished()

        // DPlayer: 1.25 is a magic number, and the ratio never exceeds 1.
        let ratio = min(1, containerSize.width / 1024 * 1.25)
        let itemFontSize = baseFontSize * ratio
        let itemHeight = itemFontSize + 6 * ratio
        let laneCount = max(1, Int(containerSize.height / itemHeight))

        let fontSize: CGFloat
        switch danmaku.size {
        case .big: fontSize = itemFontSize * 1.25
        case .medium: fontSize = itemFontSize
        case .small: fontSize = itemFontSize * 0.8
        }

        let attributed = Self.attributed(danmaku.text, fontSize: fontSize, color: danmaku.color)
        let textSize = attributed.size()
        guard textSize.width > 0, textSize.height > 0 else { return }

        guard let lane = allocateLane(
            for: danmaku,
            width: textSize.width,
            laneCount: laneCount,
            containerWidth: containerSize.width
        ) else {
            // Every lane is busy; DPlayer drops the comment in this case too.
            return
        }

        let layer = Self.makeLayer(
            attributed: attributed,
            textSize: textSize,
            isOwnComment: danmaku.isOwnComment,
            scale: scale
        )
        hostLayer.addSublayer(layer)

        let duration = (danmaku.position == .scroll ? Self.scrollDuration : Self.fixedDuration)
            / max(speedRate, 0.1)
        active.append(
            ActiveComment(
                danmaku: danmaku,
                lane: lane,
                start: now,
                duration: duration,
                width: textSize.width,
                itemHeight: itemHeight,
                layer: layer
            )
        )
        didDraw()
    }

    /// Moves every layer to its position at the current clock.
    func layout(size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        discardFinished()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for item in active {
            let progress = min(max((now - item.start) / item.duration, 0), 1)
            let height = item.layer.bounds.height
            let laneTop = CGFloat(item.lane) * item.itemHeight + 8
            let center: CGPoint
            switch item.danmaku.position {
            case .scroll:
                let left = size.width - (size.width + item.width) * CGFloat(progress)
                center = CGPoint(
                    x: left + item.width / 2,
                    y: laneTop + max(item.itemHeight, height - Self.padding * 2) / 2
                )
            case .top:
                center = CGPoint(
                    x: size.width / 2,
                    y: laneTop + max(item.itemHeight, height - Self.padding * 2) / 2
                )
            case .bottom:
                center = CGPoint(
                    x: size.width / 2,
                    y: size.height - CGFloat(item.lane + 1) * item.itemHeight - 8
                        + max(item.itemHeight, height - Self.padding * 2) / 2
                )
            }
            item.layer.position = center
        }
        CATransaction.commit()
    }

    // MARK: - Lane allocation

    /// Copies DPlayer's tunnel search: a scrolling comment may reuse a lane
    /// once its last comment has moved far enough that the new (wider or
    /// narrower) comment cannot catch up; fixed comments need an empty lane.
    private func allocateLane(
        for danmaku: CommentDanmaku,
        width: CGFloat,
        laneCount: Int,
        containerWidth: CGFloat
    ) -> Int? {
        let sameType = active.filter { $0.danmaku.position == danmaku.position }
        for lane in 0..<laneCount {
            let items = sameType.filter { $0.lane == lane }
            if danmaku.position != .scroll {
                if items.isEmpty { return lane }
                continue
            }
            if items.allSatisfy({
                Self.isScrollLaneFree(
                    existing: $0,
                    newWidth: width,
                    containerWidth: containerWidth,
                    now: now
                )
            }) {
                return lane
            }
        }
        return nil
    }

    private static func isScrollLaneFree(
        existing: ActiveComment,
        newWidth: CGFloat,
        containerWidth: CGFloat,
        now: Double
    ) -> Bool {
        let progress = (now - existing.start) / existing.duration
        if progress >= 1 { return true }
        let rightDistance = (containerWidth + existing.width) * CGFloat(progress) - existing.width
        // How far the existing comment has moved by the time the new one has
        // crossed the screen (DPlayer's tmp * danSpeed(width)).
        let moved = containerWidth * (containerWidth + existing.width) / (containerWidth + newWidth)
        return rightDistance > containerWidth - moved && rightDistance > 0
    }

    private func discardFinished() {
        active.removeAll { item in
            guard item.end <= now else { return false }
            item.layer.removeFromSuperlayer()
            return true
        }
    }

    // MARK: - Text

    private static func makeLayer(
        attributed: NSAttributedString,
        textSize: CGSize,
        isOwnComment: Bool,
        scale: CGFloat
    ) -> CALayer {
        let size = CGSize(
            width: ceil(textSize.width) + padding * 2,
            height: ceil(textSize.height) + padding * 2
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            attributed.draw(at: CGPoint(x: padding, y: padding))
            if isOwnComment {
                let border = CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
                let path = UIBezierPath(roundedRect: border, cornerRadius: 4)
                UIColor.systemOrange.setStroke()
                path.lineWidth = 1.5
                path.stroke()
            }
        }

        let layer = CALayer()
        layer.contents = image.cgImage
        layer.contentsScale = scale
        layer.bounds = CGRect(origin: .zero, size: size)
        layer.opacity = 0.95
        return layer
    }

    private static func attributed(_ text: String, fontSize: CGFloat, color: String) -> NSAttributedString {
        let font = UIFont.systemFont(ofSize: fontSize, weight: .bold)
        return NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: UIColor(commentHex: color),
                // Negative width = fill + stroke, which is the thin dark
                // outline DPlayer draws with text-shadow.
                .strokeColor: UIColor.black.withAlphaComponent(0.9),
                .strokeWidth: -3,
            ]
        )
    }
}

// MARK: - Overlay view

/// Danmaku overlay.
///
/// It is added to `AVPlayerViewController.contentOverlayView` instead of being
/// stacked in SwiftUI: that view sits above the video both inline and in the
/// fullscreen presentation, so one renderer covers every player presentation.
/// A `CADisplayLink` moves the comment layers; it does no work while there is
/// nothing on screen or playback is paused.
@MainActor
final class CommentOverlayUIView: UIView {
    private let model: CommentOverlayModel
    private let engine = CommentDanmakuEngine()
    private var displayLink: CADisplayLink?
    private var generation = 0

    init(model: CommentOverlayModel) {
        self.model = model
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        clipsToBounds = true
        // The overlay is decoration, not content for VoiceOver.
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
        engine.layout(size: bounds.size)
    }

    @objc private func step(_ link: CADisplayLink) {
        if generation != model.generation {
            generation = model.generation
            engine.clear()
        }

        let pictureInPicture = model.isPictureInPictureActive
        let hidden = !model.isVisible || pictureInPicture
        if isHidden != hidden {
            isHidden = hidden
        }
        engine.isPaused = !model.isPlaying
        engine.isVisible = model.isVisible
        engine.speedRate = model.speedRate
        engine.baseFontSize = model.baseFontSize

        if hidden {
            if !engine.isEmpty {
                engine.clear()
            }
            _ = model.drainPending()
            return
        }

        let moved = engine.advance(to: link.timestamp)

        var added = false
        if bounds.width > 0, bounds.height > 0 {
            let pending = model.drainPending()
            for danmaku in pending {
                engine.add(
                    danmaku,
                    in: layer,
                    containerSize: bounds.size,
                    scale: max(traitCollection.displayScale, 1)
                ) { [model] in
                    model.markDrawn()
                }
                added = true
            }
        }

        if moved || added {
            engine.layout(size: bounds.size)
        }
    }
}

// MARK: - Colour parsing

extension UIColor {
    /// `#RRGGBB` (the format KonomiKit produces) to a colour.
    convenience init(commentHex: String) {
        var value = commentHex
        if value.hasPrefix("#") {
            value.removeFirst()
        }
        guard value.count == 6, let number = UInt32(value, radix: 16) else {
            self.init(white: 1, alpha: 1)
            return
        }
        self.init(
            red: CGFloat((number >> 16) & 0xFF) / 255,
            green: CGFloat((number >> 8) & 0xFF) / 255,
            blue: CGFloat(number & 0xFF) / 255,
            alpha: 1
        )
    }
}
