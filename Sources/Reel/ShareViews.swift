import AppKit
import SwiftUI

/// The finished file: drag it anywhere, copy it, or reveal it.
struct ExportedFileTile: View {
    let url: URL
    let thumbnail: NSImage?
    let info: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Group {
                    if let thumbnail {
                        Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: "film").font(.title2).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 80, height: 50)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 2) {
                    Text(url.lastPathComponent)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(info)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Text("Drag to share")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06)))
            .overlay(FileDragSource(url: url, image: thumbnail))
            .help("Drag into Slack, Finder, Mail, Figma…")

            HStack {
                Button {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.writeObjects([url as NSURL])
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
            }
        }
    }
}

/// Transparent AppKit view laid over the tile that starts a real file drag.
struct FileDragSource: NSViewRepresentable {
    let url: URL
    let image: NSImage?

    func makeNSView(context: Context) -> FileDragView {
        let view = FileDragView()
        view.fileURL = url
        view.dragImage = image
        return view
    }

    func updateNSView(_ nsView: FileDragView, context: Context) {
        nsView.fileURL = url
        nsView.dragImage = image
    }
}

final class FileDragView: NSView, NSDraggingSource {
    var fileURL: URL?
    var dragImage: NSImage?

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        // Swallow so mouseDragged arrives here.
    }

    override func mouseDragged(with event: NSEvent) {
        guard let fileURL else { return }
        let item = NSDraggingItem(pasteboardWriter: fileURL as NSURL)
        let image = dragImage ?? NSWorkspace.shared.icon(forFile: fileURL.path)
        let width: CGFloat = 160
        let aspect = image.size.width > 0 ? image.size.height / image.size.width : 0.625
        let size = CGSize(width: width, height: width * aspect)
        let point = convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                     width: size.width, height: size.height),
                              contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}
