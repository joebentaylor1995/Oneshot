import AVKit
import SwiftUI

struct EditorView: View {
    @ObservedObject var model: EditorModel
    @StateObject private var exporter = ExportModel()
    @State private var showingExport = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                toolbar
                Divider()
                preview
                Divider()
                transportBar
                Divider()
                EditorTimeline(model: model)
                    .frame(height: 178)
            }
            Divider()
            InspectorView(model: model)
                .frame(width: 310)
        }
        .frame(minWidth: 1100, minHeight: 720)
        .task { await model.load() }
        .sheet(isPresented: $showingExport) {
            ExportView(exporter: exporter, editor: model, isPresented: $showingExport)
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 14) {
            Picker("Aspect ratio", selection: $model.edits.style.aspect) {
                ForEach(AspectRatio.allCases) { ratio in
                    Text(ratio.label).tag(ratio)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 320)
            .help("Output aspect ratio")

            Spacer()

            Text(model.project.displayName)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            Button {
                exporter.reset()
                showingExport = true
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("e", modifiers: .command)
            .disabled(!model.isLoaded)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: Preview

    private var preview: some View {
        ZStack {
            Color(nsColor: .underPageBackgroundColor)
            PlayerSurface(player: model.player)
                .aspectRatio(model.outputAspect, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
                .padding(24)
            if !model.isLoaded {
                ProgressView()
            } else if let error = model.loadError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .padding(10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Transport

    private var transportBar: some View {
        HStack(spacing: 10) {
            Button {
                model.togglePlayback()
            } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").frame(width: 18)
            }
            .help("Play / Pause (Space)")

            PlaybackTimeLabel(model: model, clock: model.clock)

            Spacer()

            Button { model.addZoomAtPlayhead() } label: { Label("Zoom", systemImage: "plus.magnifyingglass") }
                .help("Add a zoom at the playhead (Z)")
            Button { model.addCutAtPlayhead() } label: { Label("Cut", systemImage: "scissors") }
                .help("Cut a section at the playhead (C)")
            Button { model.addSpeedAtPlayhead() } label: { Label("Speed", systemImage: "hare") }
                .help("Speed up a section at the playhead (S)")
            Button { model.regenerateAutoZooms() } label: { Label("Auto Zoom", systemImage: "wand.and.stars") }
                .help("Rebuild automatic zooms from your clicks")

            Button(role: .destructive) { model.deleteSelection() } label: { Image(systemName: "trash") }
                .disabled(model.selection == nil)
                .help("Delete selected (⌫)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
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
struct PlaybackTimeLabel: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var clock: PlaybackClock

    var body: some View {
        Text("\(formatTime(model.mapping.compositionTime(forSource: clock.sourceTime))) / \(formatTime(model.outputDuration))")
            .monospacedDigit()
            .foregroundStyle(.secondary)
    }
}
