import SwiftUI

struct ExportView: View {
    @ObservedObject var exporter: ExportModel
    @ObservedObject var editor: EditorModel
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Export")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
                IconButton(systemName: "xmark", help: "Close", size: 11, enabled: !exporter.isExporting) {
                    isPresented = false
                }
            }

            InspectorSection("Format") {
                ChipPicker(options: ExportModel.Format.allCases.map { ($0, $0.rawValue) }, selection: $exporter.format)
            }
            .disabled(exporter.isExporting)

            Group {
                if exporter.format == .mp4 {
                    InspectorSection("Resolution") {
                        ChipPicker(options: [(720, "720p"), (1080, "1080p"), (2160, "4K")], selection: $exporter.resolution)
                    }
                    InspectorSection("Frame rate") {
                        ChipPicker(options: [24, 30, 60, 120].map { ($0, "\($0) fps") }, selection: $exporter.fps)
                    }
                } else {
                    InspectorSection("Size") {
                        ChipPicker(options: [(480, "480p"), (720, "720p"), (1080, "1080p")], selection: $exporter.gifSize)
                    }
                    InspectorSection("Frame rate") {
                        ChipPicker(options: [15, 20, 30].map { ($0, "\($0) fps") }, selection: $exporter.gifFPS)
                    }
                }
            }
            .disabled(exporter.isExporting)

            let size = editor.canvasSize(shortSide: CGFloat(exporter.shortSide))
            Text("\(Int(size.width)) × \(Int(size.height))  ·  \(editor.edits.style.aspect.label)  ·  \(formatTime(editor.outputDuration))\(exporter.format == .mp4 && exporter.resolution >= 2160 ? "  ·  HEVC" : "")")
                .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.textSecondary)

            switch exporter.state {
            case .idle:
                EmptyView()
            case .exporting(let progress):
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: progress)
                        .tint(Theme.accentSoft)
                    Text("Exporting… \(Int(progress * 100))%")
                        .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                }
            case .done(let url):
                ExportedFileTile(url: url, thumbnail: editor.thumbnails.first, info: exporter.resultInfo)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                if exporter.isExporting {
                    QuietButton(title: "Cancel") { exporter.cancel() }
                } else {
                    QuietButton(title: "Close") { isPresented = false }
                        .keyboardShortcut(.cancelAction)
                }
                AccentButton(title: isDone ? "Export again" : "Export", systemImage: "square.and.arrow.up",
                             enabled: !exporter.isExporting) {
                    exporter.start(editor: editor)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 460)
        .background(Theme.card)
        .environment(\.colorScheme, .dark)
    }

    private var isDone: Bool {
        if case .done = exporter.state { return true }
        return false
    }
}
