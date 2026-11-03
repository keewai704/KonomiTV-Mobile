import AVFoundation
import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import KonomiKit
import Observation
import Photos
import UIKit
import UniformTypeIdentifiers

/// One encoded capture image, ready to be saved.
struct ProducedCapture: Sendable {
    let filename: String
    let data: Data
}

/// Failure of saving a capture to the photo library.
private enum CaptureSaveError: Error {
    case photoLibraryUnavailable
}

/// Everything the composition of one capture needs. The images are immutable
/// once created, so handing them to a background task is safe.
private struct CaptureInputs: @unchecked Sendable {
    let frame: CGImage
    let planes: [CaptionCompositePlane]
    let planeSpace: CGSize
    let commentImage: CGImage?
    let producesVideoOnly: Bool
    let producesCaption: Bool
    let metadata: CaptureExifMetadata
    let capturedAt: Date
    let software: String
    let baseName: String
}

/// Captures the video frame of the app wide player and turns it into a JPEG
/// with the web client's EXIF metadata, optionally burning in the ARIB caption
/// and the comment overlay (CaptureManager.ts + CaptureCompositor.ts).
///
/// Owned by `PlaybackController` next to `captions` and `comments`, because the
/// frame comes from the shared AVPlayer and the overlays live on the player's
/// content overlay view.
@MainActor
@Observable
final class CaptureController {
    /// Transient message shown over the player ("capture.notice").
    private(set) var notice: String?
    /// Number of images produced since launch (read by the UI tests).
    private(set) var producedImageCount = 0
    /// Filename of the last produced image (read by the UI tests).
    private(set) var lastFilename: String?
    /// Images produced since launch, newest last. The Twitter panel shows them
    /// as attachments; the oldest are dropped beyond the panel's limit.
    private(set) var sessionCaptures: [ProducedCapture] = []
    /// A capture is being composited or saved.
    private(set) var isCapturing = false

    /// The player this controller captures from. Set by PlaybackController.
    @ObservationIgnored weak var playback: PlaybackController?

    @ObservationIgnored private var output: AVPlayerItemVideoOutput?
    @ObservationIgnored private weak var outputItem: AVPlayerItem?
    @ObservationIgnored private let ciContext = CIContext()
    @ObservationIgnored private var noticeTask: Task<Void, Never>?

    // MARK: - Video output

    /// Attaches a BGRA video output to the item the player is about to show.
    /// Anamorphic streams (1440x1080 with a 16:9 display aspect) keep their
    /// pixel size here; the capture is scaled to the item's presentation size.
    func attach(to item: AVPlayerItem) {
        detach()
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        item.add(output)
        self.output = output
        outputItem = item
    }

    /// Removes the video output from the current item (item replaced, playback
    /// stopped).
    func detach() {
        if let outputItem, let output {
            outputItem.remove(output)
        }
        output = nil
        outputItem = nil
    }

    // MARK: - Capture

    /// Captures the current frame.
    ///
    /// - Parameter includeComments: composite the comment overlay into every
    ///   produced image (the web client's "コメント付きでキャプチャ").
    func capture(includeComments: Bool, settings: ClientSettings) {
        guard let playback, let playbackItem = playback.item else { return }

        // A radio channel has no video, so there is nothing to capture.
        if case .live(let channel) = playbackItem, channel.isRadioChannel {
            showNotice("ラジオチャンネルはキャプチャできません。")
            return
        }

        guard !isCapturing else { return }

        let capturedAt = Date()
        guard let frame = grabFrame() else {
            showNotice("読み込み中はキャプチャできません。")
            return
        }

        if includeComments, !playback.comments.isVisible {
            showNotice("コメントを付けてキャプチャするには、コメント表示をオンにしてください。")
            return
        }

        // Everything below must be read on the main actor before the
        // composition moves to a background task.
        let size = captureSize(for: frame)
        guard let scaledFrame = Self.scaled(frame, to: size) else {
            showNotice("キャプチャを保存できませんでした。")
            return
        }

        let captionPlanes = playback.captions.compositePlanes()
        let captionText = captionPlanes.isEmpty ? nil : playback.captions.captionText
        let commentImage = includeComments ? renderCommentOverlay(size: size) : nil
        if includeComments, commentImage == nil {
            showNotice("コメントを付けてキャプチャするには、コメント表示をオンにしてください。")
            return
        }

        let metadata = Self.metadata(
            for: playbackItem,
            position: playback.capturePosition,
            capturedAt: capturedAt,
            captionText: captionText
        )
        let baseName = CaptureFilename.make(
            pattern: settings.captureFilenamePattern,
            context: Self.filenameContext(for: playbackItem, capturedAt: capturedAt)
        )
        let software = JPEGExif.softwareName(version: CaptureController.appVersion)

        let inputs = CaptureInputs(
            frame: scaledFrame,
            planes: captionPlanes,
            planeSpace: playback.captions.renderSize,
            commentImage: commentImage,
            producesVideoOnly: settings.captureCaptionMode.producesVideoOnly,
            producesCaption: settings.captureCaptionMode.producesCaptionComposite,
            metadata: metadata,
            capturedAt: capturedAt,
            software: software,
            baseName: baseName
        )

        isCapturing = true
        let client = playback.captureClient
        let saveMode = settings.captureSaveMode
        let copyToClipboard = settings.captureCopyToClipboard

        Task { [weak self] in
            let images = await Task.detached(priority: .userInitiated) {
                Self.render(inputs)
            }.value
            guard let self else { return }
            self.isCapturing = false

            guard !images.isEmpty else {
                self.showNotice("キャプチャを保存できませんでした。")
                return
            }
            self.producedImageCount += images.count
            self.lastFilename = images.last?.filename
            self.rememberSessionCaptures(images)
            self.save(images, saveMode: saveMode, client: client, copyToClipboard: copyToClipboard)
        }
    }

    // MARK: - Session captures

    /// Keeps the latest captures for the Twitter panel's attachment grid.
    private func rememberSessionCaptures(_ images: [ProducedCapture]) {
        sessionCaptures.append(contentsOf: images)
        let limit = 100
        if sessionCaptures.count > limit {
            sessionCaptures.removeFirst(sessionCaptures.count - limit)
        }
    }

    /// Draws the program title onto a capture (tweet_capture_watermark_position).
    ///
    /// Text and shadow follow the web client's drawProgramTitleOnCapture:
    /// semi-transparent bold white with a black glow, 16 px from the edges.
    static func watermarked(
        _ data: Data,
        title: String,
        position: TweetCaptureWatermarkPosition
    ) -> Data? {
        guard position != .none, !title.isEmpty, let image = UIImage(data: data) else {
            return nil
        }
        let size = image.size
        guard size.width >= 1, size.height >= 1 else { return nil }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true

        let output = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))

            // The web client uses 22 px on a full-size screenshot; scale with
            // the image so the watermark keeps its relative size.
            let fontSize = max(22 * size.width / 1920, 12)
            let shadow = NSShadow()
            shadow.shadowColor = UIColor.black
            shadow.shadowBlurRadius = 4
            shadow.shadowOffset = .zero
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: fontSize, weight: .bold),
                .foregroundColor: UIColor.white.withAlphaComponent(0.7),
                .shadow: shadow,
            ]

            let text = title as NSString
            let textSize = text.size(withAttributes: attributes)
            let margin: CGFloat = 16
            let origin: CGPoint
            switch position {
            case .none:
                origin = .zero
            case .topLeft:
                origin = CGPoint(x: margin, y: margin / 2)
            case .topRight:
                origin = CGPoint(x: size.width - margin - textSize.width, y: margin / 2)
            case .bottomLeft:
                origin = CGPoint(x: margin, y: size.height - textSize.height - margin / 2)
            case .bottomRight:
                origin = CGPoint(
                    x: size.width - margin - textSize.width,
                    y: size.height - textSize.height - margin / 2
                )
            }
            text.draw(at: origin, withAttributes: attributes)
        }
        return output.jpegData(compressionQuality: 1)
    }

    /// Reads the current frame of the shared player, in the renderer's pixel
    /// space. nil before the first frame has been decoded.
    private func grabFrame() -> CGImage? {
        guard let output, let item = playback?.capturePlayer?.currentItem else { return nil }

        var pixelBuffer = output.copyPixelBuffer(
            forItemTime: output.itemTime(forHostTime: CACurrentMediaTime()),
            itemTimeForDisplay: nil
        )
        if pixelBuffer == nil {
            let time = item.currentTime()
            if time.isValid, item.status == .readyToPlay {
                pixelBuffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil)
            }
        }
        guard let buffer = pixelBuffer else { return nil }

        let image = CIImage(cvPixelBuffer: buffer)
        guard image.extent.width >= 1, image.extent.height >= 1 else { return nil }
        return ciContext.createCGImage(image, from: image.extent)
    }

    /// The size the capture is written at: the item's presentation size, so an
    /// anamorphic 1440x1080 frame becomes 1920x1080.
    private func captureSize(for frame: CGImage) -> CGSize {
        let presentationSize = playback?.capturePlayer?.currentItem?.presentationSize ?? .zero
        if presentationSize.width >= 1, presentationSize.height >= 1,
           presentationSize.width.isFinite, presentationSize.height.isFinite {
            return presentationSize
        }
        return CGSize(width: frame.width, height: frame.height)
    }

    /// Renders the danmaku overlay's layer tree at the capture's size.
    ///
    /// The overlay spans the whole player, letterbox included, so only the
    /// part over the video (aspect fit of the capture size) is mapped onto the
    /// image, with one uniform scale.
    private func renderCommentOverlay(size: CGSize) -> CGImage? {
        guard let overlay = playback?.commentOverlay,
              overlay.bounds.width >= 1, overlay.bounds.height >= 1 else {
            return nil
        }
        let videoRect = AVMakeRect(aspectRatio: size, insideRect: overlay.bounds)
        guard videoRect.width >= 1, videoRect.height >= 1 else { return nil }
        let scale = size.width / videoRect.width

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            context.cgContext.scaleBy(x: scale, y: scale)
            context.cgContext.translateBy(x: -videoRect.minX, y: -videoRect.minY)
            overlay.layer.render(in: context.cgContext)
        }
        return image.cgImage
    }

    // MARK: - Saving

    private func save(
        _ images: [ProducedCapture],
        saveMode: CaptureSaveMode,
        client: APIClient?,
        copyToClipboard: Bool
    ) {
        // The video-only image is always saved first (that is the array order).
        showNotice("キャプチャを保存しました")

        if saveMode.uploadsToServer, let client {
            for image in images {
                Task { [weak self] in
                    do {
                        _ = try await client.uploadCapture(image: image.data, filename: image.filename)
                    } catch {
                        self?.showNotice("サーバーにキャプチャをアップロードできませんでした。")
                    }
                }
            }
        }

        if saveMode.savesToDevice {
            Task { [weak self] in
                for image in images {
                    do {
                        try await Self.saveToPhotos(image.data)
                    } catch {
                        self?.showNotice("写真にキャプチャを保存できませんでした。")
                        break
                    }
                }
            }
        }

        if copyToClipboard, let last = images.last, let image = UIImage(data: last.data) {
            UIPasteboard.general.image = image
        }
    }

    /// Saves the original bytes to the photo library (add only permission).
    nonisolated private static func saveToPhotos(_ data: Data) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw CaptureSaveError.photoLibraryUnavailable
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: data, options: nil)
            } completionHandler: { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: error ?? CaptureSaveError.photoLibraryUnavailable)
                }
            }
        }
    }

    // MARK: - Version

    /// MARKETING_VERSION of the app bundle, written as the EXIF Software tag.
    nonisolated private static var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? ""
    }

    // MARK: - Notice

    private func showNotice(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    // MARK: - Metadata

    private static func metadata(
        for item: PlaybackItem,
        position: Double,
        capturedAt: Date,
        captionText: String?
    ) -> CaptureExifMetadata {
        switch item {
        case .live(let channel):
            return CaptureExifMetadata.live(
                channel: channel,
                program: channel.programPresent,
                capturedAt: capturedAt,
                captionText: captionText
            )
        case .video(let video):
            return CaptureExifMetadata.video(
                program: video,
                position: position,
                capturedAt: capturedAt,
                captionText: captionText
            )
        }
    }

    private static func filenameContext(
        for item: PlaybackItem,
        capturedAt: Date
    ) -> CaptureFilenameContext {
        switch item {
        case .live(let channel):
            let program = channel.programPresent
            return CaptureFilenameContext(
                capturedAt: capturedAt,
                channelName: channel.name,
                serviceID: channel.serviceID,
                remoconID: channel.remoconID,
                eventID: program?.eventID ?? -1,
                eventTitle: program?.title ?? "",
                eventStartTime: program?.startTime ?? capturedAt,
                eventEndTime: program?.endTime
            )
        case .video(let video):
            return CaptureFilenameContext(
                capturedAt: capturedAt,
                channelName: video.channel?.name ?? "不明なチャンネル",
                serviceID: video.channel?.serviceID ?? 0,
                remoconID: video.channel?.remoconID ?? 0,
                eventID: video.eventID ?? -1,
                eventTitle: video.title,
                eventStartTime: video.startTime,
                eventEndTime: video.endTime
            )
        }
    }

    // MARK: - Composition (off the main actor)

    /// Composites and encodes the images of one capture: the video-only image
    /// first, then the caption composite when the caption is on screen.
    nonisolated private static func render(_ inputs: CaptureInputs) -> [ProducedCapture] {
        let hasCaption = producesCaptionPlanes(inputs)
        let needsVideoOnly = inputs.producesVideoOnly || !hasCaption

        var results: [ProducedCapture] = []

        if needsVideoOnly,
           let image = compose(
               frame: inputs.frame,
               planes: [],
               planeSpace: inputs.planeSpace,
               commentImage: inputs.commentImage
           ),
           let data = encode(
               image,
               metadata: inputs.metadata,
               capturedAt: inputs.capturedAt,
               software: inputs.software,
               isCaptionComposited: false,
               isCommentComposited: inputs.commentImage != nil
           ) {
            results.append(ProducedCapture(filename: inputs.baseName + ".jpg", data: data))
        }

        if hasCaption,
           let image = compose(
               frame: inputs.frame,
               planes: inputs.planes,
               planeSpace: inputs.planeSpace,
               commentImage: inputs.commentImage
           ),
           let data = encode(
               image,
               metadata: inputs.metadata,
               capturedAt: inputs.capturedAt,
               software: inputs.software,
               isCaptionComposited: true,
               isCommentComposited: inputs.commentImage != nil
           ) {
            results.append(
                ProducedCapture(filename: inputs.baseName + "_caption.jpg", data: data)
            )
        }

        return results
    }

    nonisolated private static func producesCaptionPlanes(_ inputs: CaptureInputs) -> Bool {
        inputs.producesCaption && !inputs.planes.isEmpty
    }

    /// Draws the video frame, the caption planes and the comment image into one
    /// bitmap of the frame's size.
    nonisolated private static func compose(
        frame: CGImage,
        planes: [CaptionCompositePlane],
        planeSpace: CGSize,
        commentImage: CGImage?
    ) -> CGImage? {
        let width = frame.width
        let height = frame.height
        guard width >= 1, height >= 1,
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else {
            return nil
        }

        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.interpolationQuality = .high
        context.draw(frame, in: bounds)

        // Caption planes are positioned in the renderer's top-left origin
        // space; the bitmap context uses the bottom-left origin.
        let scale = planeSpace.width >= 1 ? CGFloat(width) / planeSpace.width : 1
        for plane in planes {
            let rect = plane.rect
            guard rect.width > 0, rect.height > 0 else { continue }
            let target = CGRect(
                x: rect.minX * scale,
                y: CGFloat(height) - rect.maxY * scale,
                width: rect.width * scale,
                height: rect.height * scale
            )
            context.draw(plane.image, in: target)
        }

        if let commentImage {
            context.draw(commentImage, in: bounds)
        }

        return context.makeImage()
    }

    /// JPEG encodes at quality 0.99 (like the web client) and splices the EXIF
    /// segment in.
    nonisolated private static func encode(
        _ image: CGImage,
        metadata: CaptureExifMetadata,
        capturedAt: Date,
        software: String,
        isCaptionComposited: Bool,
        isCommentComposited: Bool
    ) -> Data? {
        var imageMetadata = metadata
        imageMetadata.isCaptionComposited = isCaptionComposited
        imageMetadata.isCommentComposited = isCommentComposited

        guard let jpeg = jpegData(image) else { return nil }
        let segment = JPEGExif.segment(
            metadata: imageMetadata,
            capturedAt: capturedAt,
            software: software
        )
        return (try? JPEGExif.insert(segment, into: jpeg)) ?? jpeg
    }

    nonisolated private static func jpegData(
        _ image: CGImage,
        quality: Double = 0.99
    ) -> Data? {
        guard let mutableData = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(
                  mutableData,
                  UTType.jpeg.identifier as CFString,
                  1,
                  nil
              ) else {
            return nil
        }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality as String: quality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return mutableData as Data
    }

    nonisolated private static func scaled(_ image: CGImage, to size: CGSize) -> CGImage? {
        let width = Int(size.width.rounded())
        let height = Int(size.height.rounded())
        guard width >= 1, height >= 1 else { return nil }
        if width == image.width, height == image.height {
            return image
        }
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
