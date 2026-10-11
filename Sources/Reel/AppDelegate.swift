import AppKit
import AVFoundation
import Carbon.HIToolbox
import ScreenCaptureKit

/// Owns the menu bar item. States: idle (menu), recording (click to stop, shows elapsed time), saving.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private struct Session {
        let project: ProjectFolder
        let recorder: ScreenRecorder
        let sampler: CursorSampler
        let shapes: CursorShapeRecorder
        let store: CursorTrackStore
        let scale: Double
        let createdAt: Date
    }

    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let regionSelector = RegionSelector()
    private var session: Session?
    private var isStarting = false
    private var borderWindow: RecordingBorderWindow?
    private var recordingStartedAt: Date?
    private var tickTimer: Timer?
    private var editors: [EditorWindowController] = []
    private var hotKey: HotKey?
    private var hasRequestedScreenAccess = false

    // MARK: Preferences

    private let defaults = UserDefaults.standard

    private var recordSystemAudio: Bool {
        get { defaults.object(forKey: "systemAudio") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "systemAudio") }
    }

    /// nil = no microphone.
    private var microphoneID: String? {
        get { defaults.string(forKey: "microphoneID") }
        set { defaults.set(newValue, forKey: "microphoneID") }
    }

    private var useCountdown: Bool {
        get { defaults.object(forKey: "countdown") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "countdown") }
    }

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.delegate = self
        showIdleState()

        // ⌘⇧2 starts an area recording, or stops the current one.
        hotKey = HotKey(keyCode: kVK_ANSI_2, modifiers: cmdKey | shiftKey) { [weak self] in
            self?.hotKeyPressed()
        }
    }

    private func hotKeyPressed() {
        if session != nil {
            stopRecording()
        } else {
            beginSelection(.area)
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let area = item("Record Area…", #selector(recordArea))
        area.keyEquivalent = "2"
        area.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(area)
        menu.addItem(item("Record Window…", #selector(recordWindow)))
        menu.addItem(item("Record Display…", #selector(recordDisplay)))
        menu.addItem(.separator())

        // Microphone
        let micItem = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        let micMenu = NSMenu()
        let none = item("None", #selector(selectMicrophone(_:)))
        none.state = microphoneID == nil ? .on : .off
        micMenu.addItem(none)
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external],
                                                       mediaType: .audio,
                                                       position: .unspecified).devices
        if !devices.isEmpty { micMenu.addItem(.separator()) }
        for device in devices {
            let deviceItem = item(device.localizedName, #selector(selectMicrophone(_:)))
            deviceItem.representedObject = device.uniqueID
            deviceItem.state = device.uniqueID == microphoneID ? .on : .off
            micMenu.addItem(deviceItem)
        }
        micItem.submenu = micMenu
        menu.addItem(micItem)

        let system = item("Record System Audio", #selector(toggleSystemAudio))
        system.state = recordSystemAudio ? .on : .off
        menu.addItem(system)

        let countdown = item("Countdown", #selector(toggleCountdown))
        countdown.state = useCountdown ? .on : .off
        menu.addItem(countdown)
        menu.addItem(.separator())

        // Projects
        let recentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu()
        let recents = ProjectFolder.recent()
        if recents.isEmpty {
            let empty = NSMenuItem(title: "No Recordings Yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            recentMenu.addItem(empty)
        }
        for project in recents {
            let projectItem = item(project.displayName, #selector(openRecent(_:)))
            projectItem.representedObject = project.url
            recentMenu.addItem(projectItem)
        }
        recentItem.submenu = recentMenu
        menu.addItem(recentItem)
        menu.addItem(item("Open Reel Folder", #selector(openFolder)))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Reel", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func recordArea() { beginSelection(.area) }
    @objc private func recordWindow() { beginSelection(.window) }
    @objc private func recordDisplay() { beginSelection(.display) }
    @objc private func selectMicrophone(_ sender: NSMenuItem) { microphoneID = sender.representedObject as? String }
    @objc private func toggleSystemAudio() { recordSystemAudio.toggle() }
    @objc private func toggleCountdown() { useCountdown.toggle() }
    @objc private func openFolder() { NSWorkspace.shared.open(Paths.root) }

    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        openEditor(for: ProjectFolder(url: url))
    }

    // MARK: Status item states

    private func showIdleState() {
        tickTimer?.invalidate()
        tickTimer = nil
        recordingStartedAt = nil
        guard let button = statusItem.button else { return }
        let image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Reel")
        image?.isTemplate = true
        button.image = image
        button.title = ""
        button.imagePosition = .imageOnly
        button.toolTip = "Reel (⌘⇧2 to record)"
        button.action = nil
        statusItem.menu = menu
    }

    private func showRecordingState() {
        guard let button = statusItem.button else { return }
        statusItem.menu = nil // a click now fires the stop action instead of opening the menu

        let config = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
        let image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "Stop recording")?
            .withSymbolConfiguration(config)
        image?.isTemplate = false
        button.image = image
        button.imagePosition = .imageLeading
        button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        button.title = " 0:00"
        button.toolTip = "Click (or ⌘⇧2) to stop recording"
        button.target = self
        button.action = #selector(stopRecording)

        recordingStartedAt = Date()
        tickTimer?.invalidate()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateElapsed() }
        }
    }

    private func updateElapsed() {
        guard let start = recordingStartedAt else { return }
        let seconds = Int(Date().timeIntervalSince(start))
        statusItem.button?.title = String(format: " %d:%02d", seconds / 60, seconds % 60)
    }

    private func showSavingState() {
        tickTimer?.invalidate()
        tickTimer = nil
        guard let button = statusItem.button else { return }
        button.action = nil
        button.title = ""
        button.imagePosition = .imageOnly
        let image = NSImage(systemSymbolName: "hourglass", accessibilityDescription: "Saving")
        image?.isTemplate = true
        button.image = image
    }

    // MARK: Recording

    private func beginSelection(_ mode: RegionSelector.Mode) {
        guard session == nil, !isStarting else { return }
        if !CGPreflightScreenCaptureAccess() {
            // Ask macOS once per launch. After that, a newly granted permission only takes
            // effect once Reel restarts, so offer to do that instead of asking again.
            if !hasRequestedScreenAccess {
                hasRequestedScreenAccess = true
                if CGRequestScreenCaptureAccess() { return beginSelection(mode) }
            }
            showPermissionAlert()
            return
        }
        regionSelector.begin(mode: mode) { [weak self] selection in
            guard let self, let selection else { return }
            Task { await self.startRecording(selection) }
        }
    }

    private func startRecording(_ selection: RegionSelector.Selection) async {
        isStarting = true
        defer { isStarting = false }

        let screen = selection.screen
        let rect = selection.rect.integral
        let globalRect = rect.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)

        var microphone: AVCaptureDevice?
        if let id = microphoneID, await AVCaptureDevice.requestAccess(for: .audio) {
            microphone = AVCaptureDevice(uniqueID: id)
        }

        let border = RecordingBorderWindow(around: globalRect)
        border.orderFrontRegardless()
        borderWindow = border

        do {
            if useCountdown {
                await Countdown.run(in: globalRect)
            } else {
                try await Task.sleep(nanoseconds: 120_000_000) // let the selection overlay leave the screen
            }

            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else {
                throw ReelError.displayNotFound
            }
            let ownApp = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }

            // ScreenCaptureKit wants display-local points with a top-left origin.
            let sourceRect = CGRect(x: rect.minX, y: screen.frame.height - rect.maxY, width: rect.width, height: rect.height)
            let displayBounds = CGDisplayBounds(display.displayID)
            let quartzRegion = sourceRect.offsetBy(dx: displayBounds.minX, dy: displayBounds.minY)

            let project = try ProjectFolder.create()
            let store = CursorTrackStore()
            let sampler = CursorSampler(region: quartzRegion, store: store)
            let shapes = CursorShapeRecorder(store: store, directory: project.cursorsURL)
            let recorder = ScreenRecorder(outputURL: project.videoURL)
            recorder.onUnexpectedStop = { [weak self] in self?.stopRecording() }

            sampler.start()
            shapes.start()
            do {
                try await recorder.start(display: display,
                                         excluding: ownApp,
                                         sourceRect: sourceRect,
                                         scale: screen.backingScaleFactor,
                                         systemAudio: recordSystemAudio,
                                         microphone: microphone)
            } catch {
                sampler.stop()
                shapes.stop()
                try? FileManager.default.removeItem(at: project.url)
                throw error
            }

            session = Session(project: project, recorder: recorder, sampler: sampler, shapes: shapes,
                              store: store, scale: Double(screen.backingScaleFactor), createdAt: Date())
            showRecordingState()
        } catch {
            borderWindow?.orderOut(nil)
            borderWindow = nil
            present(error)
        }
    }

    @objc private func stopRecording() {
        guard let session else { return }
        self.session = nil
        borderWindow?.orderOut(nil)
        borderWindow = nil
        showSavingState()
        session.sampler.stop()
        session.shapes.stop()

        Task {
            do {
                let result = try await session.recorder.stop()
                let track = session.store.snapshot().shifted(by: result.firstFrameTime)
                let info = RecordingInfo(pixelWidth: Int(session.recorder.pixelSize.width),
                                         pixelHeight: Int(session.recorder.pixelSize.height),
                                         scale: session.scale,
                                         hasSystemAudio: session.recorder.hasSystemAudio,
                                         hasMicrophone: session.recorder.hasMicrophone,
                                         duration: max(0.1, result.endTime - result.firstFrameTime),
                                         createdAt: session.createdAt)
                try session.project.save(info, to: session.project.infoURL)
                try session.project.save(track, to: session.project.cursorURL)
                showIdleState()
                openEditor(for: session.project)
            } catch {
                showIdleState()
                present(error)
            }
        }
    }

    // MARK: Windows & helpers

    private func openEditor(for project: ProjectFolder) {
        if let existing = editors.first(where: { $0.model.project == project }) {
            NSApp.activate()
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        do {
            let controller = try EditorWindowController(project: project)
            controller.onClose = { [weak self] closed in
                self?.editors.removeAll { $0 === closed }
            }
            editors.append(controller)
            controller.showWindow(nil)
            NSApp.activate()
            controller.window?.makeKeyAndOrderFront(nil)
        } catch {
            present(error)
        }
    }

    private func present(_ error: Error) {
        NSApp.activate()
        NSAlert(error: error).runModal()
    }

    private func showPermissionAlert() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Reel needs Screen Recording permission"
        alert.informativeText = "Turn on Reel in System Settings › Privacy & Security › Screen & System Audio Recording, then choose Quit & Reopen here."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Quit & Reopen")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        case .alertSecondButtonReturn:
            relaunch()
        default:
            break
        }
    }

    /// Starts a fresh copy of Reel a moment after this one quits.
    private func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.6; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }

}
