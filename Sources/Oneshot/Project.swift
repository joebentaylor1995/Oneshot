import Foundation
import CoreGraphics

// MARK: - Recording data (written once, when recording stops)

struct RecordingInfo: Codable {
    var pixelWidth: Int
    var pixelHeight: Int
    /// Screen points to video pixels (2 on Retina).
    var scale: Double
    var hasSystemAudio: Bool
    var hasMicrophone: Bool
    var duration: Double
    var createdAt: Date

    var sourceAspect: CGFloat {
        CGFloat(pixelWidth) / CGFloat(max(pixelHeight, 1))
    }
}

/// Cursor position, normalised to the recorded area (0...1, top-left origin). Time in seconds from the first frame.
struct CursorSample: Codable {
    var t: Double
    var x: Double
    var y: Double
}

struct ClickEvent: Codable {
    var t: Double
    var x: Double
    var y: Double
}

/// A cursor image as captured from the system. Sizes and hot spot are in points (hot spot from the top-left).
struct CursorShape: Codable {
    var file: String
    var hotX: Double
    var hotY: Double
    var width: Double
    var height: Double
}

struct CursorShapeChange: Codable {
    var t: Double
    var shape: Int
}

struct CursorTrack: Codable {
    var samples: [CursorSample] = []
    var clicks: [ClickEvent] = []
    var shapes: [CursorShape] = []
    var shapeChanges: [CursorShapeChange] = []

    func shifted(by offset: Double) -> CursorTrack {
        var copy = self
        copy.samples = samples.map { CursorSample(t: $0.t - offset, x: $0.x, y: $0.y) }
        copy.clicks = clicks.map { ClickEvent(t: $0.t - offset, x: $0.x, y: $0.y) }
        copy.shapeChanges = shapeChanges.map { CursorShapeChange(t: $0.t - offset, shape: $0.shape) }
        return copy
    }
}

// MARK: - Edits (saved continuously while editing)

enum AspectRatio: String, Codable, CaseIterable, Identifiable {
    case auto, wide, standard, square, vertical

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "Auto"
        case .wide: return "16:9"
        case .standard: return "4:3"
        case .square: return "1:1"
        case .vertical: return "9:16"
        }
    }

    func ratio(source: CGFloat) -> CGFloat {
        switch self {
        case .auto: return source
        case .wide: return 16.0 / 9.0
        case .standard: return 4.0 / 3.0
        case .square: return 1
        case .vertical: return 9.0 / 16.0
        }
    }
}

struct RGBColor: Codable, Equatable {
    var r: Double
    var g: Double
    var b: Double

    init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    init(hex: UInt32) {
        r = Double((hex >> 16) & 0xFF) / 255
        g = Double((hex >> 8) & 0xFF) / 255
        b = Double(hex & 0xFF) / 255
    }
}

enum BackgroundStyle: Codable, Equatable {
    case gradient(Int)
    case color(RGBColor)
    case wallpaper(String)
    case image(String)
}

enum ClickEffect: String, Codable, CaseIterable, Identifiable {
    /// Refractive shockwave: a glass-like ring spreads from the click and bends what it passes over.
    case lens
    case ripple, circle, none
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

struct StyleSettings: Codable, Equatable {
    var background: BackgroundStyle = .gradient(0)
    /// Fractions of the canvas' shorter side, so they look the same at every export size.
    var padding: Double = 0
    var cornerRadius: Double = 0.014
    var shadow: Double = 0.55
    var shadowSize: Double = 0.035
    var aspect: AspectRatio = .auto

    var showCursor = true
    var cursorScale: Double = 1.6
    var cursorSmoothing: Double = 0.6
    var motionBlur: Double = 0.5
    var clickEffect: ClickEffect = .lens
    var hideIdleCursor = true

    var cameraSmoothing: Double = 0.5

    var systemVolume: Double = 1
    var micVolume: Double = 1

    /// Seconds of fade from black at the start and to black at the end (video and audio).
    var fadeIn: Double = 0
    var fadeOut: Double = 0

    /// The fades for a video `total` seconds long, shortened in proportion if they'd overlap.
    func fadeDurations(total: Double) -> (fadeIn: Double, fadeOut: Double) {
        let fadeIn = max(0, self.fadeIn)
        let fadeOut = max(0, self.fadeOut)
        let sum = fadeIn + fadeOut
        guard sum > total, sum > 0 else { return (fadeIn, fadeOut) }
        let k = max(0, total) / sum
        return (fadeIn * k, fadeOut * k)
    }
}

extension StyleSettings {
    /// Settings missing from older edits files keep their defaults instead of failing the whole decode.
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func read<T: Decodable>(_ key: CodingKeys, into value: inout T) {
            if let decoded = try? c.decodeIfPresent(T.self, forKey: key) { value = decoded }
        }
        read(.background, into: &background)
        read(.padding, into: &padding)
        read(.cornerRadius, into: &cornerRadius)
        read(.shadow, into: &shadow)
        read(.shadowSize, into: &shadowSize)
        read(.aspect, into: &aspect)
        read(.showCursor, into: &showCursor)
        read(.cursorScale, into: &cursorScale)
        read(.cursorSmoothing, into: &cursorSmoothing)
        read(.motionBlur, into: &motionBlur)
        read(.clickEffect, into: &clickEffect)
        read(.hideIdleCursor, into: &hideIdleCursor)
        read(.cameraSmoothing, into: &cameraSmoothing)
        read(.systemVolume, into: &systemVolume)
        read(.micVolume, into: &micVolume)
        read(.fadeIn, into: &fadeIn)
        read(.fadeOut, into: &fadeOut)
    }
}

protocol TimedSegment: Identifiable where ID == UUID {
    var start: Double { get set }
    var end: Double { get set }
}

struct ZoomSegment: Codable, Equatable, TimedSegment {
    var id = UUID()
    var start: Double
    var end: Double
    var scale: Double = 2
    var followsCursor = true
    var focusX: Double = 0.5
    var focusY: Double = 0.5
    var isAuto = false
}

struct CutSegment: Codable, Equatable, TimedSegment {
    var id = UUID()
    var start: Double
    var end: Double
}

struct SpeedSegment: Codable, Equatable, TimedSegment {
    var id = UUID()
    var start: Double
    var end: Double
    var rate: Double = 2
}

struct ProjectEdits: Codable, Equatable {
    var style = StyleSettings()
    var zooms: [ZoomSegment] = []
    var cuts: [CutSegment] = []
    var speeds: [SpeedSegment] = []
    var trimStart: Double = 0
    var trimEnd: Double?
    var autoZoomGenerated = false
}

// MARK: - Project folder on disk

/// ~/Movies/Oneshot/Projects/Recording <date>/
///   screen.mov      video + system audio + microphone tracks
///   recording.json  RecordingInfo
///   cursor.json     CursorTrack
///   cursors/*.png   captured cursor images
///   edits.json      ProjectEdits (autosaved)
///   name.txt        the recording's name ("Untitled" until saved)
///   .draft          present until the recording is saved or exported; drafts are
///                   moved to the Trash when their editor closes
struct ProjectFolder: Equatable {
    let url: URL

    var videoURL: URL { url.appendingPathComponent("screen.mov") }
    var infoURL: URL { url.appendingPathComponent("recording.json") }
    var cursorURL: URL { url.appendingPathComponent("cursor.json") }
    var cursorsURL: URL { url.appendingPathComponent("cursors", isDirectory: true) }
    var editsURL: URL { url.appendingPathComponent("edits.json") }
    var nameURL: URL { url.appendingPathComponent("name.txt") }
    var draftURL: URL { url.appendingPathComponent(".draft") }

    static let defaultName = "Untitled"

    /// The recording's name; older recordings (before names existed) use their folder name.
    var displayName: String {
        if let name = try? String(contentsOf: nameURL, encoding: .utf8) {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return url.lastPathComponent
    }

    /// True until the recording is saved or exported.
    var isDraft: Bool { FileManager.default.fileExists(atPath: draftURL.path) }

    func rename(to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try? (trimmed.isEmpty ? Self.defaultName : trimmed).write(to: nameURL, atomically: true, encoding: .utf8)
    }

    /// Keeps the recording when its editor closes.
    func keep() { try? FileManager.default.removeItem(at: draftURL) }

    /// Moves an unsaved, unexported recording to the Trash (recoverable from there).
    func discardIfDraft() {
        guard isDraft else { return }
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    static func create(date: Date = Date()) throws -> ProjectFolder {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let url = Paths.projects.appendingPathComponent("Recording \(formatter.string(from: date))", isDirectory: true)
        let project = ProjectFolder(url: url)
        try FileManager.default.createDirectory(at: project.cursorsURL, withIntermediateDirectories: true)
        project.rename(to: defaultName)
        FileManager.default.createFile(atPath: project.draftURL.path, contents: Data())
        return project
    }

    static func recent(limit: Int = 8) -> [ProjectFolder] {
        let fileManager = FileManager.default
        guard let urls = try? fileManager.contentsOfDirectory(at: Paths.projects,
                                                              includingPropertiesForKeys: [.contentModificationDateKey],
                                                              options: [.skipsHiddenFiles]) else { return [] }
        func modified(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        return urls
            .filter { fileManager.fileExists(atPath: $0.appendingPathComponent("recording.json").path) }
            .sorted { modified($0) > modified($1) }
            .prefix(limit)
            .map { ProjectFolder(url: $0) }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    func save<T: Encodable>(_ value: T, to url: URL) throws {
        try Self.encoder.encode(value).write(to: url, options: .atomic)
    }

    func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.decoder.decode(type, from: data)
    }

    func loadInfo() -> RecordingInfo? { load(RecordingInfo.self, from: infoURL) }
    func loadCursor() -> CursorTrack? { load(CursorTrack.self, from: cursorURL) }
    func loadEdits() -> ProjectEdits? { load(ProjectEdits.self, from: editsURL) }
    func saveEdits(_ edits: ProjectEdits) { try? save(edits, to: editsURL) }
}
