#if canImport(CoreText)
import Foundation
import CoreGraphics
import CAribCaption

/// One rendered caption image and where it belongs in the video frame.
public struct ARIBCaptionImage {
    /// RGBA bitmap produced by libaribcaption.
    public let cgImage: CGImage
    /// Destination in the renderer frame's coordinate space (origin top-left,
    /// y increasing downwards, matching the C API's dst_x / dst_y).
    public let destinationRect: CGRect
    /// PTS the images were rendered for, in milliseconds.
    public let ptsMilliseconds: Int64
}

/// Renders decoded captions into RGBA images using libaribcaption's CoreText
/// backend.
///
/// The renderer keeps appended captions internally so a caption stays visible
/// until the next one. It is not thread-safe: keep one instance per stream and
/// only touch it from one thread at a time.
public final class ARIBCaptionRenderer {
    private let context: OpaquePointer
    private let renderer: OpaquePointer

    public let kind: ARIBCaptionKind
    /// Opacity applied to the alpha channel of every produced image (0...1).
    public var opacity: Float {
        didSet { opacity = min(max(opacity, 0), 1) }
    }

    /// - Parameters:
    ///   - frameSize: Video frame size in pixels, e.g. 1920x1080.
    ///   - type: `.caption` for 字幕, `.superimpose` for 文字スーパー.
    ///   - fontFamilies: Optional font family fallback list.
    ///   - forceDefaultFont: Use `fontFamilies` for every language, not only
    ///     when the caption language is unknown.
    ///   - alwaysBorderText: Always draw a stroke around the text.
    ///   - strokeWidth: Stroke width in dots (relative, 0 = none).
    ///   - replacesDRCS: Replace DRCS characters with their Unicode
    ///     alternative when one exists.
    ///   - opacity: Alpha multiplier applied to the rendered bitmap.
    public init(
        frameSize: CGSize,
        type: ARIBCaptionKind = .caption,
        fontFamilies: [String]? = nil,
        forceDefaultFont: Bool = false,
        alwaysBorderText: Bool = true,
        strokeWidth: Float = 1.0,
        replacesDRCS: Bool = true,
        opacity: Float = 1.0
    ) throws {
        guard let context = aribcc_context_alloc() else {
            throw ARIBCaptionError.contextUnavailable
        }
        guard let renderer = aribcc_renderer_alloc(context) else {
            aribcc_context_free(context)
            throw ARIBCaptionError.allocationFailed
        }
        guard aribcc_renderer_initialize(
            renderer,
            type.cValue,
            ARIBCC_FONTPROVIDER_TYPE_CORETEXT,
            ARIBCC_TEXTRENDERER_TYPE_CORETEXT
        ) else {
            aribcc_renderer_free(renderer)
            aribcc_context_free(context)
            throw ARIBCaptionError.initializationFailed
        }
        self.context = context
        self.renderer = renderer
        self.kind = type
        self.opacity = min(max(opacity, 0), 1)

        aribcc_renderer_set_force_stroke_text(renderer, alwaysBorderText)
        aribcc_renderer_set_stroke_width(renderer, max(strokeWidth, 0))
        aribcc_renderer_set_replace_drcs(renderer, replacesDRCS)
        _ = aribcc_renderer_set_frame_size(
            renderer,
            Int32(frameSize.width.rounded()),
            Int32(frameSize.height.rounded())
        )
        _ = aribcc_renderer_set_margins(renderer, 0, 0, 0, 0)

        if let fontFamilies, !fontFamilies.isEmpty {
            let cStrings: [UnsafeMutablePointer<CChar>?] = fontFamilies.map { strdup($0) }
            defer { cStrings.forEach { free($0) } }
            // The C API takes `const char * const *`.
            let constStrings: [UnsafePointer<CChar>?] = cStrings.map { $0.map { UnsafePointer($0) } }
            constStrings.withUnsafeBufferPointer { buffer in
                let pointers = buffer.baseAddress
                _ = aribcc_renderer_set_default_font_family(
                    renderer,
                    pointers,
                    fontFamilies.count,
                    forceDefaultFont
                )
            }
        }
    }

    deinit {
        aribcc_renderer_free(renderer)
        aribcc_context_free(context)
    }

    /// Adds a decoded caption to the renderer's internal storage.
    @discardableResult
    public func append(_ caption: ARIBCaption) -> Bool {
        var raw = caption.rawCaption
        return withUnsafePointer(to: &raw) { pointer in
            aribcc_renderer_append_caption(renderer, pointer)
        }
    }

    /// Renders the captions active at `pts` (milliseconds).
    ///
    /// Returns an empty array when no caption is visible at that timestamp.
    /// Images are in RGBA order with straight (non-premultiplied) alpha.
    public func render(ptsMilliseconds: Int64) -> [ARIBCaptionImage] {
        var result = aribcc_render_result_t()
        let status = aribcc_renderer_render(renderer, ptsMilliseconds, &result)
        guard status == ARIBCC_RENDER_STATUS_GOT_IMAGE
            || status == ARIBCC_RENDER_STATUS_GOT_IMAGE_UNCHANGED
        else {
            return []
        }
        defer { aribcc_render_result_cleanup(&result) }

        guard let images = result.images else { return [] }
        var output: [ARIBCaptionImage] = []
        output.reserveCapacity(Int(result.image_count))
        for index in 0..<Int(result.image_count) {
            let image = images[index]
            guard let cgImage = makeCGImage(from: image) else { continue }
            output.append(ARIBCaptionImage(
                cgImage: cgImage,
                destinationRect: CGRect(
                    x: Int(image.dst_x),
                    y: Int(image.dst_y),
                    width: Int(image.width),
                    height: Int(image.height)
                ),
                ptsMilliseconds: result.pts
            ))
        }
        return output
    }

    /// Renders the captions active at a 90 kHz PTS.
    public func render(pts: Int64) -> [ARIBCaptionImage] {
        render(ptsMilliseconds: pts / 90)
    }

    /// Renders the captions active at a 90 kHz PTS.
    public func render(ptsTicks: Int64) -> [ARIBCaptionImage] {
        render(ptsMilliseconds: ptsTicks / 90)
    }

    /// Drops every appended caption. Call after a seek / discontinuity.
    public func clear() {
        aribcc_renderer_flush(renderer)
    }

    private func makeCGImage(from image: aribcc_image_t) -> CGImage? {
        guard image.width > 0, image.height > 0,
              let bitmap = image.bitmap,
              image.bitmap_size > 0,
              Int(image.bitmap_size) >= Int(image.stride) * Int(image.height)
        else { return nil }

        var pixels = Data(bytes: bitmap, count: Int(image.bitmap_size))
        if opacity < 1 {
            let factor = Double(opacity)
            pixels.withUnsafeMutableBytes { buffer in
                guard let base = buffer.bindMemory(to: UInt8.self).baseAddress else { return }
                let count = buffer.count
                var index = 3
                while index < count {
                    base[index] = UInt8((Double(base[index]) * factor).rounded())
                    index += 4
                }
            }
        }

        guard let provider = CGDataProvider(data: pixels as CFData) else {
            return nil
        }
        return CGImage(
            width: Int(image.width),
            height: Int(image.height),
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: Int(image.stride),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}
#endif
