import AppKit
import CoreGraphics

/// Thread-safe store the samplers write into while recording.
final class CursorTrackStore: @unchecked Sendable {
    private let lock = NSLock()
    private var track = CursorTrack()

    func addSample(_ sample: CursorSample) {
        lock.lock(); track.samples.append(sample); lock.unlock()
    }

    func addClick(_ click: ClickEvent) {
        lock.lock(); track.clicks.append(click); lock.unlock()
    }

    func addShape(_ shape: CursorShape) -> Int {
        lock.lock(); defer { lock.unlock() }
        track.shapes.append(shape)
        return track.shapes.count - 1
    }

    func addShapeChange(_ change: CursorShapeChange) {
        lock.lock(); track.shapeChanges.append(change); lock.unlock()
    }

    func snapshot() -> CursorTrack {
        lock.lock(); defer { lock.unlock() }
        return track
    }
}

/// Polls the cursor position and mouse buttons at ~120 Hz. No permissions needed.
final class CursorSampler: @unchecked Sendable {
    /// Recorded area in global Quartz coordinates (points, top-left origin).
    private let region: CGRect
    private let store: CursorTrackStore
    private let queue = DispatchQueue(label: "oneshot.cursor", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var wasDown = false

    init(region: CGRect, store: CursorTrackStore) {
        self.region = region
        self.store = store
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(8_333_333), leeway: .nanoseconds(500_000))
        timer.setEventHandler { [weak self] in self?.sample() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func sample() {
        guard let location = CGEvent(source: nil)?.location, region.width > 0, region.height > 0 else { return }
        let t = hostTimeSeconds()
        let x = Double((location.x - region.minX) / region.width)
        let y = Double((location.y - region.minY) / region.height)
        store.addSample(CursorSample(t: t, x: x, y: y))

        let down = CGEventSource.buttonState(.combinedSessionState, button: .left)
            || CGEventSource.buttonState(.combinedSessionState, button: .right)
        if down && !wasDown {
            store.addClick(ClickEvent(t: t, x: x, y: y))
        }
        wasDown = down
    }
}

/// Captures the current system cursor image (arrow, I-beam, hand…) whenever it changes,
/// saving each unique shape as a high-resolution PNG so it can be re-rendered at any size.
@MainActor
final class CursorShapeRecorder {
    private let store: CursorTrackStore
    private let directory: URL
    private var timer: Timer?
    private var known: [Int: Int] = [:]
    private var current = -1

    init(store: CursorTrackStore, directory: URL) {
        self.store = store
        self.directory = directory
    }

    func start() {
        capture()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.capture() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func capture() {
        guard let cursor = NSCursor.currentSystem else { return }
        let image = cursor.image
        guard image.size.width > 0, image.size.height > 0,
              let raster = rasterize(image, scale: 4) else { return }

        var hasher = Hasher()
        hasher.combine(raster.hash)
        hasher.combine(cursor.hotSpot.x)
        hasher.combine(cursor.hotSpot.y)
        let key = hasher.finalize()

        let index: Int
        if let existing = known[key] {
            index = existing
        } else {
            let file = "cursor-\(known.count).png"
            writePNG(raster.image, to: directory.appendingPathComponent(file))
            index = store.addShape(CursorShape(file: file,
                                               hotX: Double(cursor.hotSpot.x),
                                               hotY: Double(cursor.hotSpot.y),
                                               width: Double(image.size.width),
                                               height: Double(image.size.height)))
            known[key] = index
        }
        if index != current {
            current = index
            store.addShapeChange(CursorShapeChange(t: hostTimeSeconds(), shape: index))
        }
    }
}
