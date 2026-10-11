import AppKit

/// 3, 2, 1 shown over the middle of the area about to be recorded.
@MainActor
enum Countdown {
    static func run(in globalRect: CGRect, seconds: Int = 3) async {
        let size: CGFloat = 132
        let frame = CGRect(x: globalRect.midX - size / 2, y: globalRect.midY - size / 2, width: size, height: size)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.setFrame(frame, display: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .screenSaver
        window.isReleasedWhenClosed = false
        window.sharingType = .none
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let view = CountdownView(frame: CGRect(origin: .zero, size: frame.size))
        window.contentView = view
        window.orderFrontRegardless()

        for number in stride(from: seconds, through: 1, by: -1) {
            view.number = number
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        window.orderOut(nil)
    }
}

final class CountdownView: NSView {
    var number = 3 { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 2, dy: 2)).fill()
        let text = NSAttributedString(string: "\(number)", attributes: [
            .font: NSFont.systemFont(ofSize: 64, weight: .semibold),
            .foregroundColor: NSColor.white,
        ])
        let size = text.size()
        text.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }
}
