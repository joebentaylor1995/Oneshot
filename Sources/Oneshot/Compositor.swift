import AVFoundation
import CoreImage

/// Everything the renderer needs for one state of the edit. Immutable once built, so the
/// video composition's background threads can read it while the UI builds the next one.
final class RenderSnapshot: @unchecked Sendable {
    let style: StyleSettings
    let mapping: TimeMapping
    let info: RecordingInfo
    let cursor: CursorMotion
    let camera: CameraMotion
    let clicks: [ClickEvent]
    let cursorImages: [CIImage]
    let cursorShapes: [CursorShape]
    let shapeChanges: [CursorShapeChange]
    let backgroundImage: CIImage?

    private let cacheLock = NSLock()
    /// Background + shadow, pre-rendered once per canvas size (preview and export sizes differ).
    private var baseCache: [String: CIImage] = [:]

    /// Used only to flatten the static base layer into a bitmap.
    private static let flattenContext = CIContext(options: [.cacheIntermediates: false])

    init(style: StyleSettings, mapping: TimeMapping, info: RecordingInfo, cursor: CursorMotion, camera: CameraMotion,
         clicks: [ClickEvent], cursorImages: [CIImage], cursorShapes: [CursorShape],
         shapeChanges: [CursorShapeChange], backgroundImage: CIImage?) {
        self.style = style
        self.mapping = mapping
        self.info = info
        self.cursor = cursor
        self.camera = camera
        self.clicks = clicks.sorted { $0.t < $1.t }
        self.cursorImages = cursorImages
        self.cursorShapes = cursorShapes
        self.shapeChanges = shapeChanges.sorted { $0.t < $1.t }
        self.backgroundImage = backgroundImage
    }

    // MARK: Render

    /// Composes one output frame: background → shadow → rounded screen → click effects → cursor,
    /// all seen through the zoom camera. Every layer is transformed straight from its source,
    /// so zoomed-in text stays as sharp as the recording allows. `outputTime` (after trim, cuts
    /// and speed-ups) drives the fade in and out; nil leaves the fades out.
    func render(source: CIImage, sourceTime t: Double, outputTime: Double?, canvas: CGSize) -> CIImage {
        let canvasRect = CGRect(origin: .zero, size: canvas)
        let src = source.extent
        guard src.width > 0, src.height > 0, canvas.width > 0, canvas.height > 0 else { return source }
        let short = min(canvas.width, canvas.height)

        // Where the recording sits on the canvas before zooming.
        let pad = CGFloat(style.padding) * short
        let available = canvasRect.insetBy(dx: pad, dy: pad)
        let fit = min(available.width / src.width, available.height / src.height)
        var content = CGRect(x: available.midX - src.width * fit / 2,
                             y: available.midY - src.height * fit / 2,
                             width: src.width * fit,
                             height: src.height * fit)
        // The canvas is rounded to even pixels, so a recording that should fill it can come up a
        // pixel or two short and leave hairlines of background along the edges. Within that
        // tolerance, stretch it to the edge (an invisible change in aspect).
        let snap: CGFloat = 2.5
        if available.width - content.width < snap {
            content.origin.x = available.minX
            content.size.width = available.width
        }
        if available.height - content.height < snap {
            content.origin.y = available.minY
            content.size.height = available.height
        }
        let fitX = content.width / src.width
        let fitY = content.height / src.height

        // Camera: scale around the focus point, kept inside the recording where possible.
        let cam = camera.frame(at: t)
        let s = CGFloat(max(cam.scale, 1))
        let focus = CGPoint(x: content.minX + CGFloat(cam.x) * content.width,
                            y: content.maxY - CGFloat(cam.y) * content.height)
        let originX = Self.viewOrigin(focus: focus.x, view: canvas.width / s, low: content.minX, high: content.maxX, total: canvas.width)
        let originY = Self.viewOrigin(focus: focus.y, view: canvas.height / s, low: content.minY, high: content.maxY, total: canvas.height)
        let cameraTransform = CGAffineTransform(translationX: -originX, y: -originY)
            .concatenating(CGAffineTransform(scaleX: s, y: s))

        let sourceToCanvas = CGAffineTransform(translationX: -src.minX, y: -src.minY)
            .concatenating(CGAffineTransform(scaleX: fitX, y: fitY))
            .concatenating(CGAffineTransform(translationX: content.minX, y: content.minY))
            .concatenating(cameraTransform)

        let point: (Double, Double) -> CGPoint = { nx, ny in
            CGPoint(x: src.minX + CGFloat(nx) * src.width, y: src.minY + CGFloat(1 - ny) * src.height)
                .applying(sourceToCanvas)
        }

        // Background and shadow never change during playback, so they come from a cached bitmap
        // that the camera just scales and moves (no per-frame blur).
        // With no padding the recording fills the canvas edge to edge, so its corners stay square
        // rather than showing slivers of background.
        let baseRadius = style.padding > 0
            ? min(CGFloat(style.cornerRadius) * short, min(content.width, content.height) / 2)
            : 0
        var output = baseLayer(canvas: canvas, content: content, radius: baseRadius, short: short)
            .transformed(by: cameraTransform)

        let frame = content.applying(cameraTransform)
        let radius = baseRadius * s

        let screen = Self.resample(source, scaleX: fitX * s, scaleY: fitY * s,
                                   offset: CGPoint(x: (content.minX - originX) * s, y: (content.minY - originY) * s))
        if let mask = Self.roundedRect(frame, radius: radius, color: CIColor(red: 1, green: 1, blue: 1, alpha: 1)) {
            output = screen.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: output,
                kCIInputMaskImageKey: mask,
            ])
        } else {
            output = screen.composited(over: output)
        }

        // Canvas pixels per screen point, used to size the cursor and click effects.
        let pixelsPerPoint = fitX * s * CGFloat(info.scale)
        output = drawClicks(on: output, t: t, point: point, pixelsPerPoint: pixelsPerPoint, short: short)
        output = drawCursor(on: output, t: t, point: point, pixelsPerPoint: pixelsPerPoint,
                            contentPixels: CGSize(width: content.width * s, height: content.height * s))
        output = output.cropped(to: canvasRect)

        let level = outputTime.map { fadeLevel(at: $0) } ?? 1
        if level < 0.999 {
            let k = CGFloat(max(level, 0))
            output = output.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: k, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0),
            ])
        }
        return output
    }

    /// Brightness at an output time: 0 (black) at the very start and end, 1 between the fades.
    func fadeLevel(at outputTime: Double) -> Double {
        let (fadeIn, fadeOut) = style.fadeDurations(total: mapping.duration)
        var level = 1.0
        if fadeIn > 0 { level = min(level, outputTime / fadeIn) }
        if fadeOut > 0 { level = min(level, (mapping.duration - outputTime) / fadeOut) }
        return Ease.inOutCubic(clamp(level, 0, 1))
    }

    /// Places the recording on the canvas: the same mapping as `sourceToCanvas`, but resized with
    /// Lanczos instead of bilinear filtering. When zooming in past the recording's own resolution
    /// (common with 1× displays) it also sharpens a little, so text stays crisp instead of soft.
    /// The two scales differ only by the sub-pixel stretch that makes the recording meet the edges.
    static func resample(_ source: CIImage, scaleX kx: CGFloat, scaleY k: CGFloat, offset: CGPoint) -> CIImage {
        let src = source.extent
        let placed = CGAffineTransform(translationX: offset.x, y: offset.y)
        guard abs(k - 1) > 0.001 || abs(kx - 1) > 0.001 else {
            return source.transformed(by: CGAffineTransform(translationX: -src.minX + offset.x, y: -src.minY + offset.y))
        }
        // Clamp first so the edges are resampled from real pixels rather than fading to transparent.
        var image = source
            .transformed(by: CGAffineTransform(translationX: -src.minX, y: -src.minY))
            .clampedToExtent()
            .applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: k,
                kCIInputAspectRatioKey: kx / k,
            ])
        if k > 1.1 {
            image = image.applyingFilter("CISharpenLuminance", parameters: [
                kCIInputSharpnessKey: min(0.5, (k - 1) * 0.45),
                kCIInputRadiusKey: 1.2,
            ])
        }
        return image
            .cropped(to: CGRect(x: 0, y: 0, width: src.width * kx, height: src.height * k))
            .transformed(by: placed)
    }

    private func drawClicks(on image: CIImage, t: Double, point: (Double, Double) -> CGPoint,
                            pixelsPerPoint: CGFloat, short: CGFloat) -> CIImage {
        guard style.clickEffect != .none, !clicks.isEmpty else { return image }
        let life = style.clickEffect == .lens ? LensRipple.duration : 0.55
        var output = image
        // Binary search for the first click that could still be visible.
        var low = 0
        var high = clicks.count
        while low < high {
            let mid = (low + high) / 2
            if clicks[mid].t < t - life { low = mid + 1 } else { high = mid }
        }
        var index = low
        while index < clicks.count, clicks[index].t <= t {
            let click = clicks[index]
            index += 1
            let progress = (t - click.t) / life
            guard progress >= 0, progress < 1 else { continue }
            let center = point(click.x, click.y)
            let base = 14 * pixelsPerPoint * CGFloat(style.cursorScale)
            switch style.clickEffect {
            case .lens:
                // Drawn under the cursor, so the pointer itself stays crisp.
                output = LensRipple.apply(to: output, center: center, progress: progress, scale: short)
            case .ripple:
                let r = base * CGFloat(0.4 + 1.6 * Ease.outCubic(progress))
                let ring = max(1.5, base * 0.14)
                let alpha = CGFloat(0.8 * (1 - progress))
                if let outer = Self.disk(center: center, radius: r, color: CIColor(red: 0.09, green: 0.33, blue: 1, alpha: alpha)),
                   let inner = Self.disk(center: center, radius: max(0.5, r - ring), color: CIColor(red: 1, green: 1, blue: 1, alpha: 1)) {
                    output = outer.applyingFilter("CISourceOutCompositing", parameters: [kCIInputBackgroundImageKey: inner])
                        .composited(over: output)
                }
            case .circle:
                let r = base * CGFloat(1.1 - 0.3 * progress)
                let alpha = CGFloat(0.35 * (1 - progress))
                if let disk = Self.disk(center: center, radius: r, color: CIColor(red: 0.09, green: 0.33, blue: 1, alpha: alpha)) {
                    output = disk.composited(over: output)
                }
            case .none:
                break
            }
        }
        return output
    }

    private func drawCursor(on image: CIImage, t: Double, point: (Double, Double) -> CGPoint,
                            pixelsPerPoint: CGFloat, contentPixels: CGSize) -> CIImage {
        guard style.showCursor, !cursorImages.isEmpty else { return image }
        let c = cursor.sample(at: t)
        guard c.alpha > 0.01, c.x > -0.01, c.x < 1.01, c.y > -0.01, c.y < 1.01 else { return image }

        let index = min(shapeIndex(at: t), cursorImages.count - 1)
        let shape = cursorShapes[index]
        let source = cursorImages[index]
        guard source.extent.width > 0, shape.width > 0, shape.height > 0 else { return image }

        let targetWidth = CGFloat(shape.width) * pixelsPerPoint * CGFloat(style.cursorScale)
        let k = targetWidth / source.extent.width
        var cursorImage = source.transformed(by: CGAffineTransform(translationX: -source.extent.minX, y: -source.extent.minY)
            .concatenating(CGAffineTransform(scaleX: k, y: k)))
        let size = cursorImage.extent.size
        let hotSpot = CGPoint(x: CGFloat(shape.hotX / shape.width) * size.width,
                              y: size.height - CGFloat(shape.hotY / shape.height) * size.height)
        let position = point(c.x, c.y)
        cursorImage = cursorImage.transformed(by: CGAffineTransform(translationX: position.x - hotSpot.x, y: position.y - hotSpot.y))

        if style.motionBlur > 0.01 {
            let vx = c.vx * Double(contentPixels.width)
            let vy = -c.vy * Double(contentPixels.height)
            let perFrame = hypot(vx, vy) / 60
            let radius = min(perFrame * style.motionBlur * 0.6, Double(targetWidth) * 1.5)
            if radius > 1 {
                cursorImage = cursorImage.applyingFilter("CIMotionBlur", parameters: [
                    kCIInputRadiusKey: radius,
                    kCIInputAngleKey: atan2(vy, vx),
                ])
            }
        }
        if c.alpha < 0.999 {
            cursorImage = cursorImage.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(c.alpha)),
            ])
        }
        return cursorImage.composited(over: image)
    }

    private func shapeIndex(at t: Double) -> Int {
        guard !shapeChanges.isEmpty else { return 0 }
        var low = 0
        var high = shapeChanges.count - 1
        if shapeChanges[0].t > t { return shapeChanges[0].shape }
        while low < high {
            let mid = (low + high + 1) / 2
            if shapeChanges[mid].t <= t { low = mid } else { high = mid - 1 }
        }
        return max(0, shapeChanges[low].shape)
    }

    // MARK: Background & shadow

    private func baseLayer(canvas: CGSize, content: CGRect, radius: CGFloat, short: CGFloat) -> CIImage {
        let key = "\(Int(canvas.width))x\(Int(canvas.height))"
        cacheLock.lock()
        if let cached = baseCache[key] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let rect = CGRect(origin: .zero, size: canvas)
        var image = makeBackground(canvas: canvas)
        if style.shadow > 0.01 {
            let blur = max(1, CGFloat(style.shadowSize) * short)
            let color = CIColor(red: 0, green: 0, blue: 0, alpha: CGFloat(style.shadow))
            if let shape = Self.roundedRect(content.offsetBy(dx: 0, dy: -blur * 0.4), radius: radius, color: color) {
                image = shape.applyingGaussianBlur(sigma: Double(blur / 2)).composited(over: image)
            }
        }
        image = image.cropped(to: rect)

        var result = image
        if let flattened = Self.flattenContext.createCGImage(image, from: rect) {
            result = CIImage(cgImage: flattened)
        }
        cacheLock.lock()
        baseCache[key] = result
        cacheLock.unlock()
        return result
    }

    private func makeBackground(canvas: CGSize) -> CIImage {
        let rect = CGRect(origin: .zero, size: canvas)
        let image: CIImage
        switch style.background {
        case .gradient(let index):
            image = Backgrounds.gradientImage(index: index, size: canvas)
        case .color(let color):
            image = CIImage(color: color.ciColor).cropped(to: rect)
        case .wallpaper, .image:
            if let backgroundImage {
                image = Backgrounds.aspectFill(backgroundImage, size: canvas)
            } else {
                image = Backgrounds.gradientImage(index: 0, size: canvas)
            }
        }
        return image
    }

    // MARK: Helpers

    static func viewOrigin(focus: CGFloat, view: CGFloat, low: CGFloat, high: CGFloat, total: CGFloat) -> CGFloat {
        let origin: CGFloat
        if high - low >= view {
            origin = min(max(focus - view / 2, low), high - view)
        } else {
            origin = (low + high) / 2 - view / 2
        }
        return min(max(origin, 0), max(0, total - view))
    }

    static func roundedRect(_ rect: CGRect, radius: CGFloat, color: CIColor) -> CIImage? {
        guard rect.width > 1, rect.height > 1 else { return nil }
        let r = max(0, min(radius, min(rect.width, rect.height) / 2))
        return CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
            "inputExtent": CIVector(cgRect: rect),
            "inputRadius": r,
            "inputColor": color,
        ])?.outputImage
    }

    static func disk(center: CGPoint, radius: CGFloat, color: CIColor) -> CIImage? {
        guard radius > 0.5 else { return nil }
        return roundedRect(CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2),
                           radius: radius, color: color)
    }
}

/// Holds the current snapshot behind a lock; swapped by the editor, read by render threads.
final class RenderState: @unchecked Sendable {
    private let lock = NSLock()
    private var current: RenderSnapshot?
    private var fades: Bool

    init(showsFades: Bool = true) {
        fades = showsFades
    }

    var snapshot: RenderSnapshot? {
        get { lock.lock(); defer { lock.unlock() }; return current }
        set { lock.lock(); current = newValue; lock.unlock() }
    }

    /// Off while the editor is paused, so a still frame at the very start or end isn't just black.
    var showsFades: Bool {
        get { lock.lock(); defer { lock.unlock() }; return fades }
        set { lock.lock(); fades = newValue; lock.unlock() }
    }
}

enum Compositor {
    /// One video composition drives both the live preview and the export, so what you see is what you get.
    static func makeVideoComposition(for asset: AVAsset, renderSize: CGSize, fps: Int, state: RenderState) async throws -> AVMutableVideoComposition {
        let composition: AVMutableVideoComposition = try await withCheckedThrowingContinuation { continuation in
            AVMutableVideoComposition.videoComposition(with: asset, applyingCIFiltersWithHandler: { request in
                guard let snapshot = state.snapshot else {
                    request.finish(with: request.sourceImage, context: nil)
                    return
                }
                let outputTime = request.compositionTime.seconds
                let sourceTime = snapshot.mapping.sourceTime(forComposition: outputTime)
                let image = snapshot.render(source: request.sourceImage, sourceTime: sourceTime,
                                            outputTime: state.showsFades ? outputTime : nil,
                                            canvas: request.renderSize)
                request.finish(with: image, context: nil)
            }, completionHandler: { composition, error in
                if let composition {
                    continuation.resume(returning: composition)
                } else {
                    continuation.resume(throwing: error ?? OneshotError.exportFailed("Couldn't create the video composition."))
                }
            })
        }
        composition.renderSize = renderSize
        composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
        return composition
    }
}
