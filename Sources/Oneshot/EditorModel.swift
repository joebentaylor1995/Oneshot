import AppKit
import AVFoundation
import CoreImage

enum TimelineSelection: Equatable {
    case zoom(UUID)
    case cut(UUID)
    case speed(UUID)
}

enum InspectorTab: String, CaseIterable, Identifiable {
    case background = "Background"
    case cursor = "Cursor"
    case zoom = "Zoom"
    case audio = "Audio"
    var id: String { rawValue }
}

/// Playhead state, kept separate from EditorModel so ticking it 120 times a second
/// only redraws the playhead line and the time label, not the whole editor.
@MainActor
final class PlaybackClock: ObservableObject {
    /// Playhead in source (recording) time.
    @Published var sourceTime: Double = 0
}

/// State for one project: edits (autosaved), playback, and the render snapshot shared with the preview.
@MainActor
final class EditorModel: ObservableObject {
    let project: ProjectFolder
    let info: RecordingInfo
    let cursorTrack: CursorTrack
    let sourceAsset: AVURLAsset
    let player = AVPlayer()
    let renderState = RenderState()
    let clock = PlaybackClock()

    @Published var edits: ProjectEdits {
        didSet { if edits != oldValue { editsDidChange(from: oldValue) } }
    }
    @Published var selection: TimelineSelection?
    @Published var inspectorTab: InspectorTab = .background
    @Published private(set) var sourceDuration: Double
    @Published private(set) var mapping: TimeMapping
    /// Playhead in source time.
    var playhead: Double { clock.sourceTime }
    @Published private(set) var isPlaying = false
    @Published private(set) var thumbnails: [NSImage] = []
    /// Audio peaks for the timeline (Waveform.bucketsPerSecond per second); empty if silent.
    @Published private(set) var waveform: [Float] = []
    @Published private(set) var waveformLoaded = false
    @Published private(set) var isLoaded = false
    @Published private(set) var loadError: String?
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var name: String
    /// Saved or exported: kept when the editor closes. Unsaved drafts go to the Trash.
    @Published private(set) var isKept: Bool
    @Published var showingSavePrompt = false
    /// Where the native traffic lights sit, so the top bar can line up with them.
    @Published var chrome = WindowChrome()

    struct WindowChrome: Equatable {
        var height: CGFloat = 52
        var leading: CGFloat = 84
    }

    private var undoStack: [ProjectEdits] = []
    private var redoStack: [ProjectEdits] = []
    private var lastUndoSnapshot = Date.distantPast
    private var isRestoringHistory = false

    private var cursorImages: [CIImage] = []
    private var cursorShapes: [CursorShape] = []
    private var backgroundImages: [String: CIImage] = [:]
    private var currentBackgroundImage: CIImage?
    private var cachedCursorMotion: (key: String, motion: CursorMotion)?
    private var composition: AVMutableComposition?
    private var tickTimer: Timer?
    private var seekInFlight = false
    private var pendingSeek: CMTime?
    private var endObserver: NSObjectProtocol?
    private var buildGeneration = 0
    private var saveTask: Task<Void, Never>?
    private var snapshotTask: Task<Void, Never>?

    init(project: ProjectFolder) throws {
        guard let info = project.loadInfo() else { throw OneshotError.projectUnreadable }
        self.project = project
        self.info = info
        name = project.displayName
        isKept = !project.isDraft
        cursorTrack = project.loadCursor() ?? CursorTrack()
        let edits = project.loadEdits() ?? ProjectEdits()
        self.edits = edits
        sourceAsset = AVURLAsset(url: project.videoURL)
        sourceDuration = info.duration
        mapping = TimeMapping.build(edits: edits, sourceDuration: info.duration)

        player.actionAtItemEnd = .pause
        player.automaticallyWaitsToMinimizeStalling = false
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                             object: nil, queue: .main) { [weak self] note in
            let item = note.object as AnyObject?
            MainActor.assumeIsolated {
                guard let self, item === self.player.currentItem else { return }
                self.isPlaying = false
                self.stopTicking()
                self.clock.sourceTime = self.mapping.pieces.last?.sourceEnd ?? self.sourceDuration
            }
        }
    }

    // MARK: Loading

    func load() async {
        do {
            let duration = try await sourceAsset.load(.duration).seconds
            if duration.isFinite, duration > 0 {
                sourceDuration = duration
                mapping = TimeMapping.build(edits: edits, sourceDuration: duration)
            }
            loadCursorImages()
            if !edits.autoZoomGenerated {
                var updated = edits
                updated.zooms = AutoZoom.generate(clicks: cursorTrack.clicks, duration: sourceDuration)
                updated.autoZoomGenerated = true
                edits = updated
            }
            await loadBackgroundImage()
            rebuildSnapshot()
            await rebuildPlayerItem()
            isLoaded = true
            waveform = await Waveform.load(from: sourceAsset, duration: sourceDuration)
            waveformLoaded = true
            await generateThumbnails()
        } catch {
            loadError = error.localizedDescription
            isLoaded = true
        }
    }

    private func loadCursorImages() {
        let fallback = Self.fallbackCursor()
        var shapes: [CursorShape] = []
        var images: [CIImage] = []
        for shape in cursorTrack.shapes {
            shapes.append(shape)
            images.append(CIImage(contentsOf: project.cursorsURL.appendingPathComponent(shape.file)) ?? fallback.image)
        }
        if shapes.isEmpty {
            shapes = [fallback.shape]
            images = [fallback.image]
        }
        cursorShapes = shapes
        cursorImages = images
    }

    private static func fallbackCursor() -> (shape: CursorShape, image: CIImage) {
        let cursor = NSCursor.arrow
        let size = cursor.image.size
        let shape = CursorShape(file: "", hotX: Double(cursor.hotSpot.x), hotY: Double(cursor.hotSpot.y),
                                width: Double(max(size.width, 1)), height: Double(max(size.height, 1)))
        if let raster = rasterize(cursor.image, scale: 4) {
            return (shape, CIImage(cgImage: raster.image))
        }
        return (shape, CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4)))
    }

    private func loadBackgroundImage() async {
        switch edits.style.background {
        case .wallpaper(let path), .image(let path):
            if let cached = backgroundImages[path] {
                currentBackgroundImage = cached
                return
            }
            let url = URL(fileURLWithPath: path)
            let cgImage = await Task.detached(priority: .userInitiated) {
                Backgrounds.loadImage(at: url, maxPixel: 3840)
            }.value
            if let cgImage {
                let image = CIImage(cgImage: cgImage)
                backgroundImages[path] = image
                currentBackgroundImage = image
            }
        default:
            currentBackgroundImage = nil
        }
    }

    private func generateThumbnails(count: Int = 24) async {
        let generator = AVAssetImageGenerator(asset: sourceAsset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 320)
        var images: [NSImage] = []
        for index in 0..<count {
            let seconds = sourceDuration * (Double(index) + 0.5) / Double(count)
            if let result = try? await generator.image(at: cmTime(seconds)) {
                images.append(NSImage(cgImage: result.image, size: .zero))
            }
        }
        thumbnails = images
    }

    func thumbnail(near time: Double) -> NSImage? {
        guard !thumbnails.isEmpty, sourceDuration > 0 else { return nil }
        let index = Int(clamp(time / sourceDuration, 0, 0.999) * Double(thumbnails.count))
        return thumbnails[index]
    }

    // MARK: Reacting to edits

    private func editsDidChange(from old: ProjectEdits) {
        scheduleSave()
        guard isLoaded else { return }
        recordHistory(previous: old)

        let timingChanged = old.cuts != edits.cuts || old.speeds != edits.speeds
            || old.trimStart != edits.trimStart || old.trimEnd != edits.trimEnd
        if timingChanged {
            mapping = TimeMapping.build(edits: edits, sourceDuration: sourceDuration)
            Task { await rebuildPlayerItem() }
        } else if old.style.aspect != edits.style.aspect {
            Task { await updateVideoComposition() }
        }
        if old.style.systemVolume != edits.style.systemVolume || old.style.micVolume != edits.style.micVolume
            || old.style.fadeIn != edits.style.fadeIn || old.style.fadeOut != edits.style.fadeOut {
            updateAudioMix()
        }
        if old.style.background != edits.style.background {
            Task {
                await loadBackgroundImage()
                scheduleSnapshot()
            }
        }
        scheduleSnapshot()
    }

    /// Coalesces bursts of changes (slider drags) into one snapshot rebuild per run loop turn.
    private func scheduleSnapshot() {
        guard snapshotTask == nil else { return }
        snapshotTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            self.snapshotTask = nil
            self.rebuildSnapshot()
            self.refreshPausedFrame()
        }
    }

    private func rebuildSnapshot() {
        let style = edits.style
        let key = "\(style.cursorSmoothing)|\(style.hideIdleCursor)|\(sourceDuration)"
        let cursorMotion: CursorMotion
        if let cached = cachedCursorMotion, cached.key == key {
            cursorMotion = cached.motion
        } else {
            cursorMotion = CursorMotion.build(track: cursorTrack, duration: sourceDuration,
                                              smoothing: style.cursorSmoothing, hideIdle: style.hideIdleCursor)
            cachedCursorMotion = (key, cursorMotion)
        }
        let camera = CameraMotion.build(zooms: edits.zooms, cursor: cursorMotion,
                                        duration: sourceDuration, smoothing: style.cameraSmoothing)
        renderState.snapshot = RenderSnapshot(style: style,
                                              mapping: mapping,
                                              info: info,
                                              cursor: cursorMotion,
                                              camera: camera,
                                              clicks: cursorTrack.clicks,
                                              cursorImages: cursorImages,
                                              cursorShapes: cursorShapes,
                                              shapeChanges: cursorTrack.shapeChanges,
                                              backgroundImage: currentBackgroundImage)
    }

    /// While paused, nudge the player so the current frame re-renders with the new settings.
    private func refreshPausedFrame() {
        guard !isPlaying, let item = player.currentItem,
              let copy = item.videoComposition?.mutableCopy() as? AVVideoComposition else { return }
        item.videoComposition = copy
    }

    // MARK: Player item

    var outputAspect: CGFloat { edits.style.aspect.ratio(source: info.sourceAspect) }

    func canvasSize(shortSide: CGFloat) -> CGSize {
        let ratio = outputAspect
        let size = ratio >= 1
            ? CGSize(width: shortSide * ratio, height: shortSide)
            : CGSize(width: shortSide, height: shortSide / ratio)
        return CGSize(width: evenFloor(size.width), height: evenFloor(size.height))
    }

    private var previewSize: CGSize { canvasSize(shortSide: 720) }

    /// The aspect of the frames actually rendered (rounded to even pixels), for the preview surface.
    var previewAspect: CGFloat { previewSize.width / max(previewSize.height, 1) }

    private func rebuildPlayerItem() async {
        buildGeneration += 1
        let generation = buildGeneration
        do {
            let built = try await CompositionBuilder.build(source: sourceAsset, mapping: mapping)
            let videoComposition = try await Compositor.makeVideoComposition(for: built, renderSize: previewSize, fps: 60, state: renderState)
            guard generation == buildGeneration else { return }
            let item = AVPlayerItem(asset: built)
            item.videoComposition = videoComposition
            item.audioMix = CompositionBuilder.audioMix(for: built, info: info, style: edits.style)
            item.audioTimePitchAlgorithm = .spectral
            composition = built
            let resume = playhead
            let wasPlaying = isPlaying
            player.replaceCurrentItem(with: item)
            seek(toSource: resume)
            if wasPlaying { player.playImmediately(atRate: 1) }
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func updateVideoComposition() async {
        guard let composition, let item = player.currentItem else { return }
        if let videoComposition = try? await Compositor.makeVideoComposition(for: composition, renderSize: previewSize, fps: 60, state: renderState) {
            item.videoComposition = videoComposition
        }
    }

    private func updateAudioMix() {
        guard let composition, let item = player.currentItem else { return }
        item.audioMix = CompositionBuilder.audioMix(for: composition, info: info, style: edits.style)
    }

    // MARK: Playback

    var outputDuration: Double { mapping.duration }
    var outputTime: Double { mapping.compositionTime(forSource: playhead) }

    /// Reads the player's clock in sync with the display while playing.
    private func startTicking() {
        tickTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    private func stopTicking() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    private func tick() {
        guard isPlaying else { return }
        let t = player.currentTime().seconds
        guard t.isFinite else { return }
        clock.sourceTime = mapping.sourceTime(forComposition: t)
    }

    func togglePlayback() {
        if isPlaying { pause() } else { play() }
    }

    func play() {
        if outputTime >= outputDuration - 0.05 {
            seek(toSource: mapping.pieces.first?.sourceStart ?? 0)
        }
        player.playImmediately(atRate: 1)
        isPlaying = true
        startTicking()
    }

    func pause() {
        player.pause()
        isPlaying = false
        stopTicking()
        let t = player.currentTime().seconds
        if t.isFinite { clock.sourceTime = mapping.sourceTime(forComposition: t) }
    }

    func seek(toSource time: Double) {
        let clamped = clamp(time, 0, sourceDuration)
        clock.sourceTime = clamped
        chaseSeek(to: cmTime(mapping.compositionTime(forSource: clamped)))
    }

    /// Only one seek in flight at a time; while scrubbing, the latest position wins.
    private func chaseSeek(to time: CMTime) {
        pendingSeek = time
        guard !seekInFlight else { return }
        seekInFlight = true
        runPendingSeek()
    }

    private func runPendingSeek() {
        guard let target = pendingSeek else {
            seekInFlight = false
            return
        }
        pendingSeek = nil
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.runPendingSeek() }
            }
        }
    }

    /// Steps the playhead by whole preview frames (arrow keys).
    func step(frames: Int) {
        scrub(toSource: playhead + Double(frames) / 60)
    }

    func scrub(toSource time: Double) {
        pause()
        seek(toSource: time)
    }

    func jumpToStart() {
        scrub(toSource: mapping.pieces.first?.sourceStart ?? 0)
    }

    func jumpToEnd() {
        scrub(toSource: mapping.pieces.last?.sourceEnd ?? sourceDuration)
    }

    // MARK: Undo / redo

    /// Bursts of changes (a slider drag, a segment drag) collapse into one undo step.
    private func recordHistory(previous: ProjectEdits) {
        guard !isRestoringHistory else { return }
        let now = Date()
        if now.timeIntervalSince(lastUndoSnapshot) > 0.6 {
            undoStack.append(previous)
            if undoStack.count > 200 { undoStack.removeFirst() }
        }
        lastUndoSnapshot = now
        redoStack.removeAll()
        updateHistoryFlags()
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(edits)
        restore(previous)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(edits)
        restore(next)
    }

    private func restore(_ snapshot: ProjectEdits) {
        isRestoringHistory = true
        edits = snapshot
        isRestoringHistory = false
        lastUndoSnapshot = .distantPast
        if let selection, !selectionExists(selection) { self.selection = nil }
        updateHistoryFlags()
    }

    private func selectionExists(_ selection: TimelineSelection) -> Bool {
        switch selection {
        case .zoom(let id): return edits.zooms.contains { $0.id == id }
        case .cut(let id): return edits.cuts.contains { $0.id == id }
        case .speed(let id): return edits.speeds.contains { $0.id == id }
        }
    }

    private func updateHistoryFlags() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    // MARK: Editing

    var trimEnd: Double { edits.trimEnd ?? sourceDuration }

    func setTrimStart(_ value: Double) {
        edits.trimStart = clamp(value, 0, max(0, trimEnd - 0.2))
    }

    func setTrimEnd(_ value: Double) {
        edits.trimEnd = clamp(value, edits.trimStart + 0.2, sourceDuration)
    }

    func select(_ selection: TimelineSelection?) {
        self.selection = selection
        if case .zoom? = selection { inspectorTab = .zoom }
    }

    func addZoom(at time: Double) {
        let start = clamp(time, 0, max(0, sourceDuration - 0.5))
        let zoom = ZoomSegment(start: start, end: min(sourceDuration, start + 2.5))
        edits.zooms.append(zoom)
        select(.zoom(zoom.id))
    }

    func addZoomAtPlayhead() { addZoom(at: playhead) }

    func addCutAtPlayhead() {
        let start = clamp(playhead, 0, max(0, sourceDuration - 0.3))
        let cut = CutSegment(start: start, end: min(sourceDuration, start + 1))
        edits.cuts.append(cut)
        select(.cut(cut.id))
    }

    func addSpeedAtPlayhead() {
        let start = clamp(playhead, 0, max(0, sourceDuration - 0.3))
        let speed = SpeedSegment(start: start, end: min(sourceDuration, start + 3))
        edits.speeds.append(speed)
        select(.speed(speed.id))
    }

    func regenerateAutoZooms() {
        var updated = edits
        updated.zooms.removeAll { $0.isAuto }
        updated.zooms.append(contentsOf: AutoZoom.generate(clicks: cursorTrack.clicks, duration: sourceDuration))
        updated.zooms.sort { $0.start < $1.start }
        edits = updated
    }

    func updateTiming<T: TimedSegment>(_ keyPath: WritableKeyPath<ProjectEdits, [T]>, id: UUID, start: Double, end: Double) {
        guard let index = edits[keyPath: keyPath].firstIndex(where: { $0.id == id }) else { return }
        var segment = edits[keyPath: keyPath][index]
        segment.start = clamp(start, 0, sourceDuration)
        segment.end = clamp(end, segment.start + 0.2, sourceDuration)
        edits[keyPath: keyPath][index] = segment
    }

    func updateZoom(_ id: UUID, _ change: (inout ZoomSegment) -> Void) {
        guard let index = edits.zooms.firstIndex(where: { $0.id == id }) else { return }
        var zoom = edits.zooms[index]
        change(&zoom)
        zoom.isAuto = false
        edits.zooms[index] = zoom
    }

    func updateSpeed(_ id: UUID, rate: Double) {
        guard let index = edits.speeds.firstIndex(where: { $0.id == id }) else { return }
        edits.speeds[index].rate = rate
    }

    func deleteSelection() {
        guard let selection else { return }
        switch selection {
        case .zoom(let id): edits.zooms.removeAll { $0.id == id }
        case .cut(let id): edits.cuts.removeAll { $0.id == id }
        case .speed(let id): edits.speeds.removeAll { $0.id == id }
        }
        self.selection = nil
    }

    var selectedZoom: ZoomSegment? {
        if case .zoom(let id)? = selection { return edits.zooms.first { $0.id == id } }
        return nil
    }

    var selectedCut: CutSegment? {
        if case .cut(let id)? = selection { return edits.cuts.first { $0.id == id } }
        return nil
    }

    var selectedSpeed: SpeedSegment? {
        if case .speed(let id)? = selection { return edits.speeds.first { $0.id == id } }
        return nil
    }

    // MARK: Saving & teardown

    private func scheduleSave() {
        saveTask?.cancel()
        let edits = self.edits
        let project = self.project
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            project.saveEdits(edits)
        }
    }

    func save(as newName: String) {
        project.rename(to: newName)
        project.keep()
        name = project.displayName
        isKept = true
    }

    func markKept() {
        project.keep()
        isKept = true
    }

    func teardown() {
        saveTask?.cancel()
        project.saveEdits(edits)
        player.pause()
        stopTicking()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player.replaceCurrentItem(with: nil)
    }
}
