import AVFoundation

/// A kept slice of the source recording, played at `rate`, placed at `compStart` in the output.
struct TimePiece: Equatable {
    var sourceStart: Double
    var sourceEnd: Double
    var rate: Double
    var compStart: Double

    var compDuration: Double { (sourceEnd - sourceStart) / rate }
    var compEnd: Double { compStart + compDuration }
}

/// Maps between source time (the raw recording) and output time after trim, cuts and speed changes.
/// Zooms and cursor data stay in source time, so editing cuts never shifts them.
struct TimeMapping: Equatable {
    var pieces: [TimePiece]

    var duration: Double { pieces.last?.compEnd ?? 0 }

    static func build(edits: ProjectEdits, sourceDuration: Double) -> TimeMapping {
        let start = clamp(edits.trimStart, 0, sourceDuration)
        let end = clamp(edits.trimEnd ?? sourceDuration, start, sourceDuration)

        // Kept ranges: trim range minus cuts.
        var kept: [(Double, Double)] = [(start, end)]
        for cut in edits.cuts.sorted(by: { $0.start < $1.start }) {
            kept = kept.flatMap { range -> [(Double, Double)] in
                if cut.end <= range.0 || cut.start >= range.1 { return [range] }
                var parts: [(Double, Double)] = []
                if cut.start > range.0 { parts.append((range.0, cut.start)) }
                if cut.end < range.1 { parts.append((cut.end, range.1)) }
                return parts
            }
        }

        // Split at speed boundaries and assign rates.
        let boundaries = edits.speeds.flatMap { [$0.start, $0.end] }
        var pieces: [TimePiece] = []
        var cursor = 0.0
        for range in kept {
            var marks = [range.0, range.1] + boundaries.filter { $0 > range.0 && $0 < range.1 }
            marks.sort()
            for index in 0..<(marks.count - 1) {
                let a = marks[index]
                let b = marks[index + 1]
                guard b - a > 1.0 / 240 else { continue }
                let mid = (a + b) / 2
                let rate = edits.speeds.filter { $0.start <= mid && mid < $0.end }.map(\.rate).max() ?? 1
                if var last = pieces.last, last.rate == rate, abs(last.sourceEnd - a) < 1e-9 {
                    last.sourceEnd = b
                    pieces[pieces.count - 1] = last
                    cursor = last.compEnd
                } else {
                    let piece = TimePiece(sourceStart: a, sourceEnd: b, rate: rate, compStart: cursor)
                    pieces.append(piece)
                    cursor = piece.compEnd
                }
            }
        }
        if pieces.isEmpty {
            pieces = [TimePiece(sourceStart: 0, sourceEnd: max(sourceDuration, 0.1), rate: 1, compStart: 0)]
        }
        return TimeMapping(pieces: pieces)
    }

    func sourceTime(forComposition t: Double) -> Double {
        guard let first = pieces.first else { return t }
        if t <= first.compStart { return first.sourceStart }
        var low = 0
        var high = pieces.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if pieces[mid].compStart <= t { low = mid } else { high = mid - 1 }
        }
        let piece = pieces[low]
        return min(piece.sourceEnd, piece.sourceStart + (t - piece.compStart) * piece.rate)
    }

    /// Output time for a source time. Times inside a cut snap to the next kept piece.
    func compositionTime(forSource s: Double) -> Double {
        for piece in pieces {
            if s < piece.sourceStart { return piece.compStart }
            if s <= piece.sourceEnd { return piece.compStart + (s - piece.sourceStart) / piece.rate }
        }
        return duration
    }
}

enum CompositionBuilder {
    /// Builds the trimmed, cut and speed-adjusted composition (video + audio tracks) from the raw recording.
    static func build(source: AVAsset, mapping: TimeMapping) async throws -> AVMutableComposition {
        let composition = AVMutableComposition()
        guard let sourceVideo = try await source.loadTracks(withMediaType: .video).first else { throw OneshotError.noVideoTrack }
        let videoRange = try await sourceVideo.load(.timeRange)
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw OneshotError.noVideoTrack
        }

        var audio: [(source: AVAssetTrack, range: CMTimeRange, target: AVMutableCompositionTrack)] = []
        for track in try await source.loadTracks(withMediaType: .audio) {
            guard let target = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            let range = try await track.load(.timeRange)
            audio.append((source: track, range: range, target: target))
        }

        var cursor = CMTime.zero
        for piece in mapping.pieces {
            let range = CMTimeRange(start: cmTime(piece.sourceStart), end: cmTime(piece.sourceEnd)).intersection(videoRange)
            guard range.duration > .zero else { continue }
            try videoTrack.insertTimeRange(range, of: sourceVideo, at: cursor)
            for entry in audio {
                let audioRange = range.intersection(entry.range)
                guard audioRange.duration > .zero else { continue }
                try entry.target.insertTimeRange(audioRange, of: entry.source, at: cursor + (audioRange.start - range.start))
            }
            if piece.rate != 1 {
                let scaled = CMTime(seconds: range.duration.seconds / piece.rate, preferredTimescale: 60_000)
                composition.scaleTimeRange(CMTimeRange(start: cursor, duration: range.duration), toDuration: scaled)
                cursor = cursor + scaled
            } else {
                cursor = cursor + range.duration
            }
        }
        return composition
    }

    /// Volumes for the system audio and microphone tracks (in that order, as recorded).
    static func audioMix(for composition: AVMutableComposition, info: RecordingInfo, style: StyleSettings) -> AVAudioMix? {
        let tracks = composition.tracks(withMediaType: .audio)
        guard !tracks.isEmpty else { return nil }
        var volumes: [Float] = []
        if info.hasSystemAudio { volumes.append(Float(style.systemVolume)) }
        if info.hasMicrophone { volumes.append(Float(style.micVolume)) }
        let mix = AVMutableAudioMix()
        mix.inputParameters = tracks.enumerated().map { index, track in
            let parameters = AVMutableAudioMixInputParameters(track: track)
            parameters.setVolume(index < volumes.count ? volumes[index] : 1, at: .zero)
            return parameters
        }
        return mix
    }
}
