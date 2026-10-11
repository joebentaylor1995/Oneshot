import AppKit
import SwiftUI

/// Full-screen dimmed overlay on every display.
/// - area: drag to draw, drag inside to move, drag the handles to resize, then Return /
///   double-click / Record. A bar at the top locks the shape to a ratio (16:9, 9:16, 1:1, custom…).
///   F = whole screen (largest area of the chosen ratio).
/// - window: hover highlights the window under the pointer, click to record it.
/// - display: hover highlights a display, click to record it.
/// Esc cancels in every mode.
@MainActor
final class RegionSelector {
    enum Mode { case area, window, display }

    struct Selection {
        let screen: NSScreen
        /// Selected area in the screen's local coordinates (points, bottom-left origin).
        let rect: CGRect
    }

    private var windows: [SelectionOverlayWindow] = []
    private var completion: (@MainActor (Selection?) -> Void)?
    private let aspect = AspectChoice.shared

    func begin(mode: Mode, completion: @escaping @MainActor (Selection?) -> Void) {
        if self.completion != nil { finish(nil) }
        self.completion = completion

        let candidateWindows = mode == .window ? WindowList.onScreen() : []
        NSApp.activate()
        let mouse = NSEvent.mouseLocation

        for screen in NSScreen.screens {
            let window = SelectionOverlayWindow(screen: screen)
            let view = SelectionView(frame: CGRect(origin: .zero, size: screen.frame.size),
                                     mode: mode,
                                     screenOrigin: screen.frame.origin,
                                     candidateWindows: candidateWindows,
                                     aspect: aspect)
            view.onConfirm = { [weak self] rect in
                // Deferred so the window isn't torn down mid-event.
                Task { @MainActor [weak self] in self?.finish(Selection(screen: screen, rect: rect)) }
            }
            view.onCancel = { [weak self] in
                Task { @MainActor [weak self] in self?.finish(nil) }
            }
            view.onStartInteraction = { [weak self, weak view] in
                guard let self else { return }
                for other in self.windows {
                    if let otherView = other.contentView as? SelectionView, otherView !== view {
                        otherView.clearSelection()
                    }
                }
            }
            window.contentView = view
            windows.append(window)

            if NSMouseInRect(mouse, screen.frame, false) {
                window.makeKeyAndOrderFront(nil)
                window.makeFirstResponder(view)
                view.hover(atGlobal: mouse)
            } else {
                window.orderFrontRegardless()
            }
        }
        if mode == .area { NSCursor.crosshair.set() } else { NSCursor.pointingHand.set() }
    }

    private func finish(_ selection: Selection?) {
        let completion = self.completion
        self.completion = nil
        for window in windows {
            (window.contentView as? SelectionView)?.tearDown()
            window.orderOut(nil)
        }
        windows.removeAll()
        completion?(selection)
    }
}

// MARK: - Aspect ratio choice (remembered between recordings)

@MainActor
final class AspectChoice: ObservableObject {
    static let shared = AspectChoice()

    enum Preset: String, CaseIterable, Identifiable {
        case free, r16x9, r9x16, r4x3, r3x4, r1x1, r21x9, r4x5, custom
        var id: String { rawValue }

        var label: String {
            switch self {
            case .free: return "Free"
            case .r16x9: return "16:9"
            case .r9x16: return "9:16"
            case .r4x3: return "4:3"
            case .r3x4: return "3:4"
            case .r1x1: return "1:1"
            case .r21x9: return "21:9"
            case .r4x5: return "4:5"
            case .custom: return "Custom"
            }
        }

        var ratio: CGFloat? {
            switch self {
            case .free, .custom: return nil
            case .r16x9: return 16.0 / 9.0
            case .r9x16: return 9.0 / 16.0
            case .r4x3: return 4.0 / 3.0
            case .r3x4: return 3.0 / 4.0
            case .r1x1: return 1
            case .r21x9: return 21.0 / 9.0
            case .r4x5: return 4.0 / 5.0
            }
        }
    }

    private let defaults = UserDefaults.standard

    @Published var preset: Preset { didSet { defaults.set(preset.rawValue, forKey: "areaAspect"); notify() } }
    @Published var customWidth: Double { didSet { defaults.set(customWidth, forKey: "areaAspectW"); notify() } }
    @Published var customHeight: Double { didSet { defaults.set(customHeight, forKey: "areaAspectH"); notify() } }

    /// Width / height, or nil for free.
    var ratio: CGFloat? {
        if preset == .custom {
            guard customWidth > 0, customHeight > 0 else { return nil }
            return CGFloat(customWidth / customHeight)
        }
        return preset.ratio
    }

    private var observers: [UUID: () -> Void] = [:]

    private init() {
        preset = Preset(rawValue: defaults.string(forKey: "areaAspect") ?? "") ?? .free
        let w = defaults.double(forKey: "areaAspectW")
        let h = defaults.double(forKey: "areaAspectH")
        customWidth = w > 0 ? w : 3
        customHeight = h > 0 ? h : 2
    }

    func observe(_ handler: @escaping () -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        return id
    }

    func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    private func notify() {
        for handler in observers.values { handler() }
    }
}

/// The ratio bar shown at the top of the selection overlay.
struct AspectBar: View {
    @ObservedObject var choice: AspectChoice

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "aspectratio")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .padding(.leading, 6)
                .padding(.trailing, 2)
            ForEach(AspectChoice.Preset.allCases) { preset in
                Chip(title: preset.label, isSelected: choice.preset == preset) {
                    choice.preset = preset
                }
            }
            if choice.preset == .custom {
                HStack(spacing: 4) {
                    RatioField(value: $choice.customWidth)
                    Text(":").foregroundStyle(Theme.textSecondary)
                    RatioField(value: $choice.customHeight)
                }
                .padding(.leading, 4)
            }
        }
        .padding(6)
        .background(Capsule().fill(Color(red: 0.09, green: 0.09, blue: 0.11).opacity(0.94)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
        .environment(\.colorScheme, .dark)
        .fixedSize()
    }
}

private struct RatioField: View {
    @Binding var value: Double

    var body: some View {
        TextField("", value: $value, format: .number.precision(.fractionLength(0...2)))
            .textFieldStyle(.plain)
            .multilineTextAlignment(.center)
            .font(.system(size: 12, weight: .medium).monospacedDigit())
            .foregroundStyle(Theme.text)
            .frame(width: 40)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.controlSelected))
    }
}

// MARK: - Window list

enum WindowList {
    /// Frames of normal on-screen windows (front to back) in Cocoa global coordinates.
    static func onScreen() -> [CGRect] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let ownPID = Int(ProcessInfo.processInfo.processIdentifier)
        var rects: [CGRect] = []
        for window in list {
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  (window[kCGWindowOwnerPID as String] as? Int) != ownPID,
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
                  bounds.width >= 60, bounds.height >= 60 else { continue }
            rects.append(CGRect(x: bounds.minX, y: primaryHeight - bounds.maxY, width: bounds.width, height: bounds.height))
        }
        return rects
    }
}

// MARK: - Overlay window

final class SelectionOverlayWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        sharingType = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - Selection view

final class SelectionView: NSView {
    var onConfirm: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?
    var onStartInteraction: (() -> Void)?

    /// Corners and edge midpoints of the selection.
    private enum Handle: CaseIterable {
        case bottomLeft, bottom, bottomRight, right, topRight, top, topLeft, left

        var isCorner: Bool {
            switch self {
            case .bottomLeft, .bottomRight, .topRight, .topLeft: return true
            default: return false
            }
        }

        func point(in rect: CGRect) -> CGPoint {
            switch self {
            case .bottomLeft: return CGPoint(x: rect.minX, y: rect.minY)
            case .bottom: return CGPoint(x: rect.midX, y: rect.minY)
            case .bottomRight: return CGPoint(x: rect.maxX, y: rect.minY)
            case .right: return CGPoint(x: rect.maxX, y: rect.midY)
            case .topRight: return CGPoint(x: rect.maxX, y: rect.maxY)
            case .top: return CGPoint(x: rect.midX, y: rect.maxY)
            case .topLeft: return CGPoint(x: rect.minX, y: rect.maxY)
            case .left: return CGPoint(x: rect.minX, y: rect.midY)
            }
        }

        /// The point that stays fixed while this handle is dragged.
        func anchor(in rect: CGRect) -> CGPoint {
            switch self {
            case .bottomLeft: return CGPoint(x: rect.maxX, y: rect.maxY)
            case .bottom: return CGPoint(x: rect.midX, y: rect.maxY)
            case .bottomRight: return CGPoint(x: rect.minX, y: rect.maxY)
            case .right: return CGPoint(x: rect.minX, y: rect.midY)
            case .topRight: return CGPoint(x: rect.minX, y: rect.minY)
            case .top: return CGPoint(x: rect.midX, y: rect.minY)
            case .topLeft: return CGPoint(x: rect.maxX, y: rect.minY)
            case .left: return CGPoint(x: rect.maxX, y: rect.midY)
            }
        }

        var cursor: NSCursor {
            switch self {
            case .left, .right: return .resizeLeftRight
            case .top, .bottom: return .resizeUpDown
            default: return .crosshair
            }
        }
    }

    private enum DragMode {
        case none
        case drawing(origin: CGPoint)
        case moving(offset: CGSize)
        case resizing(handle: Handle, original: CGRect)
    }

    private let mode: RegionSelector.Mode
    private let screenOrigin: CGPoint
    private let candidateWindows: [CGRect]
    private let aspect: AspectChoice
    private var aspectObserver: UUID?
    private var dragMode: DragMode = .none
    private var selection: CGRect? { didSet { needsDisplay = true } }
    private let recordButton = NSButton(title: "Record", target: nil, action: nil)
    private var aspectBar: NSHostingView<AspectBar>?
    private let minimumSize: CGFloat = 16

    init(frame frameRect: NSRect, mode: RegionSelector.Mode, screenOrigin: CGPoint, candidateWindows: [CGRect], aspect: AspectChoice) {
        self.mode = mode
        self.screenOrigin = screenOrigin
        self.candidateWindows = candidateWindows
        self.aspect = aspect
        super.init(frame: frameRect)

        recordButton.bezelStyle = .push
        recordButton.controlSize = .large
        recordButton.image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: nil)
        recordButton.imagePosition = .imageLeading
        recordButton.contentTintColor = .systemRed
        recordButton.target = self
        recordButton.action = #selector(confirm)
        recordButton.isHidden = true
        addSubview(recordButton)

        if mode == .area {
            let bar = NSHostingView(rootView: AspectBar(choice: aspect))
            addSubview(bar)
            aspectBar = bar
            layoutAspectBar()
            aspectObserver = aspect.observe { [weak self] in
                // Let the published value settle before reading it.
                Task { @MainActor [weak self] in self?.aspectDidChange() }
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func tearDown() {
        if let aspectObserver { aspect.removeObserver(aspectObserver) }
        aspectObserver = nil
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        layoutAspectBar()
    }

    private func layoutAspectBar() {
        guard let bar = aspectBar else { return }
        let size = bar.fittingSize
        // Below the menu bar / notch area.
        let top = bounds.maxY - (window?.screen?.safeAreaInsets.top ?? 0) - 44
        bar.frame = CGRect(x: (bounds.width - size.width) / 2, y: top - size.height, width: size.width, height: size.height)
    }

    func clearSelection() {
        selection = nil
        dragMode = .none
        recordButton.isHidden = true
    }

    /// Window / display modes: highlight what's under the pointer.
    func hover(atGlobal point: CGPoint) {
        switch mode {
        case .area:
            break
        case .display:
            selection = bounds
        case .window:
            if let frame = candidateWindows.first(where: { $0.contains(point) }) {
                let local = frame.offsetBy(dx: -screenOrigin.x, dy: -screenOrigin.y).intersection(bounds)
                selection = local.isNull || local.width < 10 ? nil : local
            } else {
                selection = nil
            }
        }
    }

    // MARK: Aspect ratio

    private var ratio: CGFloat? { mode == .area ? aspect.ratio : nil }

    private func aspectDidChange() {
        layoutAspectBar()
        guard let ratio, let current = selection else { return }
        // Keep roughly the same area and centre, at the new shape.
        let area = current.width * current.height
        var width = sqrt(area * ratio)
        var height = width / ratio
        let fit = min(1, bounds.width / width, bounds.height / height)
        width *= fit
        height *= fit
        var rect = CGRect(x: current.midX - width / 2, y: current.midY - height / 2, width: width, height: height)
        rect.origin.x = clamp(rect.origin.x, 0, bounds.width - width)
        rect.origin.y = clamp(rect.origin.y, 0, bounds.height - height)
        selection = rect
        showRecordButton()
    }

    /// Rectangle from a fixed corner to the pointer, shaped to the ratio and kept on screen.
    private func rect(from anchor: CGPoint, to point: CGPoint) -> CGRect {
        var dx = point.x - anchor.x
        var dy = point.y - anchor.y
        if let ratio {
            let sx: CGFloat = dx < 0 ? -1 : 1
            let sy: CGFloat = dy < 0 ? -1 : 1
            if abs(dx) / ratio >= abs(dy) {
                dy = sy * abs(dx) / ratio
            } else {
                dx = sx * abs(dy) * ratio
            }
            let maxX = dx >= 0 ? bounds.maxX - anchor.x : anchor.x
            let maxY = dy >= 0 ? bounds.maxY - anchor.y : anchor.y
            var scale: CGFloat = 1
            if abs(dx) > maxX { scale = min(scale, maxX / abs(dx)) }
            if abs(dy) > maxY { scale = min(scale, maxY / abs(dy)) }
            dx *= scale
            dy *= scale
        } else {
            dx = clamp(anchor.x + dx, 0, bounds.width) - anchor.x
            dy = clamp(anchor.y + dy, 0, bounds.height) - anchor.y
        }
        return CGRect(x: min(anchor.x, anchor.x + dx), y: min(anchor.y, anchor.y + dy), width: abs(dx), height: abs(dy))
    }

    /// Edge handle: change one dimension; with a ratio, the other follows, centred.
    private func rect(edge handle: Handle, original: CGRect, point: CGPoint) -> CGRect {
        let p = clamped(point)
        var r = original
        switch handle {
        case .left: r = CGRect(x: min(p.x, original.maxX - minimumSize), y: r.minY, width: original.maxX - min(p.x, original.maxX - minimumSize), height: r.height)
        case .right: r.size.width = max(minimumSize, p.x - original.minX)
        case .bottom: r = CGRect(x: r.minX, y: min(p.y, original.maxY - minimumSize), width: r.width, height: original.maxY - min(p.y, original.maxY - minimumSize))
        case .top: r.size.height = max(minimumSize, p.y - original.minY)
        default: break
        }
        guard let ratio else { return r }
        switch handle {
        case .left, .right:
            var width = r.width
            var height = width / ratio
            if height > bounds.height { height = bounds.height; width = height * ratio }
            let x = handle == .left ? original.maxX - width : original.minX
            var y = original.midY - height / 2
            y = clamp(y, 0, bounds.height - height)
            return CGRect(x: max(0, x), y: y, width: width, height: height)
        default:
            var height = r.height
            var width = height * ratio
            if width > bounds.width { width = bounds.width; height = width / ratio }
            let y = handle == .bottom ? original.maxY - height : original.minY
            var x = original.midX - width / 2
            x = clamp(x, 0, bounds.width - width)
            return CGRect(x: x, y: max(0, y), width: width, height: height)
        }
    }

    private func fullScreenRect() -> CGRect {
        guard let ratio else { return bounds }
        var width = bounds.width
        var height = width / ratio
        if height > bounds.height {
            height = bounds.height
            width = height * ratio
        }
        return CGRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2, width: width, height: height)
    }

    // MARK: Hit testing

    private func handle(at point: CGPoint) -> Handle? {
        guard mode == .area, let selection, selection.width > 0 else { return nil }
        let reach: CGFloat = 9
        for handle in Handle.allCases where handle.isCorner {
            let p = handle.point(in: selection)
            if abs(point.x - p.x) <= reach && abs(point.y - p.y) <= reach { return handle }
        }
        for handle in Handle.allCases where !handle.isCorner {
            let p = handle.point(in: selection)
            switch handle {
            case .left, .right:
                if abs(point.x - p.x) <= reach && point.y > selection.minY && point.y < selection.maxY { return handle }
            default:
                if abs(point.y - p.y) <= reach && point.x > selection.minX && point.x < selection.maxX { return handle }
            }
        }
        return nil
    }

    // MARK: Cursor & hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .cursorUpdate, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func cursorUpdate(with event: NSEvent) { updateCursor(at: convert(event.locationInWindow, from: nil)) }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if mode != .area {
            hover(atGlobal: CGPoint(x: point.x + screenOrigin.x, y: point.y + screenOrigin.y))
        }
        updateCursor(at: point)
    }

    override func mouseExited(with event: NSEvent) {
        if mode != .area { selection = nil }
    }

    private func updateCursor(at point: CGPoint) {
        if mode != .area {
            NSCursor.pointingHand.set()
        } else if let bar = aspectBar, bar.frame.contains(point) {
            NSCursor.arrow.set()
        } else if !recordButton.isHidden, recordButton.frame.contains(point) {
            NSCursor.arrow.set()
        } else if let handle = handle(at: point) {
            handle.cursor.set()
        } else if let selection, selection.contains(point) {
            NSCursor.openHand.set()
        } else {
            NSCursor.crosshair.set()
        }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(self)

        if mode != .area {
            hover(atGlobal: CGPoint(x: point.x + screenOrigin.x, y: point.y + screenOrigin.y))
            if selection != nil { confirm() }
            return
        }

        onStartInteraction?()
        if event.clickCount == 2, let selection, selection.contains(point) {
            confirm()
            return
        }
        recordButton.isHidden = true
        if let handle = handle(at: point), let selection {
            dragMode = .resizing(handle: handle, original: selection)
        } else if let selection, selection.contains(point) {
            dragMode = .moving(offset: CGSize(width: point.x - selection.minX, height: point.y - selection.minY))
            NSCursor.closedHand.set()
        } else {
            dragMode = .drawing(origin: clamped(point))
            selection = nil
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard mode == .area else { return }
        let point = clamped(convert(event.locationInWindow, from: nil))
        switch dragMode {
        case .drawing(let origin):
            selection = rect(from: origin, to: point)
        case .moving(let offset):
            guard var rect = selection else { return }
            rect.origin = CGPoint(x: min(max(0, point.x - offset.width), bounds.width - rect.width),
                                  y: min(max(0, point.y - offset.height), bounds.height - rect.height))
            selection = rect
        case .resizing(let handle, let original):
            if handle.isCorner {
                selection = rect(from: handle.anchor(in: original), to: point)
            } else {
                selection = rect(edge: handle, original: original, point: point)
            }
        case .none:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard mode == .area else { return }
        dragMode = .none
        if let selection, selection.width >= 10, selection.height >= 10 {
            showRecordButton()
        } else {
            selection = nil
        }
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Esc
            onCancel?()
        case 36, 76: // Return, Enter
            if selection != nil { confirm() }
        default:
            if mode == .area, event.charactersIgnoringModifiers?.lowercased() == "f" {
                onStartInteraction?()
                selection = fullScreenRect()
                showRecordButton()
            } else {
                super.keyDown(with: event)
            }
        }
    }

    @objc private func confirm() {
        guard let selection else { return }
        onConfirm?(selection.integral.intersection(bounds))
    }

    // MARK: Layout & drawing

    private func showRecordButton() {
        guard let selection else { return }
        recordButton.sizeToFit()
        var frame = recordButton.frame
        frame.size.width += 16
        frame.origin.x = min(max(8, selection.midX - frame.width / 2), bounds.width - frame.width - 8)
        frame.origin.y = selection.minY - frame.height - 14
        if frame.minY < 8 { frame.origin.y = selection.minY + 16 } // no room below: sit inside
        recordButton.frame = frame
        recordButton.isHidden = false
    }

    private func clamped(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(0, p.x), bounds.width), y: min(max(0, p.y), bounds.height))
    }

    private var hint: String {
        switch mode {
        case .area: return "Drag to select an area   ·   F for full screen   ·   Esc to cancel"
        case .window: return "Click a window to record it   ·   Esc to cancel"
        case .display: return "Click to record this display   ·   Esc to cancel"
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()

        guard let selection else {
            let size = pillSize(hint)
            drawPill(hint, at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
            return
        }

        // Punch the selected area out of the dim layer.
        NSColor.clear.setFill()
        selection.fill(using: .copy)

        NSColor.white.withAlphaComponent(0.9).setStroke()
        let outline = NSBezierPath(rect: selection.insetBy(dx: -0.5, dy: -0.5))
        outline.lineWidth = mode == .area ? 1 : 3
        outline.stroke()

        if mode == .area {
            // Thirds grid while adjusting, to help framing.
            if case .none = dragMode {} else {
                NSColor.white.withAlphaComponent(0.22).setStroke()
                let grid = NSBezierPath()
                for i in 1...2 {
                    let x = selection.minX + selection.width * CGFloat(i) / 3
                    let y = selection.minY + selection.height * CGFloat(i) / 3
                    grid.move(to: CGPoint(x: x, y: selection.minY)); grid.line(to: CGPoint(x: x, y: selection.maxY))
                    grid.move(to: CGPoint(x: selection.minX, y: y)); grid.line(to: CGPoint(x: selection.maxX, y: y))
                }
                grid.lineWidth = 1
                grid.stroke()
            }
            // Resize handles.
            for handle in Handle.allCases {
                let p = handle.point(in: selection)
                let size: CGFloat = handle.isCorner ? 9 : 7
                let dot = NSBezierPath(roundedRect: CGRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size),
                                       xRadius: 2, yRadius: 2)
                NSColor.white.setFill()
                dot.fill()
                NSColor.black.withAlphaComponent(0.35).setStroke()
                dot.lineWidth = 1
                dot.stroke()
            }
        }

        // Pixel size (and ratio) above the top-left corner, or inside if there's no room.
        let scale = window?.backingScaleFactor ?? 2
        var label = "\(Int((selection.width * scale).rounded())) × \(Int((selection.height * scale).rounded()))"
        if mode == .area, aspect.preset != .free { label += "   ·   \(aspectLabel)" }
        if mode != .area { label = "Click to record   ·   " + label }
        let size = pillSize(label)
        var origin = CGPoint(x: selection.minX, y: selection.maxY + 8)
        if origin.y + size.height > bounds.maxY - 4 {
            origin = CGPoint(x: selection.minX + 8, y: selection.maxY - size.height - 8)
        }
        origin.x = min(max(4, origin.x), bounds.width - size.width - 4)
        drawPill(label, at: origin)
    }

    private var aspectLabel: String {
        if aspect.preset == .custom {
            let format = NumberFormatter()
            format.maximumFractionDigits = 2
            let w = format.string(from: NSNumber(value: aspect.customWidth)) ?? "?"
            let h = format.string(from: NSNumber(value: aspect.customHeight)) ?? "?"
            return "\(w):\(h)"
        }
        return aspect.preset.label
    }

    private func attributed(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ])
    }

    private func pillSize(_ text: String) -> CGSize {
        let size = attributed(text).size()
        return CGSize(width: ceil(size.width) + 16, height: ceil(size.height) + 8)
    }

    private func drawPill(_ text: String, at origin: CGPoint) {
        let rect = CGRect(origin: origin, size: pillSize(text))
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
        attributed(text).draw(at: CGPoint(x: rect.minX + 8, y: rect.minY + 4))
    }
}

// MARK: - Recording border

/// Dashed outline drawn just outside the recorded area while recording.
/// It sits outside the capture rect and Oneshot is excluded from capture, so it never appears in the video.
final class RecordingBorderWindow: NSWindow {
    init(around globalRect: CGRect) {
        let frame = globalRect.insetBy(dx: -4, dy: -4)
        super.init(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        setFrame(frame, display: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .screenSaver
        isReleasedWhenClosed = false
        sharingType = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        contentView = BorderView(frame: CGRect(origin: .zero, size: frame.size))
    }

    private final class BorderView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(rect: bounds.insetBy(dx: 2, dy: 2))
            path.lineWidth = 2
            let dash: [CGFloat] = [6, 4]
            path.setLineDash(dash, count: dash.count, phase: 0)
            NSColor.systemRed.withAlphaComponent(0.9).setStroke()
            path.stroke()
        }
    }
}
