import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

@MainActor
final class ExportModel: ObservableObject {
    enum Format: String, CaseIterable, Identifiable {
        case mp4 = "MP4"
        case gif = "GIF"
        var id: String { rawValue }
    }

    enum State: Equatable {
        case idle
        case exporting(Double)
        case done(URL)
        case failed(String)
    }

    @Published var format: Format = .mp4
    /// Shorter side of the output, in pixels.
    @Published var resolution = 1080
    @Published var fps = 60
    @Published var gifSize = 720
    @Published var gifFPS = 20
    @Published private(set) var state: State = .idle
    @Published private(set) var resultInfo = ""

    private var task: Task<Void, Never>?
    private var session: AVAssetExportSession?

    var isExporting: Bool {
        if case .exporting = state { return true }
        return false
    }

    var shortSide: Int { format == .mp4 ? resolution : gifSize }

    func start(editor: EditorModel) {
        guard !isExporting else { return }
        editor.pause()
        state = .exporting(0)
        let format = self.format
        let url = Paths.exportURL(name: editor.project.displayName, fileExtension: format == .mp4 ? "mp4" : "gif")
        try? FileManager.default.removeItem(at: url)

        task = Task { [weak self] in
            guard let self else { return }
            do {
                switch format {
                case .mp4: try await self.exportMP4(editor: editor, to: url)
                case .gif: try await self.exportGIF(editor: editor, to: url)
                }
                let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                let size = editor.canvasSize(shortSide: CGFloat(self.shortSide))
                self.resultInfo = "\(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) · \(Int(size.width))×\(Int(size.height)) · \(formatTime(editor.outputDuration))"
                self.state = .done(url)
                NSSound(named: "Glass")?.play()
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: url)
                self.state = .idle
            } catch {
                try? FileManager.default.removeItem(at: url)
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        session?.cancelExport()
        task?.cancel()
    }

    func reset() {
        if !isExporting { state = .idle }
    }

    // MARK: MP4

    private func exportMP4(editor: EditorModel, to url: URL) async throws {
        let composition = try await CompositionBuilder.build(source: editor.sourceAsset, mapping: editor.mapping)
        let renderState = RenderState()
        renderState.snapshot = editor.renderState.snapshot
        let size = editor.canvasSize(shortSide: CGFloat(resolution))
        let videoComposition = try await Compositor.makeVideoComposition(for: composition, renderSize: size, fps: fps, state: renderState)

        // H.264 plays everywhere; 4K uses HEVC (H.264 tops out around 4096×2304).
        let preset = resolution >= 2160 ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHighestQuality
        guard let session = AVAssetExportSession(asset: composition, presetName: preset) else {
            throw OneshotError.exportFailed("Couldn't create an export session.")
        }
        session.outputURL = url
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        session.videoComposition = videoComposition
        session.audioMix = CompositionBuilder.audioMix(for: composition, info: editor.info, style: editor.edits.style)
        session.audioTimePitchAlgorithm = .spectral
        self.session = session

        let progressTask = Task { [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if Task.isCancelled { break }
                self?.state = .exporting(Double(session.progress))
            }
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { continuation.resume() }
        }
        progressTask.cancel()
        self.session = nil

        if session.status == .cancelled { throw CancellationError() }
        guard session.status == .completed else {
            throw OneshotError.exportFailed(session.error?.localizedDescription ?? "Unknown error.")
        }
    }

    // MARK: GIF

    private func exportGIF(editor: EditorModel, to url: URL) async throws {
        let composition = try await CompositionBuilder.build(source: editor.sourceAsset, mapping: editor.mapping)
        let renderState = RenderState()
        renderState.snapshot = editor.renderState.snapshot
        let size = editor.canvasSize(shortSide: CGFloat(gifSize))
        let videoComposition = try await Compositor.makeVideoComposition(for: composition, renderSize: size, fps: gifFPS, state: renderState)

        let generator = AVAssetImageGenerator(asset: composition)
        generator.videoComposition = videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let duration = editor.outputDuration
        let frameCount = max(1, Int(duration * Double(gifFPS)))
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frameCount, nil) else {
            throw OneshotError.exportFailed("Couldn't create the GIF file.")
        }
        let fileProperties = [kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFLoopCount as String: 0]]
        CGImageDestinationSetProperties(destination, fileProperties as CFDictionary)
        let delay = 1.0 / Double(gifFPS)
        let frameProperties = [kCGImagePropertyGIFDictionary as String: [
            kCGImagePropertyGIFDelayTime as String: delay,
            kCGImagePropertyGIFUnclampedDelayTime as String: delay,
        ]]

        for index in 0..<frameCount {
            try Task.checkCancellation()
            let time = cmTime(min(Double(index) * delay, max(0, duration - 0.001)))
            let (image, _) = try await generator.image(at: time)
            CGImageDestinationAddImage(destination, image, frameProperties as CFDictionary)
            state = .exporting(Double(index + 1) / Double(frameCount))
        }
        guard CGImageDestinationFinalize(destination) else {
            throw OneshotError.exportFailed("Couldn't finish writing the GIF.")
        }
    }
}
