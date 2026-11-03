import CoreGraphics
import Foundation
import Observation
import KonomiStreaming
import ARIBCaption

/// Font choices offered by the iOS client. The rendered fallback list maps
/// onto the Hiragino families that ship with iOS; the web client's font list
/// (Windows TV ゴシック etc.) is not available here.
enum CaptionFont: String, CaseIterable, Identifiable, Sendable {
    case hiraginoMaruGothic = "hiragino_maru_gothic"
    case hiraginoSans = "hiragino_sans"
    case system = "system"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hiraginoMaruGothic: return "ヒラギノ丸ゴシック (Hiragino Maru Gothic ProN)"
        case .hiraginoSans: return "ヒラギノ角ゴシック (Hiragino Sans)"
        case .system: return "システムフォント"
        }
    }

    /// Font family fallback list handed to libaribcaption. Nil lets the
    /// renderer pick its own default.
    var fontFamilies: [String]? {
        switch self {
        case .hiraginoMaruGothic: return ["Hiragino Maru Gothic ProN"]
        case .hiraginoSans: return ["Hiragino Sans"]
        case .system: return nil
        }
    }
}

/// Local-only caption settings, stored under the web client's key names.
struct CaptionPreferences: Sendable, Equatable {
    enum PlaybackMode: Sendable, Equatable {
        case live
        case video
    }

    var font: CaptionFont = .hiraginoMaruGothic
    var alwaysBorderText = true
    var specifyCaptionOpacity = false
    var captionOpacity = 0.5
    var showSuperimpose = false

    /// Alpha multiplier for the renderer. When "字幕の不透明度を指定する" is off,
    /// the opacity embedded in the caption data is used (i.e. no override).
    var opacity: Float {
        guard specifyCaptionOpacity else { return 1 }
        return Float(min(max(captionOpacity, 0), 1))
    }

    static func load(
        from defaults: UserDefaults = .standard,
        mode: PlaybackMode
    ) -> CaptionPreferences {
        var preferences = CaptionPreferences()
        if let raw = defaults.string(forKey: PreferenceKeys.captionFont) {
            preferences.font = CaptionFont(rawValue: raw) ?? .hiraginoMaruGothic
        }
        preferences.alwaysBorderText = bool(
            defaults,
            PreferenceKeys.alwaysBorderCaptionText,
            fallback: true
        )
        preferences.specifyCaptionOpacity = bool(
            defaults,
            PreferenceKeys.specifyCaptionOpacity,
            fallback: false
        )
        preferences.captionOpacity = double(
            defaults,
            PreferenceKeys.captionOpacity,
            fallback: 0.5
        )
        preferences.showSuperimpose = mode == .live
            ? bool(defaults, PreferenceKeys.tvShowSuperimpose, fallback: true)
            : bool(defaults, PreferenceKeys.videoShowSuperimpose, fallback: false)
        return preferences
    }

    private static func bool(
        _ defaults: UserDefaults,
        _ key: String,
        fallback: Bool
    ) -> Bool {
        guard defaults.object(forKey: key) != nil else { return fallback }
        return defaults.bool(forKey: key)
    }

    private static func double(
        _ defaults: UserDefaults,
        _ key: String,
        fallback: Double
    ) -> Double {
        guard defaults.object(forKey: key) != nil else { return fallback }
        return defaults.double(forKey: key)
    }
}

/// One rendered caption plane, ready to be shown by the overlay.
///
/// `CGImage` is not marked `Sendable`; the image is immutable after the
/// renderer produced it, so handing it from the render actor to the main actor
/// is safe.
struct CaptionRenderFrame: @unchecked Sendable {
    let image: CGImage
    /// Destination in the renderer's pixel coordinate space (origin top-left).
    let destinationRect: CGRect
}

/// A decoded caption plus the elementary stream it came from.
struct DecodedCaption: @unchecked Sendable {
    let caption: ARIBCaption
    let kind: CaptionPESKind
}

/// Owns libaribcaption's decoders and renderers.
///
/// An actor keeps them on one serial executor: they are not thread-safe, but
/// all calls (decode, append, render, configure) arrive in order. Decoding and
/// rendering therefore never run on the main actor.
actor CaptionRenderPipeline {
    private var frameSize = CGSize(width: 1920, height: 1080)
    private var preferences: CaptionPreferences?

    private var captionDecoder: ARIBCaptionDecoder?
    private var superimposeDecoder: ARIBCaptionDecoder?
    private var captionRenderer: ARIBCaptionRenderer?
    private var superimposeRenderer: ARIBCaptionRenderer?
    /// Last caption of each stream. A renderer rebuild (video rect or setting
    /// change) re-appends them so the current caption does not disappear.
    private var lastCaption: DecodedCaption?
    private var lastSuperimpose: DecodedCaption?

    /// Rebuilds the renderers when the video size or a setting changes.
    func configure(size: CGSize, preferences: CaptionPreferences) {
        let normalized = CGSize(
            width: max(1, size.width.rounded()),
            height: max(1, size.height.rounded())
        )
        guard normalized != frameSize || preferences != self.preferences
            || captionRenderer == nil
        else { return }

        frameSize = normalized
        self.preferences = preferences
        rebuild()
    }

    /// Decodes one PES packet. Its `pts` must already be on the timeline the
    /// renderer uses (the caller normalises it to 90 kHz ticks).
    func decode(_ pes: CaptionPES) -> DecodedCaption? {
        ensureConfigured()
        guard let decoder = pes.kind == .caption ? captionDecoder : superimposeDecoder else {
            return nil
        }
        switch decoder.decode(pes: pes.payload, pts: pes.pts) {
        case .gotCaption(let caption):
            return DecodedCaption(caption: caption, kind: pes.kind)
        case .noCaption, .error:
            return nil
        }
    }

    /// Hands a decoded caption to the renderer that owns its stream.
    func append(_ decoded: DecodedCaption) {
        ensureConfigured()
        switch decoded.kind {
        case .caption:
            lastCaption = decoded
            captionRenderer?.append(decoded.caption)
        case .superimpose:
            guard preferences?.showSuperimpose == true else { return }
            lastSuperimpose = decoded
            superimposeRenderer?.append(decoded.caption)
        }
    }

    /// Renders the captions active at a playback position in seconds.
    func render(playbackTime: Double) -> [CaptionRenderFrame] {
        ensureConfigured()
        let milliseconds = Int64((max(playbackTime, 0) * 1000).rounded())
        var frames: [CaptionRenderFrame] = []
        if let captionRenderer {
            frames.append(contentsOf: Self.frames(from: captionRenderer.render(
                ptsMilliseconds: milliseconds
            )))
        }
        if preferences?.showSuperimpose == true, let superimposeRenderer {
            frames.append(contentsOf: Self.frames(from: superimposeRenderer.render(
                ptsMilliseconds: milliseconds
            )))
        }
        return frames
    }

    /// Drops every appended caption and resets the decoders. Call after a seek
    /// or when a new item starts.
    func clear() {
        captionDecoder?.flush()
        superimposeDecoder?.flush()
        captionRenderer?.clear()
        superimposeRenderer?.clear()
        lastCaption = nil
        lastSuperimpose = nil
    }

    // MARK: - Private

    private func ensureConfigured() {
        guard captionRenderer == nil else { return }
        if preferences == nil {
            preferences = CaptionPreferences()
        }
        rebuild()
    }

    private func rebuild() {
        captionDecoder = try? ARIBCaptionDecoder(type: .caption)
        superimposeDecoder = try? ARIBCaptionDecoder(type: .superimpose)
        captionRenderer = makeRenderer(type: .caption)
        superimposeRenderer = makeRenderer(type: .superimpose)
        if let lastCaption {
            captionRenderer?.append(lastCaption.caption)
        }
        if preferences?.showSuperimpose == true, let lastSuperimpose {
            superimposeRenderer?.append(lastSuperimpose.caption)
        }
    }

    private func makeRenderer(type: ARIBCaptionKind) -> ARIBCaptionRenderer? {
        guard let preferences else { return nil }
        return try? ARIBCaptionRenderer(
            frameSize: frameSize,
            type: type,
            fontFamilies: preferences.font.fontFamilies,
            forceDefaultFont: preferences.font.fontFamilies != nil,
            alwaysBorderText: preferences.alwaysBorderText,
            strokeWidth: 1,
            replacesDRCS: true,
            opacity: preferences.opacity
        )
    }

    private static func frames(from images: [ARIBCaptionImage]) -> [CaptionRenderFrame] {
        images.map { image in
            CaptionRenderFrame(
                image: image.cgImage,
                destinationRect: image.destinationRect
            )
        }
    }
}

/// Shared caption (字幕・文字スーパー) state for the app-wide player.
///
/// The controller buffers caption PES packets by playback position, decodes
/// them in timeline order through `CaptionRenderPipeline`, and publishes the
/// rendered images for the overlay. Live and recorded playback only differ in
/// how a PES PTS is converted to a playback position; the buffering, seek
/// handling and rendering are the same.
@MainActor
@Observable
final class CaptionController {
    /// Images currently visible on the video.
    private(set) var frames: [CaptionRenderFrame] = []
    /// Bumped whenever `frames` changes, so the UIKit overlay can tell without
    /// diffing the images themselves.
    private(set) var framesGeneration = 0
    /// Number of distinct caption images shown since playback started (read by
    /// the hidden UI-test status label).
    private(set) var renderedCount = 0
    /// Whether the user has captions turned on (`player.captions.toggle`).
    private(set) var isVisible = true
    /// Captions are not part of the PiP window.
    var isPictureInPictureActive = false

    private enum Mode: Sendable, Equatable {
        case idle
        case live
        case video
    }

    private struct PendingPES {
        let pes: CaptionPES
        let time: Double
    }

    private struct PendingCaption {
        let decoded: DecodedCaption
        let time: Double
    }

    @ObservationIgnored private let pipeline = CaptionRenderPipeline()
    @ObservationIgnored private var mode: Mode = .idle
    @ObservationIgnored private var preferences = CaptionPreferences()
    /// Renderer frame size in pixels. The overlay keeps this in sync with
    /// the video rect so caption planes line up with the picture.
    private(set) var renderSize = CGSize(width: 1920, height: 1080)
    @ObservationIgnored private var timeProvider: (@MainActor () -> Double?)?
    @ObservationIgnored private var pendingPES: [PendingPES] = []
    @ObservationIgnored private var pendingCaptions: [PendingCaption] = []
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var needsClear = false
    @ObservationIgnored private var lastFrameCount = 0
    @ObservationIgnored private var lastNow: Double?

    // MARK: - Lifecycle

    /// Starts live caption handling. `timeProvider` returns the seconds since
    /// the live stream's PROGRAM-DATE-TIME anchor.
    func beginLive(_ timeProvider: @escaping @MainActor () -> Double?) {
        begin(mode: .live, timeProvider: timeProvider)
    }

    /// Starts recorded-video caption handling. `timeProvider` returns
    /// `AVPlayer.currentTime()` in seconds.
    func beginVideo(_ timeProvider: @escaping @MainActor () -> Double?) {
        begin(mode: .video, timeProvider: timeProvider)
    }

    /// Stops playback and clears every buffered caption.
    func end() {
        mode = .idle
        timeProvider = nil
        ticker?.cancel()
        ticker = nil
        pendingPES.removeAll()
        pendingCaptions.removeAll()
        frames = []
        framesGeneration &+= 1
        renderedCount = 0
        lastFrameCount = 0
        lastNow = nil
        // The next session's first update clears the pipeline, so a
        // fire-and-forget clear can never land after the new captions.
        needsClear = true
    }

    private func begin(mode: Mode, timeProvider: @escaping @MainActor () -> Double?) {
        self.mode = mode
        self.timeProvider = timeProvider
        // Keep the previous preferences: applyPreferences() compares them
        // with the new mode's (TV vs. video superimpose) settings and rebuilds
        // the renderers only when something actually changed.
        pendingPES.removeAll()
        pendingCaptions.removeAll()
        frames = []
        framesGeneration &+= 1
        renderedCount = 0
        lastFrameCount = 0
        lastNow = nil
        needsClear = true
        startTicker()
    }

    private func startTicker() {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                await self?.update()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    // MARK: - Input

    /// Queues a caption PES at a playback position in seconds. The PTS inside
    /// the PES is ignored and replaced with `playbackTime`, which removes the
    /// 33-bit wrap-around problem from the renderer's timeline.
    func feed(_ pes: CaptionPES, at playbackTime: Double) {
        guard playbackTime.isFinite else { return }
        let ticks = Int64((playbackTime * PTS.clockRate).rounded())
        let normalized = CaptionPES(
            kind: pes.kind,
            pts: pes.pts == nil ? nil : ticks,
            payload: pes.payload
        )
        pendingPES.append(PendingPES(pes: normalized, time: playbackTime))
        // The proxy may finish many prefetched segments at once.
        if pendingPES.count > 512 {
            pendingPES.removeFirst(pendingPES.count - 512)
        }
    }

    /// Current playback position in seconds, for callers that need to stamp a
    /// PES packet without a PTS (common for 文字スーパー).
    func currentPlaybackTime() -> Double? {
        timeProvider?()
    }

    /// Renderer frame size in pixels, set by the overlay when the video rect
    /// changes. The renderer scales caption planes into this size.
    func setRenderSize(_ size: CGSize) {
        guard size.width >= 1, size.height >= 1 else { return }
        let rounded = CGSize(width: size.width.rounded(), height: size.height.rounded())
        guard rounded != renderSize else { return }
        renderSize = rounded
        frames = []
        framesGeneration &+= 1
        let preferences = preferences
        Task { await pipeline.configure(size: rounded, preferences: preferences) }
    }

    /// Shows or hides captions (`s` / the toolbar button).
    func toggleVisibility() {
        isVisible.toggle()
        if !isVisible {
            frames = []
            framesGeneration &+= 1
            lastFrameCount = 0
        }
    }

    /// Drops buffered captions outside the new seek window and clears the
    /// renderer.
    func seek(to seconds: Double) {
        let target = max(seconds, 0)
        pendingPES.removeAll { $0.time < target - 0.25 || $0.time > target + 60 }
        pendingCaptions.removeAll { $0.time < target - 0.25 || $0.time > target + 60 }
        frames = []
        framesGeneration &+= 1
        lastFrameCount = 0
        lastNow = nil
        needsClear = true
    }

    // MARK: - Render loop

    private func update() async {
        guard mode != .idle else { return }

        if needsClear {
            needsClear = false
            await pipeline.clear()
            lastFrameCount = 0
        }

        await applyPreferences()

        guard let timeProvider, let now = timeProvider(), now.isFinite, now > -30 else {
            return
        }

        // A discontinuity can move the timeline backwards (the mock live
        // stream loops, and a real stream restarts its clock). Whatever was
        // buffered belongs to the previous timeline.
        if let lastNow, now < lastNow - 0.5 {
            pendingPES.removeAll()
            pendingCaptions.removeAll()
            frames = []
            framesGeneration &+= 1
            lastFrameCount = 0
            await pipeline.clear()
        }
        lastNow = now

        // Drop captions the playhead has already left behind (seek, reconnect).
        let staleBefore = now - 4
        pendingPES.removeAll { $0.time < staleBefore }
        pendingCaptions.removeAll { $0.time < staleBefore }

        // AVPlayer prefetches segments and the proxy finishes their requests in
        // any order, so decode strictly in timeline order to keep the ARIB
        // decoder state consistent.
        pendingPES.sort { $0.time < $1.time }
        var decodedCount = 0
        while decodedCount < 8, !pendingPES.isEmpty, pendingPES[0].time <= now + 1.0 {
            let item = pendingPES.removeFirst()
            if let decoded = await pipeline.decode(item.pes) {
                pendingCaptions.append(PendingCaption(decoded: decoded, time: item.time))
            }
            decodedCount += 1
        }

        // Append every caption the playhead has reached; the renderer keeps a
        // caption on screen until the next one (or its own duration end).
        var appended = false
        var newestAppendTime: Double?
        if !pendingCaptions.isEmpty {
            pendingCaptions.sort { $0.time < $1.time }
            while let first = pendingCaptions.first, first.time <= now + 0.02 {
                pendingCaptions.removeFirst()
                await pipeline.append(first.decoded)
                appended = true
                newestAppendTime = first.time
            }
        }

        // Render just after the newest appended caption so it is guaranteed to
        // be the image libaribcaption returns; otherwise an append that lands
        // a few milliseconds in the future would publish the previous caption.
        let renderTime = max(now, (newestAppendTime ?? now) + 0.001)
        let rendered = await pipeline.render(playbackTime: renderTime)
        let emptied = frames.isEmpty != rendered.isEmpty
        if appended || emptied {
            publish(rendered, appended: appended)
        }
    }

    private func applyPreferences() async {
        let loaded = CaptionPreferences.load(mode: mode == .live ? .live : .video)
        guard loaded != preferences else { return }
        preferences = loaded
        await pipeline.configure(size: renderSize, preferences: loaded)
        frames = []
        framesGeneration &+= 1
        lastFrameCount = 0
    }

    private func publish(_ rendered: [CaptionRenderFrame], appended: Bool) {
        frames = rendered
        framesGeneration &+= 1
        if !rendered.isEmpty, appended || lastFrameCount == 0 {
            renderedCount += 1
        }
        lastFrameCount = rendered.count
    }
}
