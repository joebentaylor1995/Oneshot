import AVFoundation

/// Peak levels of a recording's audio for the timeline's audio track.
enum Waveform {
    static let bucketsPerSecond = 20.0

    /// One level (0…1) per 1/20 s across the whole recording, with every audio track
    /// (system audio and microphone) mixed together. Empty if there's no audio.
    static func load(from asset: AVAsset, duration: Double) async -> [Float] {
        guard duration > 0,
              let tracks = try? await asset.loadTracks(withMediaType: .audio),
              !tracks.isEmpty else { return [] }
        return await Task.detached(priority: .utility) {
            read(asset: asset, tracks: tracks, duration: duration)
        }.value
    }

    private static func read(asset: AVAsset, tracks: [AVAssetTrack], duration: Double) -> [Float] {
        guard let reader = try? AVAssetReader(asset: asset) else { return [] }
        let sampleRate = 8_000.0
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: sampleRate,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        guard reader.startReading() else { return [] }

        let count = max(1, Int((duration * bucketsPerSecond).rounded(.up)))
        var peaks = [Int32](repeating: 0, count: count)
        let samplesPerBucket = sampleRate / bucketsPerSecond
        var position = 0.0

        while let buffer = output.copyNextSampleBuffer() {
            let start = CMSampleBufferGetPresentationTimeStamp(buffer)
            if start.isValid { position = start.seconds * sampleRate }
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            guard length >= 2 else { continue }
            var samples = [Int16](repeating: 0, count: length / 2)
            let status = samples.withUnsafeMutableBytes { raw in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: samples.count * 2, destination: raw.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else { continue }
            for sample in samples {
                let bucket = Int(position / samplesPerBucket)
                if bucket >= 0 && bucket < count {
                    let level = abs(Int32(sample))
                    if level > peaks[bucket] { peaks[bucket] = level }
                }
                position += 1
            }
        }
        guard reader.status == .completed || reader.status == .reading else { return [] }
        // Square-root scaling so quiet speech is still visible next to loud system audio.
        return peaks.map { Float((Double($0) / 32_768).squareRoot()) }
    }
}
