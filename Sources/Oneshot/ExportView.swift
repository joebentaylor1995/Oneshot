import SwiftUI

struct ExportView: View {
    @ObservedObject var exporter: ExportModel
    @ObservedObject var editor: EditorModel
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Export").font(.title2.weight(.semibold))

            Picker("Format", selection: $exporter.format) {
                ForEach(ExportModel.Format.allCases) { format in
                    Text(format.rawValue).tag(format)
                }
            }
            .pickerStyle(.segmented)
            .disabled(exporter.isExporting)

            Group {
                if exporter.format == .mp4 {
                    row("Resolution") {
                        Picker("Resolution", selection: $exporter.resolution) {
                            Text("720p").tag(720)
                            Text("1080p").tag(1080)
                            Text("4K").tag(2160)
                        }
                    }
                    row("Frame rate") {
                        Picker("Frame rate", selection: $exporter.fps) {
                            Text("24").tag(24)
                            Text("30").tag(30)
                            Text("60").tag(60)
                            Text("120").tag(120)
                        }
                    }
                } else {
                    row("Size") {
                        Picker("Size", selection: $exporter.gifSize) {
                            Text("480p").tag(480)
                            Text("720p").tag(720)
                            Text("1080p").tag(1080)
                        }
                    }
                    row("Frame rate") {
                        Picker("Frame rate", selection: $exporter.gifFPS) {
                            Text("15").tag(15)
                            Text("20").tag(20)
                            Text("30").tag(30)
                        }
                    }
                }
            }
            .disabled(exporter.isExporting)

            let size = editor.canvasSize(shortSide: CGFloat(exporter.shortSide))
            Text("\(Int(size.width)) × \(Int(size.height))  ·  \(editor.edits.style.aspect.label)  ·  \(formatTime(editor.outputDuration))\(exporter.format == .mp4 && exporter.resolution >= 2160 ? "  ·  HEVC" : "")")
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)

            switch exporter.state {
            case .idle:
                EmptyView()
            case .exporting(let progress):
                ProgressView(value: progress) {
                    Text("Exporting… \(Int(progress * 100))%").font(.callout)
                }
            case .done(let url):
                ExportedFileTile(url: url, thumbnail: editor.thumbnails.first, info: exporter.resultInfo)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                if exporter.isExporting {
                    Button("Cancel") { exporter.cancel() }
                } else {
                    Button("Close") { isPresented = false }
                        .keyboardShortcut(.cancelAction)
                }
                Button {
                    exporter.start(editor: editor)
                } label: {
                    Text(isDone ? "Export Again" : "Export")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(exporter.isExporting)
            }
        }
        .padding(24)
        .frame(width: 500)
    }

    private var isDone: Bool {
        if case .done = exporter.state { return true }
        return false
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(title).frame(width: 90, alignment: .leading)
            content()
                .pickerStyle(.segmented)
                .labelsHidden()
        }
    }
}
