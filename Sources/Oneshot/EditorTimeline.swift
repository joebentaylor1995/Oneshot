import SwiftUI

/// Source-time timeline: ruler, filmstrip with trim handles (cuts shown red, speed-ups blue),
/// zoom track, and the cut / speed track. Drag segment bodies to move them, edges to resize.
struct EditorTimeline: View {
    @ObservedObject var model: EditorModel
    private let inset: CGFloat = 16

    var body: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width - inset * 2)
            let pps = width / CGFloat(max(model.sourceDuration, 0.01))

            VStack(alignment: .leading, spacing: 6) {
                ruler(width: width, pps: pps)
                    .frame(width: width, height: 18)
                videoTrack(width: width, pps: pps)
                    .frame(width: width, height: 56)
                zoomTrack(width: width, pps: pps)
                    .frame(width: width, height: 30)
                editTrack(width: width, pps: pps)
                    .frame(width: width, height: 26)
            }
            .padding(.horizontal, inset)
            .padding(.vertical, 10)
            .overlay(alignment: .topLeading) {
                PlayheadLine(clock: model.clock, x0: inset, pps: pps, height: geo.size.height - 14)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: Ruler

    private func ruler(width: CGFloat, pps: CGFloat) -> some View {
        let steps: [Double] = [0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300]
        let step = steps.first { CGFloat($0) * pps >= 64 } ?? 600
        let duration = model.sourceDuration
        return Canvas { context, size in
            var t = 0.0
            while t <= duration {
                let x = CGFloat(t) * pps
                var tick = Path()
                tick.move(to: CGPoint(x: x, y: size.height - 5))
                tick.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(tick, with: .color(.secondary), lineWidth: 1)
                context.draw(Text(formatShortTime(t)).font(.caption2).foregroundColor(.secondary),
                             at: CGPoint(x: x + 3, y: 0), anchor: .topLeading)
                t += step
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

    // MARK: Video track

    private func videoTrack(width: CGFloat, pps: CGFloat) -> some View {
        let trimStartX = CGFloat(model.edits.trimStart) * pps
        let trimEndX = CGFloat(model.trimEnd) * pps
        return ZStack(alignment: .topLeading) {
            filmstrip(width: width, height: 56)
                .gesture(scrubGesture(pps: pps))

            ForEach(model.edits.speeds) { speed in
                Color.blue.opacity(0.35)
                    .frame(width: max(1, CGFloat(speed.end - speed.start) * pps), height: 56)
                    .offset(x: CGFloat(speed.start) * pps)
                    .allowsHitTesting(false)
            }
            ForEach(model.edits.cuts) { cut in
                Color.red.opacity(0.45)
                    .frame(width: max(1, CGFloat(cut.end - cut.start) * pps), height: 56)
                    .offset(x: CGFloat(cut.start) * pps)
                    .allowsHitTesting(false)
            }

            Color.black.opacity(0.6)
                .frame(width: max(0, trimStartX), height: 56)
                .allowsHitTesting(false)
            Color.black.opacity(0.6)
                .frame(width: max(0, width - trimEndX), height: 56)
                .offset(x: trimEndX)
                .allowsHitTesting(false)

            TrimHandle(value: model.edits.trimStart, pps: pps) { model.setTrimStart($0) }
                .frame(width: 10, height: 56)
                .offset(x: trimStartX)
            TrimHandle(value: model.trimEnd, pps: pps) { model.setTrimEnd($0) }
                .frame(width: 10, height: 56)
                .offset(x: trimEndX - 10)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func filmstrip(width: CGFloat, height: CGFloat) -> some View {
        let count = max(model.thumbnails.count, 1)
        return HStack(spacing: 0) {
            ForEach(Array(model.thumbnails.enumerated()), id: \.offset) { _, image in
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: width / CGFloat(count), height: height)
                    .clipped()
            }
        }
        .frame(width: width, height: height, alignment: .leading)
        .background(Color.primary.opacity(0.08))
        .contentShape(Rectangle())
    }

    // MARK: Zoom track

    private func zoomTrack(width: CGFloat, pps: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.05))
                .contentShape(Rectangle())
                .onTapGesture(count: 2, coordinateSpace: .local) { location in
                    model.addZoom(at: Double(location.x / pps))
                }
                .onTapGesture { model.select(nil) }

            if model.edits.zooms.isEmpty {
                Text("Double-click to add a zoom")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 8)
                    .frame(height: 30)
                    .allowsHitTesting(false)
            }

            ForEach(model.edits.zooms) { zoom in
                SegmentBar(start: zoom.start, end: zoom.end, pps: pps, limit: model.sourceDuration,
                           color: .purple,
                           label: String(format: "%.1f×", zoom.scale),
                           icon: zoom.followsCursor ? "cursorarrow.motionlines" : "scope",
                           isSelected: model.selection == .zoom(zoom.id),
                           onSelect: { model.select(.zoom(zoom.id)) },
                           onChange: { start, end in model.updateTiming(\.zooms, id: zoom.id, start: start, end: end) })
                    .frame(height: 30)
                    .offset(x: CGFloat(zoom.start) * pps)
            }
        }
    }

    // MARK: Cut & speed track

    private func editTrack(width: CGFloat, pps: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.05))
                .contentShape(Rectangle())
                .onTapGesture { model.select(nil) }

            if model.edits.cuts.isEmpty && model.edits.speeds.isEmpty {
                Text("Cuts and speed-ups (C / S at the playhead)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 8)
                    .frame(height: 26)
                    .allowsHitTesting(false)
            }

            ForEach(model.edits.cuts) { cut in
                SegmentBar(start: cut.start, end: cut.end, pps: pps, limit: model.sourceDuration,
                           color: .red, label: "Cut", icon: "scissors",
                           isSelected: model.selection == .cut(cut.id),
                           onSelect: { model.select(.cut(cut.id)) },
                           onChange: { start, end in model.updateTiming(\.cuts, id: cut.id, start: start, end: end) })
                    .frame(height: 26)
                    .offset(x: CGFloat(cut.start) * pps)
            }
            ForEach(model.edits.speeds) { speed in
                SegmentBar(start: speed.start, end: speed.end, pps: pps, limit: model.sourceDuration,
                           color: .blue, label: String(format: "%g×", speed.rate), icon: "hare",
                           isSelected: model.selection == .speed(speed.id),
                           onSelect: { model.select(.speed(speed.id)) },
                           onChange: { start, end in model.updateTiming(\.speeds, id: speed.id, start: start, end: end) })
                    .frame(height: 26)
                    .offset(x: CGFloat(speed.start) * pps)
            }
        }
    }
}

// MARK: - Pieces

struct TrimHandle: View {
    let value: Double
    let pps: CGFloat
    let onChange: (Double) -> Void
    @State private var anchor: Double?

    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color.yellow)
            .overlay(Capsule().fill(Color.black.opacity(0.5)).frame(width: 2, height: 18))
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let start = anchor ?? value
                        if anchor == nil { anchor = start }
                        onChange(start + Double(drag.translation.width / pps))
                    }
                    .onEnded { _ in anchor = nil }
            )
    }
}

struct SegmentBar: View {
    let start: Double
    let end: Double
    let pps: CGFloat
    let limit: Double
    let color: Color
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
            RoundedRectangle(cornerRadius: 6)
                .fill(color.opacity(isSelected ? 1 : 0.72))
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.white.opacity(isSelected ? 0.95 : 0), lineWidth: 1.5)
            if width > 44 {
                Label(label, systemImage: icon)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
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
        DragGesture(minimumDistance: part == .body ? 3 : 0)
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

/// The red playhead. Observes only the playback clock, so it can move every display frame cheaply.
struct PlayheadLine: View {
    @ObservedObject var clock: PlaybackClock
    let x0: CGFloat
    let pps: CGFloat
    let height: CGFloat

    var body: some View {
        Capsule()
            .fill(Color.red)
            .frame(width: 2, height: height)
            .offset(x: x0 + CGFloat(clock.sourceTime) * pps - 1, y: 7)
            .allowsHitTesting(false)
    }
}
