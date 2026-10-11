import SwiftUI

/// Screen Studio style timeline, in recording (source) time:
///  - ruler with second labels and half-step dots (click or drag to scrub)
///  - amber Clip track: the trimmed recording, with cuts drawn as dark gaps and
///    speed-ups as labelled bands inside it; drag the clip's ends to trim
///  - indigo Zoom track: click empty space to add a zoom at that point
/// Segments: drag the body to move, the edges to resize, click to select.
///
/// Drags that move or resize the view being dragged measure in window coordinates: measured locally,
/// the view's own movement is subtracted from the drag, so edges lag behind the pointer and jitter.
struct EditorTimeline: View {
    @ObservedObject var model: EditorModel
    private let inset: CGFloat = 16
    private let rulerHeight: CGFloat = 26
    private let clipHeight: CGFloat = 38
    private let zoomHeight: CGFloat = 36

    var body: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width - inset * 2)
            let pps = width / CGFloat(max(model.sourceDuration, 0.01))

            VStack(alignment: .leading, spacing: 8) {
                ruler(pps: pps)
                    .frame(width: width, height: rulerHeight)
                clipTrack(width: width, pps: pps)
                    .frame(width: width, height: clipHeight)
                zoomTrack(width: width, pps: pps)
                    .frame(width: width, height: zoomHeight)
            }
            .padding(.horizontal, inset)
            .padding(.top, 4)
            .overlay(alignment: .topLeading) {
                PlayheadLine(clock: model.clock, x0: inset, pps: pps, height: geo.size.height - 12)
            }
        }
    }

    // MARK: Ruler

    private func ruler(pps: CGFloat) -> some View {
        let steps: [Double] = [0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300]
        let step = steps.first { CGFloat($0) * pps >= 90 } ?? 600
        let duration = model.sourceDuration
        return Canvas { context, size in
            var t = 0.0
            var index = 0
            while t <= duration + 0.0001 {
                let x = CGFloat(t) * pps
                if index > 0 {
                    context.draw(Text(formatShortTime(t)).font(.system(size: 10.5, weight: .medium)).foregroundColor(Theme.textSecondary),
                                 at: CGPoint(x: x, y: 6), anchor: .top)
                    let tick = Path(ellipseIn: CGRect(x: x - 1, y: size.height - 5, width: 2, height: 2))
                    context.fill(tick, with: .color(Theme.textTertiary))
                }
                let half = x + CGFloat(step / 2) * pps
                if CGFloat(duration) * pps >= half {
                    let dot = Path(ellipseIn: CGRect(x: half - 1, y: size.height - 5, width: 2, height: 2))
                    context.fill(dot, with: .color(Theme.textTertiary))
                }
                t += step
                index += 1
            }
        }
        .contentShape(Rectangle())
        .gesture(scrubGesture(pps: pps))
    }

    private func scrubGesture(pps: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                model.scrub(toSource: Double(value.location.x / pps))
            }
    }

    // MARK: Clip track

    private func clipTrack(width: CGFloat, pps: CGFloat) -> some View {
        let startX = CGFloat(model.edits.trimStart) * pps
        let endX = CGFloat(model.trimEnd) * pps
        let clipWidth = max(12, endX - startX)
        return ZStack(alignment: .topLeading) {
            // Trimmed-away parts stay visible as an empty lane so they can be dragged back.
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.03))
                .contentShape(Rectangle())
                .gesture(scrubGesture(pps: pps))

            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Theme.clip)
                RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                VStack(spacing: 1) {
                    Text("Clip")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                    HStack(spacing: 4) {
                        Text(String(format: "%.0fs", model.outputDuration.rounded()))
                        Image(systemName: "timer").font(.system(size: 9, weight: .semibold))
                        Text(speedSummary)
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                }
                .allowsHitTesting(false)
                .opacity(clipWidth > 90 ? 1 : 0)
            }
            .frame(width: clipWidth, height: clipHeight)
            .offset(x: startX)
            .contentShape(Rectangle())
            .gesture(scrubGesture(pps: pps).onEnded { _ in model.select(nil) })

            ForEach(model.edits.speeds) { speed in
                SegmentBar(start: speed.start, end: speed.end, pps: pps, limit: model.sourceDuration,
                           fill: AnyShapeStyle(Color.black.opacity(0.28)),
                           stroke: Color.white.opacity(0.35),
                           label: String(format: "%g×", speed.rate), icon: "hare",
                           isSelected: model.selection == .speed(speed.id),
                           onSelect: { model.select(.speed(speed.id)) },
                           onChange: { start, end in model.updateTiming(\.speeds, id: speed.id, start: start, end: end) })
                    .frame(height: clipHeight)
                    .offset(x: CGFloat(speed.start) * pps)
            }

            ForEach(model.edits.cuts) { cut in
                SegmentBar(start: cut.start, end: cut.end, pps: pps, limit: model.sourceDuration,
                           fill: CutHatch.style,
                           stroke: Color.white.opacity(0.25),
                           label: "Cut", icon: "scissors",
                           isSelected: model.selection == .cut(cut.id),
                           onSelect: { model.select(.cut(cut.id)) },
                           onChange: { start, end in model.updateTiming(\.cuts, id: cut.id, start: start, end: end) })
                    .frame(height: clipHeight)
                    .offset(x: CGFloat(cut.start) * pps)
            }

            TrimHandle(value: model.edits.trimStart, pps: pps, isLeading: true) { model.setTrimStart($0) }
                .frame(width: 10, height: clipHeight)
                .offset(x: startX)
            TrimHandle(value: model.trimEnd, pps: pps, isLeading: false) { model.setTrimEnd($0) }
                .frame(width: 10, height: clipHeight)
                .offset(x: endX - 10)
        }
    }

    private var speedSummary: String {
        let rates = Set(model.edits.speeds.map(\.rate))
        if rates.isEmpty { return "1×" }
        if rates.count == 1, let rate = rates.first { return String(format: "1–%g×", rate) }
        return "mixed"
    }

    // MARK: Zoom track

    private func zoomTrack(width: CGFloat, pps: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Theme.zoomTrack)
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { location in
                    model.addZoom(at: Double(location.x / pps) - 0.4)
                }

            if model.edits.zooms.isEmpty {
                Text("Click to add a zoom on the cursor")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: width, height: zoomHeight)
                    .allowsHitTesting(false)
            }

            ForEach(model.edits.zooms) { zoom in
                SegmentBar(start: zoom.start, end: zoom.end, pps: pps, limit: model.sourceDuration,
                           fill: AnyShapeStyle(Theme.zoom),
                           stroke: Color.white.opacity(0.18),
                           label: String(format: "Zoom %.1f×", zoom.scale),
                           icon: zoom.followsCursor ? "cursorarrow.motionlines" : "scope",
                           isSelected: model.selection == .zoom(zoom.id),
                           onSelect: { model.select(.zoom(zoom.id)) },
                           onChange: { start, end in model.updateTiming(\.zooms, id: zoom.id, start: start, end: end) })
                    .frame(height: zoomHeight)
                    .offset(x: CGFloat(zoom.start) * pps)
            }
        }
    }
}

// MARK: - Pieces

/// Diagonal stripes for removed sections.
enum CutHatch {
    static var style: AnyShapeStyle {
        AnyShapeStyle(ImagePaint(image: Image(nsImage: tile), scale: 0.5))
    }

    private static let tile: NSImage = {
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(calibratedWhite: 0.07, alpha: 0.92).setFill()
        NSRect(origin: .zero, size: size).fill()
        NSColor(calibratedWhite: 1, alpha: 0.08).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 3
        for offset in stride(from: -16.0, through: 16.0, by: 8.0) {
            path.move(to: NSPoint(x: offset, y: 0))
            path.line(to: NSPoint(x: offset + 16, y: 16))
        }
        path.stroke()
        image.unlockFocus()
        return image
    }()
}

struct TrimHandle: View {
    let value: Double
    let pps: CGFloat
    let isLeading: Bool
    let onChange: (Double) -> Void
    @State private var anchor: Double?
    @State private var hovering = false

    var body: some View {
        ZStack {
            Color.clear
            Capsule()
                .fill(Color.white.opacity(hovering || anchor != nil ? 0.95 : 0.55))
                .frame(width: 3, height: 16)
        }
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { drag in
                    let start = anchor ?? value
                    if anchor == nil { anchor = start }
                    onChange(start + Double(drag.translation.width / pps))
                }
                .onEnded { _ in anchor = nil }
        )
        .help(isLeading ? "Drag to trim the start" : "Drag to trim the end")
    }
}

struct SegmentBar: View {
    let start: Double
    let end: Double
    let pps: CGFloat
    let limit: Double
    let fill: AnyShapeStyle
    let stroke: Color
    let label: String
    let icon: String
    let isSelected: Bool
    let onSelect: () -> Void
    let onChange: (Double, Double) -> Void

    private enum DragPart { case body, leading, trailing }
    @State private var anchor: (start: Double, end: Double)?

    var body: some View {
        let width = max(8, CGFloat(end - start) * pps)
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(fill)
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isSelected ? Color.white.opacity(0.95) : stroke, lineWidth: isSelected ? 1.5 : 1)
            if width > 54 {
                Label(label, systemImage: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                    .lineLimit(1)
                    .padding(.horizontal, 10)
            }
            HStack(spacing: 0) {
                edge(.leading)
                Spacer(minLength: 0)
                edge(.trailing)
            }
        }
        .frame(width: width)
        .contentShape(Rectangle())
        .gesture(drag(.body))
        .onTapGesture { onSelect() }
    }

    private func edge(_ part: DragPart) -> some View {
        Color.clear
            .frame(width: 8)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .highPriorityGesture(drag(part))
    }

    private func drag(_ part: DragPart) -> some Gesture {
        DragGesture(minimumDistance: part == .body ? 3 : 0, coordinateSpace: .global)
            .onChanged { value in
                let base = anchor ?? (start: start, end: end)
                if anchor == nil {
                    anchor = base
                    onSelect()
                }
                let delta = Double(value.translation.width / pps)
                let length = base.end - base.start
                switch part {
                case .body:
                    let newStart = clamp(base.start + delta, 0, max(0, limit - length))
                    onChange(newStart, newStart + length)
                case .leading:
                    onChange(clamp(base.start + delta, 0, base.end - 0.2), base.end)
                case .trailing:
                    onChange(base.start, clamp(base.end + delta, base.start + 0.2, limit))
                }
            }
            .onEnded { _ in anchor = nil }
    }
}

/// Violet playhead with a knob on the ruler. Observes only the playback clock,
/// so it can move every display frame cheaply.
struct PlayheadLine: View {
    @ObservedObject var clock: PlaybackClock
    let x0: CGFloat
    let pps: CGFloat
    let height: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            Circle()
                .fill(Theme.accent)
                .frame(width: 10, height: 10)
            Rectangle()
                .fill(Theme.accent)
                .frame(width: 2, height: max(0, height - 10))
        }
        .frame(width: 10)
        .offset(x: x0 + CGFloat(clock.sourceTime) * pps - 5, y: 2)
        .allowsHitTesting(false)
    }
}
