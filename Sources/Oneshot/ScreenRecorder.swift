import AVFoundation
import ScreenCaptureKit

struct RecordingResult {
    /// Host-clock time (seconds) of the first video frame. Cursor data is aligned to this.
    let firstFrameTime: Double
    /// Host-clock time when recording stopped.
    let endTime: Double
}

/// Captures a rectangle of one display with ScreenCaptureKit (no cursor, it's recorded separately)
/// plus optional system audio and microphone, into a high-bitrate HEVC .mov.
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    /// Called on the main actor if capture stops on its own
    /// (for example from the system's screen recording indicator in the menu bar).
    var onUnexpectedStop: (@MainActor () -> Void)?

    let outputURL: URL
    private(set) var pixelSize: CGSize = .zero
    private(set) var hasSystemAudio = false
    private(set) var hasMicrophone = false

    private let queue = DispatchQueue(label: "oneshot.capture", qos: .userInteractive)
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var systemAudioInput: AVAssetWriterInput?
    private var microphoneInput: AVAssetWriterInput?
    private var firstFrameTime: Double?
    private var finished = false

    init(outputURL: URL) {
        self.outputURL = outputURL
        super.init()
    }

    /// - Parameters:
    ///   - sourceRect: area to record in display points, top-left origin.
    ///   - scale: the display's backing scale factor (2 on Retina).
    func start(display: SCDisplay,
               excluding apps: [SCRunningApplication],
               sourceRect: CGRect,
               scale: CGFloat,
               systemAudio: Bool,
               microphone: AVCaptureDevice?,
               maxFrameRate: Int = 120) async throws {
        let pixelWidth = max(2, Int((sourceRect.width * scale).rounded(.down)) & ~1)
        let pixelHeight = max(2, Int((sourceRect.height * scale).rounded(.down)) & ~1)
        pixelSize = CGSize(width: pixelWidth, height: pixelHeight)

        let config = SCStreamConfiguration()
        config.sourceRect = sourceRect
        config.width = pixelWidth
        config.height = pixelHeight
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(maxFrameRate))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = false // drawn later from the recorded cursor data
        config.queueDepth = 6
        config.capturesAudio = systemAudio
        config.sampleRate = 48_000
        config.channelCount = 2
        config.excludesCurrentProcessAudio = true
        if let microphone {
            config.captureMicrophone = true
            config.microphoneCaptureDeviceID = microphone.uniqueID
        }

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)

        let bitrate = min(150_000_000, max(12_000_000, Int(Double(pixelWidth * pixelHeight) * Double(maxFrameRate) * 0.07)))
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: pixelWidth,
            AVVideoHeightKey: pixelHeight,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: maxFrameRate,
                AVVideoMaxKeyFrameIntervalKey: maxFrameRate,
                AVVideoAllowFrameReorderingKey: false,
            ],
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else { throw OneshotError.writerFailed("Unsupported video settings.") }
        writer.add(videoInput)
        self.videoInput = videoInput

        // Track order in the file is video, system audio, microphone. The editor relies on it.
        if systemAudio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.audioSettings(channels: 2))
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                systemAudioInput = input
                hasSystemAudio = true
            }
        }
        if let microphone {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.audioSettings(channels: Self.channelCount(of: microphone)))
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                microphoneInput = input
                hasMicrophone = true
            }
        }

        guard writer.startWriting() else {
            throw OneshotError.writerFailed(writer.error?.localizedDescription ?? "Unknown error.")
        }
        self.writer = writer

        let filter = SCContentFilter(display: display, excludingApplications: apps, exceptingWindows: [])
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if systemAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        }
        if microphone != nil {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
        }
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async throws -> RecordingResult {
        if let stream { try? await stream.stopCapture() }
        stream = nil

        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                finished = true
                guard let writer, let firstFrameTime else {
                    writer?.cancelWriting()
                    continuation.resume(throwing: OneshotError.noFrames)
                    return
                }
                let endTime = hostTimeSeconds()
                videoInput?.markAsFinished()
                systemAudioInput?.markAsFinished()
                microphoneInput?.markAsFinished()
                // ScreenCaptureKit only delivers frames when something changes, so extend the
                // last frame up to "now" or a static ending would be cut short.
                writer.endSession(atSourceTime: CMTime(seconds: endTime, preferredTimescale: 1_000_000_000))
                writer.finishWriting {
                    if writer.status == .completed {
                        continuation.resume(returning: RecordingResult(firstFrameTime: firstFrameTime, endTime: endTime))
                    } else {
                        continuation.resume(throwing: OneshotError.writerFailed(writer.error?.localizedDescription ?? "Unknown error."))
                    }
                }
            }
        }
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !finished, sampleBuffer.isValid, let writer, writer.status == .writing else { return }

        switch type {
        case .screen:
            // Only "complete" frames carry new pixels; idle/blank frames are skipped.
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let rawStatus = attachments.first?[.status] as? Int,
                  let status = SCFrameStatus(rawValue: rawStatus),
                  status == .complete,
                  let videoInput else { return }
            if firstFrameTime == nil {
                writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
                firstFrameTime = sampleBuffer.presentationTimeStamp.seconds
            }
            if videoInput.isReadyForMoreMediaData {
                videoInput.append(sampleBuffer)
            }
        case .audio:
            appendAudio(sampleBuffer, to: systemAudioInput)
        case .microphone:
            appendAudio(sampleBuffer, to: microphoneInput)
        @unknown default:
            break
        }
    }

    private func appendAudio(_ sampleBuffer: CMSampleBuffer, to input: AVAssetWriterInput?) {
        guard firstFrameTime != nil, let input, input.isReadyForMoreMediaData else { return }
        input.append(sampleBuffer)
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let handler = onUnexpectedStop
        Task { @MainActor in handler?() }
    }

    // MARK: Helpers

    private static func audioSettings(channels: Int) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: channels == 1 ? 128_000 : 192_000,
        ]
    }

    private static func channelCount(of device: AVCaptureDevice) -> Int {
        let description = device.activeFormat.formatDescription
        if let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description) {
            return Int(min(max(basic.pointee.mChannelsPerFrame, 1), 2))
        }
        return 1
    }
}
