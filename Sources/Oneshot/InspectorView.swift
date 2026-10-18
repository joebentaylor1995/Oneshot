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

/// Background picker: Color (solid or gradient) or Image (macOS wallpapers or your own image).
struct BackgroundInspector: View {
    @ObservedObject var model: EditorModel
    @State private var kindOverride: Kind?
    @State private var colorModeOverride: ColorMode?

    private enum Kind: Hashable { case color, image }
    private enum ColorMode: Hashable { case solid, gradient }

    private static let solidPresets: [RGBColor] = [
        RGBColor(hex: 0xFFFFFF), RGBColor(hex: 0xF2F2F4), RGBColor(hex: 0x8E8E93),
        RGBColor(hex: 0x2C2C2E), RGBColor(hex: 0x121212), RGBColor(hex: 0x1653FF),
        RGBColor(hex: 0x6B59FA), RGBColor(hex: 0xFF5F57), RGBColor(hex: 0xFEBC2E), RGBColor(hex: 0x28C840),
    ]

    private var style: BackgroundStyle { model.edits.style.background }

    private var kind: Kind {
        if let kindOverride { return kindOverride }
        switch style {
        case .color, .gradient: return .color
        case .wallpaper, .image: return .image
        }
    }

    private var colorMode: ColorMode {
        if let colorModeOverride { return colorModeOverride }
        if case .color = style { return .solid }
        return .gradient
    }

    var body: some View {
        InspectorSection("Background") {
            ChipPicker(options: [(Kind.color, "Color"), (.image, "Image")],
                       selection: Binding(get: { kind }, set: { kindOverride = $0 }))
        }

        switch kind {
        case .color:
            InspectorSection("Fill") {
                ChipPicker(options: [(ColorMode.solid, "Solid"), (.gradient, "Gradient")],
                           selection: Binding(get: { colorMode }, set: { colorModeOverride = $0 }))
                switch colorMode {
                case .solid: solidPicker
                case .gradient: gradientPicker
                }
            }
        case .image:
            wallpaperSection
            InspectorDivider()
            customImageSection
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
        InspectorDivider()
        InspectorSection("Fade in", trailing: AnyView(secondsLabel(model.edits.style.fadeIn))) {
            ThemedSlider(value: $model.edits.style.fadeIn, range: 0...3, defaultValue: defaults.fadeIn)
        }
        InspectorSection("Fade out", trailing: AnyView(secondsLabel(model.edits.style.fadeOut))) {
            ThemedSlider(value: $model.edits.style.fadeOut, range: 0...3, defaultValue: defaults.fadeOut)
            Text("Fades the video and audio from and to black.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private func secondsLabel(_ seconds: Double) -> some View {
        Text(seconds < 0.05 ? "Off" : String(format: "%.1fs", seconds))
            .font(.system(size: 11.5, weight: .medium).monospacedDigit())
            .foregroundStyle(Theme.textSecondary)
    }

    // MARK: Color

    private var solidPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5), spacing: 6) {
                ForEach(Self.solidPresets.indices, id: \.self) { index in
                    let preset = Self.solidPresets[index]
                    RoundedRectangle(cornerRadius: 7)
                        .fill(preset.color)
                        .aspectRatio(1, contentMode: .fit)
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.hairline, lineWidth: 1))
                        .overlay(selectionRing(style == .color(preset)))
                        .contentShape(Rectangle())
                        .onTapGesture { model.edits.style.background = .color(preset) }
                }
            }
            ColorPicker(selection: colorBinding, supportsOpacity: false) {
                Text("Custom colour")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var gradientPicker: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5), spacing: 6) {
            ForEach(Backgrounds.gradients.indices, id: \.self) { index in
                let gradient = Backgrounds.gradients[index]
                RoundedRectangle(cornerRadius: 7)
                    .fill(LinearGradient(colors: [gradient.a.color, gradient.b.color],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .aspectRatio(1, contentMode: .fit)
                    .overlay(selectionRing(style == .gradient(index)))
                    .contentShape(Rectangle())
                    .onTapGesture { model.edits.style.background = .gradient(index) }
                    .help(gradient.name)
            }
        }
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: {
                if case .color(let color) = style { return color.color }
                return .white
            },
            set: { model.edits.style.background = .color(RGBColor(color: $0)) }
        )
    }

    // MARK: Image

    private var wallpaperSection: some View {
        InspectorSection("Wallpapers", trailing: Backgrounds.wallpapers.isEmpty ? nil : AnyView(
            QuietButton(title: "Random") {
                if let url = Backgrounds.wallpapers.randomElement() {
                    model.edits.style.background = .wallpaper(url.path)
                }
            }
        )) {
            if Backgrounds.wallpapers.isEmpty {
                Text("No macOS wallpapers found.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textSecondary)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                    ForEach(Backgrounds.wallpapers, id: \.self) { url in
                        WallpaperThumb(url: url, isSelected: style == .wallpaper(url.path)) {
                            model.edits.style.background = .wallpaper(url.path)
                        }
                    }
                }
            }
        }
    }

    private var customImageSection: some View {
        InspectorSection("Custom image") {
            HStack(spacing: 10) {
                if case .image(let path) = style {
                    WallpaperThumb(url: URL(fileURLWithPath: path), isSelected: true) {}
                        .frame(width: 44)
                    Text(URL(fileURLWithPath: path).lastPathComponent)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                QuietButton(title: isCustomImage ? "Change…" : "Choose image…") { chooseImage() }
            }
        }
    }

    private var isCustomImage: Bool {
        if case .image = style { return true }
        return false
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
