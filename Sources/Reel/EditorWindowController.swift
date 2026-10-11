import AppKit
import SwiftUI

@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    let model: EditorModel
    var onClose: ((EditorWindowController) -> Void)?
    private var keyMonitor: Any?

    init(project: ProjectFolder) throws {
        let model = try EditorModel(project: project)
        self.model = model

        let hosting = NSHostingController(rootView: EditorView(model: model))
        hosting.sizingOptions = [.minSize]

        let window = NSWindow(contentViewController: hosting)
        window.title = project.displayName
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 1320, height: 840))
        window.center()
        window.setFrameAutosaveName("ReelEditor")

        super.init(window: window)
        window.delegate = self

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

    func windowWillClose(_ notification: Notification) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        model.teardown()
        onClose?(self)
    }
}
