import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Rounded inspector card to the right of the preview. Shows the selected timeline item's
/// settings when something is selected, otherwise the tab picked in the icon rail.
struct InspectorView: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if model.selection != nil {
                    SelectionInspector(model: model)
                } else {
                    switch model.inspectorTab {
                    case .background: BackgroundInspector(model: model)
                    case .cursor: CursorInspector(model: model)
                    case .zoom: ZoomInspector(model: model)
                    case .audio: AudioInspector(model: model)
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.cardFill))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hairline, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

private let defaults = StyleSettings()

// MARK: - Selection

struct SelectionInspector: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        if let zoom = model.selectedZoom {
            header("Zoom", range: (zoom.start, zoom.end))
            InspectorSection("Zoom level", trailing: AnyView(valueLabel(String(format: "%.1f×", zoom.scale)))) {
                ThemedSlider(value: Binding(get: { zoom.scale },
                                            set: { value in model.updateZoom(zoom.id) { $0.scale = value } }),
                             range: 1.2...4, defaultValue: 2)
            }
            InspectorDivider()
            ThemedToggleRow(title: "Follow cursor",
                            subtitle: "Keep the cursor in view while zoomed in.",
                            isOn: Binding(get: { zoom.followsCursor },
                                          set: { value in model.updateZoom(zoom.id) { $0.followsCursor = value } }))
            if !zoom.followsCursor {
                InspectorSection("Focus point") {
                    FocusPicker(image: model.thumbnail(near: zoom.start),
                                aspect: model.info.sourceAspect,
                                focus: CGPoint(x: zoom.focusX, y: zoom.focusY)) { point in
                        model.updateZoom(zoom.id) {
                            $0.focusX = Double(point.x)
                            $0.focusY = Double(point.y)
                        }
                    }
                }
            }
            deleteButton("Delete zoom")
        } else if let cut = model.selectedCut {
            header("Cut", range: (cut.start, cut.end))
            Text("This part of the recording is removed from the video. Drag its edges on the timeline to adjust.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            deleteButton("Remove cut")
        } else if let speed = model.selectedSpeed {
            header("Speed", range: (speed.start, speed.end))
            InspectorSection("Playback speed") {
                ChipPicker(options: [1.25, 1.5, 2, 3, 4, 8].map { ($0, String(format: "%g×", $0)) },
                           selection: Binding(get: { speed.rate }, set: { model.updateSpeed(speed.id, rate: $0) }))
            }
            deleteButton("Remove speed-up")
        }
    }

    private func header(_ title: String, range: (Double, Double)) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.text)
            Text("\(formatTime(range.0)) – \(formatTime(range.1))")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.textTertiary)
            Spacer()
            IconButton(systemName: "xmark", help: "Done", size: 11) { model.select(nil) }
        }
    }

    private func valueLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5, weight: .medium).monospacedDigit())
            .foregroundStyle(Theme.textSecondary)
    }

    private func deleteButton(_ title: String) -> some View {
        QuietButton(title: title) { model.deleteSelection() }
            .padding(.top, 4)
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
                    .background(Circle().fill(Theme.accent.opacity(0.55)))
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
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Background

private enum BackgroundKind: Hashable {
    case wallpaper, gradient, color, image
}

struct BackgroundInspector: View {
    @ObservedObject var model: EditorModel
    @State private var kindOverride: BackgroundKind?

    private var kind: BackgroundKind {
        if let kindOverride { return kindOverride }
        switch model.edits.style.background {
        case .wallpaper: return .wallpaper
        case .gradient: return .gradient
        case .color: return .color
        case .image: return .image
        }
    }

    var body: some View {
        InspectorSection("Background") {
            ChipPicker(options: [(BackgroundKind.wallpaper, "Wallpaper"), (.gradient, "Gradient"), (.color, "Color"), (.image, "Image")],
                       selection: Binding(get: { kind }, set: { kindOverride = $0 }))
        }

        switch kind {
        case .wallpaper:
            if Backgrounds.wallpapers.isEmpty {
                Text("No macOS wallpapers found.").font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary)
            } else {
                InspectorSection("Wallpaper") {
                    HStack {
                        QuietButton(title: "Pick random wallpaper") {
                            if let url = Backgrounds.wallpapers.randomElement() {
                                model.edits.style.background = .wallpaper(url.path)
                            }
                        }
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                        ForEach(Backgrounds.wallpapers, id: \.self) { url in
                            WallpaperThumb(url: url, isSelected: model.edits.style.background == .wallpaper(url.path)) {
                                model.edits.style.background = .wallpaper(url.path)
                            }
                        }
                    }
                }
            }
        case .gradient:
            InspectorSection("Gradient") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5), spacing: 6) {
                    ForEach(Backgrounds.gradients.indices, id: \.self) { index in
                        let gradient = Backgrounds.gradients[index]
                        RoundedRectangle(cornerRadius: 7)
                            .fill(LinearGradient(colors: [gradient.a.color, gradient.b.color],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                            .aspectRatio(1, contentMode: .fit)
                            .overlay(selectionRing(model.edits.style.background == .gradient(index)))
                            .contentShape(Rectangle())
                            .onTapGesture { model.edits.style.background = .gradient(index) }
                            .help(gradient.name)
                    }
                }
            }
        case .color:
            InspectorSection("Color") {
                ColorPicker("Background colour", selection: colorBinding, supportsOpacity: false)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }
        case .image:
            InspectorSection("Image") {
                QuietButton(title: "Choose image…") { chooseImage() }
                if case .image(let path) = model.edits.style.background {
                    Text(URL(fileURLWithPath: path).lastPathComponent)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
        }

        InspectorDivider()

        InspectorSection("Padding") {
            ThemedSlider(value: $model.edits.style.padding, range: 0...0.25, defaultValue: defaults.padding)
        }
        InspectorSection("Roundness") {
            ThemedSlider(value: $model.edits.style.cornerRadius, range: 0...0.06, defaultValue: defaults.cornerRadius)
        }
        InspectorDivider()
        InspectorSection("Shadow") {
            ThemedSlider(value: $model.edits.style.shadow, range: 0...1, defaultValue: defaults.shadow)
        }
        InspectorSection("Shadow size") {
            ThemedSlider(value: $model.edits.style.shadowSize, range: 0...0.1, defaultValue: defaults.shadowSize)
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
    RoundedRectangle(cornerRadius: 7)
        .strokeBorder(Color.white.opacity(selected ? 0.95 : 0), lineWidth: 2)
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
                Theme.control
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(selectionRing(isSelected))
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .help(url.deletingPathExtension().lastPathComponent)
        .task {
            guard image == nil else { return }
            let target = url
            let cgImage = await Task.detached(priority: .utility) {
                Backgrounds.loadImage(at: target, maxPixel: 200)
            }.value
            if let cgImage { image = NSImage(cgImage: cgImage, size: .zero) }
        }
    }
}

// MARK: - Cursor

struct CursorInspector: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        InspectorSection("Cursor size") {
            ThemedSlider(value: $model.edits.style.cursorScale, range: 0.8...3, defaultValue: defaults.cursorScale)
        }
        InspectorSection("Smoothing") {
            ThemedSlider(value: $model.edits.style.cursorSmoothing, range: 0...1, defaultValue: defaults.cursorSmoothing)
        }
        InspectorSection("Motion blur") {
            ThemedSlider(value: $model.edits.style.motionBlur, range: 0...1, defaultValue: defaults.motionBlur)
        }

        InspectorDivider()

        ThemedToggleRow(title: "Hide cursor if not moving",
                        subtitle: "Fades the cursor out after a moment of stillness.",
                        isOn: $model.edits.style.hideIdleCursor)
        ThemedToggleRow(title: "Hide cursor",
                        isOn: Binding(get: { !model.edits.style.showCursor },
                                      set: { model.edits.style.showCursor = !$0 }))

        InspectorDivider()

        InspectorSection("Click effect") {
            ChipPicker(options: ClickEffect.allCases.map { ($0, $0.label) },
                       selection: $model.edits.style.clickEffect)
        }
    }
}

// MARK: - Zoom

struct ZoomInspector: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        InspectorSection("Camera smoothness") {
            ThemedSlider(value: $model.edits.style.cameraSmoothing, range: 0...1, defaultValue: defaults.cameraSmoothing)
            Text("How gently the camera follows the cursor while zoomed in.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
        }

        InspectorDivider()

        InspectorSection("Automatic zoom") {
            Text("\(model.edits.zooms.count) zoom\(model.edits.zooms.count == 1 ? "" : "s") on the timeline. Click the zoom track to add one, or rebuild them from your clicks.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            QuietButton(title: "Regenerate auto zooms") { model.regenerateAutoZooms() }
        }
    }
}

// MARK: - Audio

struct AudioInspector: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        if model.info.hasSystemAudio {
            InspectorSection("System audio") {
                ThemedSlider(value: $model.edits.style.systemVolume, range: 0...1, defaultValue: 1)
            }
        }
        if model.info.hasMicrophone {
            InspectorSection("Microphone") {
                ThemedSlider(value: $model.edits.style.micVolume, range: 0...1, defaultValue: 1)
            }
        }
        if !model.info.hasSystemAudio && !model.info.hasMicrophone {
            InspectorSection("Audio") {
                Text("No audio was recorded. Pick a microphone or turn on system audio from the menu bar before recording.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
