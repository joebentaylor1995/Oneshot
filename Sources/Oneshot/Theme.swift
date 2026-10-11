import AppKit
import SwiftUI

/// Dark editor look modelled on Screen Studio: near-black window, slightly lifted cards,
/// a violet accent, pill-shaped option chips, an amber clip track and an indigo zoom track.
enum Theme {
    static let accent = Color(red: 0.42, green: 0.35, blue: 0.98)          // #6B59FA
    static let accentSoft = Color(red: 0.62, green: 0.57, blue: 1.0)       // slider knobs, icons
    static let window = Color(red: 0.071, green: 0.071, blue: 0.086)       // #121216
    static let nsWindow = NSColor(red: 0.071, green: 0.071, blue: 0.086, alpha: 1)
    static let card = Color(red: 0.11, green: 0.105, blue: 0.13)           // #1C1B21
    static let cardTop = Color(red: 0.13, green: 0.12, blue: 0.15)
    static let hairline = Color.white.opacity(0.07)
    static let control = Color.white.opacity(0.05)
    static let controlHover = Color.white.opacity(0.08)
    static let controlSelected = Color.white.opacity(0.11)
    static let text = Color.white.opacity(0.92)
    static let textSecondary = Color.white.opacity(0.52)
    static let textTertiary = Color.white.opacity(0.32)

    static let clipTop = Color(red: 0.70, green: 0.47, blue: 0.13)
    static let clipBottom = Color(red: 0.80, green: 0.55, blue: 0.17)
    static let zoomTrack = Color(red: 0.10, green: 0.095, blue: 0.19)
    static let zoomTop = Color(red: 0.47, green: 0.40, blue: 0.98)
    static let zoomBottom = Color(red: 0.37, green: 0.30, blue: 0.88)

    static var clip: LinearGradient {
        LinearGradient(colors: [clipTop, clipBottom], startPoint: .top, endPoint: .bottom)
    }

    static var zoom: LinearGradient {
        LinearGradient(colors: [zoomTop, zoomBottom], startPoint: .top, endPoint: .bottom)
    }

    static var cardFill: LinearGradient {
        LinearGradient(colors: [cardTop, card], startPoint: .top, endPoint: .bottom)
    }
}

// MARK: - Building blocks

/// Titled block inside an inspector card.
struct InspectorSection<Content: View>: View {
    let title: String
    var trailing: AnyView?
    @ViewBuilder let content: Content

    init(_ title: String, trailing: AnyView? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = trailing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.text)
                Spacer()
                if let trailing { trailing }
            }
            content
        }
    }
}

struct InspectorDivider: View {
    var body: some View {
        Rectangle().fill(Theme.hairline).frame(height: 1).padding(.vertical, 6)
    }
}

/// Row of pill buttons, one selected (Screen Studio's segmented style).
struct ChipPicker<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 6) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                Chip(title: option.1, isSelected: option.0 == selection) {
                    selection = option.0
                }
            }
        }
    }
}

struct Chip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isSelected ? Theme.text : Theme.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(isSelected ? Theme.controlSelected : (hovering ? Theme.controlHover : Theme.control))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(Color.white.opacity(isSelected ? 0.14 : 0), lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Small grey text button, e.g. "Reset".
struct QuietButton: View {
    let title: String
    var enabled = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(enabled ? Theme.text : Theme.textTertiary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6).fill(hovering && enabled ? Theme.controlHover : Theme.control))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
    }
}

/// Slider with the accent tint and an optional Reset button, like Screen Studio's.
struct ThemedSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var defaultValue: Double?

    var body: some View {
        HStack(spacing: 10) {
            Slider(value: $value, in: range)
                .controlSize(.small)
                .tint(Theme.accentSoft)
            if let defaultValue {
                QuietButton(title: "Reset", enabled: abs(value - defaultValue) > 0.0001) {
                    value = defaultValue
                }
            }
        }
    }
}

struct ThemedToggleRow: View {
    let title: String
    var subtitle: String?
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.text)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(Theme.accent)
                .labelsHidden()
        }
    }
}

/// Borderless icon button with a soft hover background.
struct IconButton: View {
    let systemName: String
    var help: String = ""
    var size: CGFloat = 14
    var isActive = false
    var enabled = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(enabled ? (isActive ? Theme.accentSoft : Theme.text) : Theme.textTertiary)
                .frame(width: 30, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(isActive ? Theme.controlSelected : (hovering && enabled ? Theme.controlHover : .clear))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
        .onHover { hovering = $0 }
    }
}

/// Filled accent button (Export).
struct AccentButton: View {
    let title: String
    var systemImage: String?
    var enabled = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 12, weight: .semibold)) }
                Text(title).font(.system(size: 12.5, weight: .semibold))
            }
            .foregroundStyle(.white.opacity(enabled ? 1 : 0.5))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accent.opacity(enabled ? (hovering ? 0.9 : 1) : 0.4)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
    }
}

/// Lets an area of SwiftUI content drag the window (used for the custom title bar).
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                window?.performZoom(nil)
            } else {
                window?.performDrag(with: event)
            }
        }
    }

    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
