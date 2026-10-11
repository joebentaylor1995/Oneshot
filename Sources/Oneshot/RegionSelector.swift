import AppKit

/// Full-screen dimmed overlay on every display.
/// - area: drag to draw, drag inside to move, then Return / double-click / Record. F = whole screen.
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
                                     candidateWindows: candidateWindows)
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
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        completion?(selection)
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

    private enum DragMode {
        case none
        case drawing(origin: CGPoint)
        case moving(offset: CGSize)
    }

    private let mode: RegionSelector.Mode
    private let screenOrigin: CGPoint
    private let candidateWindows: [CGRect]
    private var dragMode: DragMode = .none
    private var selection: CGRect? { didSet { needsDisplay = true } }
    private let recordButton = NSButton(title: "Record", target: nil, action: nil)

    init(frame frameRect: NSRect, mode: RegionSelector.Mode, screenOrigin: CGPoint, candidateWindows: [CGRect]) {
        self.mode = mode
        self.screenOrigin = screenOrigin
        self.candidateWindows = candidateWindows
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
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

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
        } else if !recordButton.isHidden, recordButton.frame.contains(point) {
            NSCursor.arrow.set()
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
        if let selection, selection.contains(point) {
            dragMode = .moving(offset: CGSize(width: point.x - selection.minX, height: point.y - selection.minY))
            NSCursor.closedHand.set()
        } else {
            dragMode = .drawing(origin: point)
            selection = nil
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard mode == .area else { return }
        let point = clamped(convert(event.locationInWindow, from: nil))
        switch dragMode {
        case .drawing(let origin):
            selection = CGRect(x: min(origin.x, point.x), y: min(origin.y, point.y),
                               width: abs(point.x - origin.x), height: abs(point.y - origin.y))
        case .moving(let offset):
            guard var rect = selection else { return }
            rect.origin = CGPoint(x: min(max(0, point.x - offset.width), bounds.width - rect.width),
                                  y: min(max(0, point.y - offset.height), bounds.height - rect.height))
            selection = rect
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
                selection = bounds
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
        frame.origin.y = selection.minY - frame.height - 12
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

        // Pixel size label above the top-left corner (or inside if there's no room).
        let scale = window?.backingScaleFactor ?? 2
        var label = "\(Int((selection.width * scale).rounded())) × \(Int((selection.height * scale).rounded()))"
        if mode != .area { label = "Click to record   ·   " + label }
        let size = pillSize(label)
        var origin = CGPoint(x: selection.minX, y: selection.maxY + 6)
        if origin.y + size.height > bounds.maxY - 4 {
            origin = CGPoint(x: selection.minX + 6, y: selection.maxY - size.height - 6)
        }
        origin.x = min(max(4, origin.x), bounds.width - size.width - 4)
        drawPill(label, at: origin)
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
