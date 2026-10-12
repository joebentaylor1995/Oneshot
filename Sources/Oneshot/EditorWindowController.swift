import AppKit
import SwiftUI

@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    let model: EditorModel
    var onClose: ((EditorWindowController) -> Void)?
    private var keyMonitor: Any?
    /// Set when Oneshot closes editors to install an update: drafts survive that.
    var keepsDraftOnClose = false

    init(project: ProjectFolder) throws {
        let model = try EditorModel(project: project)
        self.model = model

        let hosting = NSHostingController(rootView: EditorView(model: model))
        hosting.sizingOptions = [.minSize]

        let window = NSWindow(contentViewController: hosting)
        window.title = project.displayName
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        // Dark, chrome-less window with the traffic lights sitting in our own top bar.
        // An empty unified toolbar makes the title bar tall enough to centre them.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbar = NSToolbar(identifier: "OneshotEditor")
        window.toolbarStyle = .unified
        window.appearance = NSAppearance(named: .darkAqua)
        // Glass: the SwiftUI WindowGlass background shows the blurred desktop through.
        window.isOpaque = false
        window.backgroundColor = .clear
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 1320, height: 840))
        window.center()
        window.setFrameAutosaveName("OneshotEditor")

        super.init(window: window)
        window.delegate = self
        updateChromeMetrics()

        // Editor shortcuts are handled here, before any focused control sees the key,
        // so Space always plays/pauses (instead of pressing whichever button has focus).
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handleKey(event) ?? false }
            return handled ? nil : event
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Space play/pause · ←/→ step a frame · Z zoom · C cut · S speed · ⌫ delete selected.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard let window, event.window === window, window.attachedSheet == nil else { return false }
        // Let text fields (e.g. a colour hex field) receive their keys.
        if let textView = window.firstResponder as? NSTextView, textView.isEditable { return false }

        let modifiers = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])

        // ⌘S saves (names) the recording.
        if event.charactersIgnoringModifiers?.lowercased() == "s", modifiers == [.command] {
            model.showingSavePrompt = true
            return true
        }
        // ⌘Z / ⇧⌘Z (Oneshot has no main menu, so handle them here).
        if event.charactersIgnoringModifiers?.lowercased() == "z" {
            if modifiers == [.command] { model.undo(); return true }
            if modifiers == [.command, .shift] { model.redo(); return true }
        }
        guard modifiers.isEmpty else { return false }

        switch event.keyCode {
        case 49: // Space
            model.togglePlayback()
        case 123: // ←
            model.step(frames: -1)
        case 124: // →
            model.step(frames: 1)
        case 51, 117: // Delete, Forward Delete
            guard model.selection != nil else { return false }
            model.deleteSelection()
        default:
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "z": model.addZoomAtPlayhead()
            case "c": model.addCutAtPlayhead()
            case "s": model.addSpeedAtPlayhead()
            default: return false
            }
        }
        return true
    }

    func windowDidResize(_ notification: Notification) { updateChromeMetrics() }
    func windowDidBecomeKey(_ notification: Notification) { updateChromeMetrics() }
    func windowDidEnterFullScreen(_ notification: Notification) { updateChromeMetrics() }
    func windowDidExitFullScreen(_ notification: Notification) { updateChromeMetrics() }

    /// Lines the SwiftUI top bar up with the native close/minimise/zoom buttons: same vertical
    /// centre, starting just after the zoom button. Measured, because the title bar height
    /// differs between macOS versions.
    func updateChromeMetrics() {
        guard let window,
              !window.styleMask.contains(.fullScreen),
              let close = window.standardWindowButton(.closeButton),
              let zoom = window.standardWindowButton(.zoomButton),
              close.superview != nil else {
            model.chrome = .init(height: 52, leading: 16)
            return
        }
        let closeRect = close.convert(close.bounds, to: nil)
        let zoomRect = zoom.convert(zoom.bounds, to: nil)
        let centreFromTop = window.frame.height - closeRect.midY
        let metrics = EditorModel.WindowChrome(height: max(32, (centreFromTop * 2).rounded()),
                                               leading: (zoomRect.maxX + 12).rounded())
        if model.chrome != metrics { model.chrome = metrics }
    }

    /// Unsaved, unexported recordings are moved to the Trash when their editor closes.
    func discardIfDraft() {
        guard !keepsDraftOnClose else { return }
        model.project.discardIfDraft()
    }

    func windowWillClose(_ notification: Notification) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        model.teardown()
        discardIfDraft()
        onClose?(self)
    }
}
