import AVKit
import SwiftUI

struct EditorView: View {
    @ObservedObject var model: EditorModel
    @StateObject private var exporter = ExportModel()
    @State private var showingExport = false
    @State private var saveName = ""

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Rectangle().fill(Theme.hairline).frame(height: 1)

            // Canvas and timeline on the left; the inspector runs the full height on the right,
            // with its icon rail floating at the canvas's top-right corner.
            HStack(alignment: .top, spacing: 0) {
                VStack(spacing: 0) {
                    canvasHeader
                    preview
                    transportRow
                    EditorTimeline(model: model)
                        .frame(height: EditorTimeline.contentHeight)
                        .padding(.bottom, 18)
                }
                .overlay(alignment: .topTrailing) {
                    InspectorRail(model: model)
                        .padding(.top, 18)
                }
                InspectorView(model: model)
                    .frame(width: 300)
                    .padding(.top, 18)
                    .padding(.trailing, 18)
                    .padding(.bottom, 18)
            }
        }
        .background(WindowGlass())
        .environment(\.colorScheme, .dark)
        .frame(minWidth: 1100, minHeight: 720)
        .task { await model.load() }
        .sheet(isPresented: $showingExport) {
            ExportView(exporter: exporter, editor: model, isPresented: $showingExport)
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        ZStack {
            WindowDragArea()

            HStack(spacing: 4) {
                Color.clear.frame(width: max(0, model.chrome.leading - 12), height: 1) // traffic lights
                IconButton(systemName: "folder", help: "Show recording in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([model.project.url])
                }
                Spacer()
                IconButton(systemName: "arrow.uturn.backward", help: "Undo (⌘Z)", enabled: model.canUndo) { model.undo() }
                IconButton(systemName: "arrow.uturn.forward", help: "Redo (⇧⌘Z)", enabled: model.canRedo) { model.redo() }
                Rectangle().fill(Theme.hairline).frame(width: 1, height: 18).padding(.horizontal, 8)
                IconButton(systemName: model.isKept ? "checkmark.circle" : "square.and.arrow.down",
                           help: model.isKept ? "Saved — click to rename (⌘S)" : "Save recording (⌘S). Unsaved recordings are deleted when closed unless exported.",
                           isActive: model.isKept) {
                    saveName = model.name
                    model.showingSavePrompt = true
                }
                AccentButton(title: "Export", systemImage: "square.and.arrow.up", enabled: model.isLoaded) {
                    exporter.reset()
                    showingExport = true
                }
                .keyboardShortcut("e", modifiers: .command)
            }
            .padding(.horizontal, 12)

            HStack(spacing: 0) {
                Text(model.name)
                    .foregroundStyle(Theme.text)
                Text(".oneshot")
                    .foregroundStyle(Theme.textTertiary)
            }
            .font(.system(size: 12.5, weight: .medium))
            .lineLimit(1)
            .allowsHitTesting(false)
        }
        .frame(height: model.chrome.height)
        .alert("Save recording", isPresented: $model.showingSavePrompt) {
            TextField("Name", text: $saveName)
            Button("Save") { model.save(as: saveName) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saved recordings stay in Open Recent. Recordings that aren't saved or exported are moved to the Trash when you close them.")
        }
    }

    // MARK: Canvas

    private var canvasHeader: some View {
        HStack(spacing: 4) {
            Menu {
                ForEach(AspectRatio.allCases) { ratio in
                    Button {
                        model.edits.style.aspect = ratio
                    } label: {
                        if ratio == model.edits.style.aspect {
                            Label(ratio.label, systemImage: "checkmark")
                        } else {
                            Text(ratio.label)
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "aspectratio")
                    Text(model.edits.style.aspect.label)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Output aspect ratio")

            Spacer()
        }
        .padding(.horizontal, 22)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    private var preview: some View {
        ZStack {
            PlayerSurface(player: model.player)
                .aspectRatio(model.outputAspect, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            if !model.isLoaded {
                ProgressView().controlSize(.small)
            } else if let error = model.loadError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.text)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
            }
        }
        // Wider on the right to keep clear of the floating inspector rail.
        .padding(.leading, 28)
        .padding(.trailing, 56)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Transport

    private var transportRow: some View {
        ZStack {
            HStack(spacing: 2) {
                IconButton(systemName: "scissors", help: "Cut a section at the playhead (C)") { model.addCutAtPlayhead() }
                IconButton(systemName: "hare", help: "Speed up a section at the playhead (S)") { model.addSpeedAtPlayhead() }
                IconButton(systemName: "plus.magnifyingglass", help: "Add a zoom at the playhead (Z)") { model.addZoomAtPlayhead() }
                IconButton(systemName: "wand.and.stars", help: "Rebuild automatic zooms from your clicks") { model.regenerateAutoZooms() }
                Spacer()
                IconButton(systemName: "trash", help: "Delete selected (⌫)", enabled: model.selection != nil) { model.deleteSelection() }
            }

            HStack(spacing: 10) {
                CurrentTimeLabel(model: model, clock: model.clock)
                    .frame(width: 64, alignment: .trailing)
                IconButton(systemName: "backward.end", help: "Go to start") { model.jumpToStart() }
                Button {
                    model.togglePlayback()
                } label: {
                    Image(systemName: model.isPlaying ? "pause.circle" : "play.circle")
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(Theme.text)
                        .frame(width: 32, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Play / Pause (Space)")
                IconButton(systemName: "forward.end", help: "Go to end") { model.jumpToEnd() }
                Text(formatTime(model.outputDuration))
                    .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 64, alignment: .leading)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

/// Right-hand icon rail that switches the inspector card.
struct InspectorRail: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(spacing: 8) {
            ForEach(InspectorTab.allCases) { tab in
                ZStack(alignment: .trailing) {
                    IconButton(systemName: tab.icon, help: tab.rawValue, size: 13,
                               isActive: model.inspectorTab == tab && model.selection == nil) {
                        model.select(nil)
                        model.inspectorTab = tab
                    }
                    if model.inspectorTab == tab && model.selection == nil {
                        Circle().fill(Theme.accentSoft).frame(width: 3, height: 3).offset(x: -3)
                    }
                }
            }
        }
        .padding(.horizontal, 8)
    }
}

extension InspectorTab {
    var icon: String {
        switch self {
        case .background: return "square.dashed.inset.filled"
        case .cursor: return "cursorarrow"
        case .zoom: return "plus.magnifyingglass"
        case .audio: return "speaker.wave.2"
        }
    }
}

struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = false
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {}
}

/// Only this small view redraws as the playhead moves.
struct CurrentTimeLabel: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var clock: PlaybackClock

    var body: some View {
        Text(formatTime(model.mapping.compositionTime(forSource: clock.sourceTime)))
            .font(.system(size: 11.5, weight: .medium).monospacedDigit())
            .foregroundStyle(Theme.textTertiary)
    }
}
