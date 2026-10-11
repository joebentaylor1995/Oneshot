import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct InspectorView: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(spacing: 0) {
            if model.selection != nil {
                SelectionInspector(model: model)
                    .padding(16)
                Divider()
            }
            Picker("Section", selection: $model.inspectorTab) {
                ForEach(InspectorTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch model.inspectorTab {
                    case .background: BackgroundInspector(model: model)
                    case .cursor: CursorInspector(model: model)
                    case .zoom: ZoomInspector(model: model)
                    case .audio: AudioInspector(model: model)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

// MARK: - Shared pieces

struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format: (Double) -> String = { String(format: "%.0f%%", $0 * 100) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value)).monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.callout)
            Slider(value: $value, in: range)
        }
    }
}

// MARK: - Selection

struct SelectionInspector: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let zoom = model.selectedZoom {
                header("Zoom", icon: "plus.magnifyingglass", range: (zoom.start, zoom.end))
                LabeledSlider(title: "Zoom level",
                              value: Binding(get: { zoom.scale },
                                             set: { value in model.updateZoom(zoom.id) { $0.scale = value } }),
                              range: 1.2...4,
                              format: { String(format: "%.1f×", $0) })
                Toggle("Follow cursor", isOn: Binding(get: { zoom.followsCursor },
                                                      set: { value in model.updateZoom(zoom.id) { $0.followsCursor = value } }))
                if !zoom.followsCursor {
                    Text("Click to set the focus point").font(.caption).foregroundStyle(.secondary)
                    FocusPicker(image: model.thumbnail(near: zoom.start),
                                aspect: model.info.sourceAspect,
                                focus: CGPoint(x: zoom.focusX, y: zoom.focusY)) { point in
                        model.updateZoom(zoom.id) {
                            $0.focusX = Double(point.x)
                            $0.focusY = Double(point.y)
                        }
                    }
                }
            } else if let cut = model.selectedCut {
                header("Cut", icon: "scissors", range: (cut.start, cut.end))
                Text("This section is removed from the video.").font(.caption).foregroundStyle(.secondary)
            } else if let speed = model.selectedSpeed {
                header("Speed", icon: "hare", range: (speed.start, speed.end))
                Picker("Speed", selection: Binding(get: { speed.rate },
                                                   set: { model.updateSpeed(speed.id, rate: $0) })) {
                    ForEach([1.25, 1.5, 2, 3, 4, 8], id: \.self) { rate in
                        Text(String(format: "%g×", rate)).tag(rate)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            Button(role: .destructive) {
                model.deleteSelection()
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func header(_ title: String, icon: String, range: (Double, Double)) -> some View {
        HStack {
            Label(title, systemImage: icon).font(.headline)
            Spacer()
            Text("\(formatTime(range.0)) to \(formatTime(range.1))")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}

struct FocusPicker: View {
    let image: NSImage?
    let aspect: CGFloat
    let focus: CGPoint
    let onPick: (CGPoint) -> Void

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if let image {
                    Image(nsImage: image).resizable()
                } else {
                    Color.black
                }
                Circle()
                    .strokeBorder(Color.white, lineWidth: 2)
                    .background(Circle().fill(Color.purple.opacity(0.5)))
                    .frame(width: 18, height: 18)
                    .shadow(radius: 2)
                    .position(x: focus.x * geo.size.width, y: focus.y * geo.size.height)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        onPick(CGPoint(x: clamp(value.location.x / geo.size.width, 0, 1),
                                       y: clamp(value.location.y / geo.size.height, 0, 1)))
                    }
            )
        }
        .aspectRatio(aspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Background

struct BackgroundInspector: View {
    @ObservedObject var model: EditorModel
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 5)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Gradients")
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(Backgrounds.gradients.indices, id: \.self) { index in
                    let gradient = Backgrounds.gradients[index]
                    RoundedRectangle(cornerRadius: 6)
                        .fill(LinearGradient(colors: [gradient.a.color, gradient.b.color],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .aspectRatio(1, contentMode: .fit)
                        .overlay(selectionRing(model.edits.style.background == .gradient(index)))
                        .onTapGesture { model.edits.style.background = .gradient(index) }
                        .help(gradient.name)
                }
            }
        }

        if !Backgrounds.wallpapers.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle("Wallpapers")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                    ForEach(Backgrounds.wallpapers, id: \.self) { url in
                        WallpaperThumb(url: url, isSelected: model.edits.style.background == .wallpaper(url.path)) {
                            model.edits.style.background = .wallpaper(url.path)
                        }
                    }
                }
            }
        }

        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Colour & image")
            ColorPicker("Solid colour", selection: colorBinding, supportsOpacity: false)
            Button {
                chooseImage()
            } label: {
                Label("Choose Image…", systemImage: "photo")
            }
            if case .image(let path) = model.edits.style.background {
                Text(URL(fileURLWithPath: path).lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }

        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("Frame")
            LabeledSlider(title: "Padding", value: $model.edits.style.padding, range: 0...0.25)
            LabeledSlider(title: "Corner radius", value: $model.edits.style.cornerRadius, range: 0...0.06)
            LabeledSlider(title: "Shadow", value: $model.edits.style.shadow, range: 0...1)
            LabeledSlider(title: "Shadow size", value: $model.edits.style.shadowSize, range: 0...0.1)
        }
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: {
                if case .color(let color) = model.edits.style.background { return color.color }
                return .white
            },
            set: { model.edits.style.background = .color(RGBColor(color: $0)) }
        )
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            model.edits.style.background = .image(url.path)
        }
    }
}

func selectionRing(_ selected: Bool) -> some View {
    RoundedRectangle(cornerRadius: 6)
        .strokeBorder(Color.accentColor, lineWidth: selected ? 2.5 : 0)
}

struct WallpaperThumb: View {
    let url: URL
    let isSelected: Bool
    let action: () -> Void
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Color.secondary.opacity(0.15)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(selectionRing(isSelected))
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .help(url.deletingPathExtension().lastPathComponent)
        .task {
            guard image == nil else { return }
            let target = url
            let cgImage = await Task.detached(priority: .utility) {
                Backgrounds.loadImage(at: target, maxPixel: 240)
            }.value
            if let cgImage { image = NSImage(cgImage: cgImage, size: .zero) }
        }
    }
}

// MARK: - Cursor

struct CursorInspector: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("Cursor")
            Toggle("Show cursor", isOn: $model.edits.style.showCursor)
            LabeledSlider(title: "Size", value: $model.edits.style.cursorScale, range: 0.8...3,
                          format: { String(format: "%.1f×", $0) })
            LabeledSlider(title: "Smoothing", value: $model.edits.style.cursorSmoothing, range: 0...1)
            LabeledSlider(title: "Motion blur", value: $model.edits.style.motionBlur, range: 0...1)
            Toggle("Hide when idle", isOn: $model.edits.style.hideIdleCursor)
        }
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Clicks")
            Picker("Click effect", selection: $model.edits.style.clickEffect) {
                ForEach(ClickEffect.allCases) { effect in
                    Text(effect.label).tag(effect)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }
}

// MARK: - Zoom

struct ZoomInspector: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("Camera")
            LabeledSlider(title: "Smoothness", value: $model.edits.style.cameraSmoothing, range: 0...1)
            Text("How lazily the camera follows the cursor while zoomed in.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Zooms")
            Text("\(model.edits.zooms.count) zoom\(model.edits.zooms.count == 1 ? "" : "s"). Double-click the zoom track or press Z to add one; select a zoom to change its level or focus.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                model.regenerateAutoZooms()
            } label: {
                Label("Regenerate Auto Zooms", systemImage: "wand.and.stars")
            }
            .help("Replaces automatic zooms with fresh ones built from your clicks. Zooms you've edited are kept.")
        }
    }
}

// MARK: - Audio

struct AudioInspector: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("Volume")
            if model.info.hasSystemAudio {
                LabeledSlider(title: "System audio", value: $model.edits.style.systemVolume, range: 0...1)
            }
            if model.info.hasMicrophone {
                LabeledSlider(title: "Microphone", value: $model.edits.style.micVolume, range: 0...1)
            }
            if !model.info.hasSystemAudio && !model.info.hasMicrophone {
                Text("No audio was recorded. Pick a microphone or turn on system audio from the menu bar before recording.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
