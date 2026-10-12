import AppKit
import CoreGraphics
import CoreMedia
import ImageIO
import UniformTypeIdentifiers

enum OneshotError: LocalizedError {
    case displayNotFound
    case noFrames
    case writerFailed(String)
    case noVideoTrack
    case exportFailed(String)
    case projectUnreadable

    var errorDescription: String? {
        switch self {
        case .displayNotFound: return "Couldn't find the display you selected."
        case .noFrames: return "No frames were captured."
        case .writerFailed(let message): return "Couldn't save the recording. \(message)"
        case .noVideoTrack: return "The recording has no video track."
        case .exportFailed(let message): return "Export failed. \(message)"
        case .projectUnreadable: return "This project couldn't be opened."
        }
    }
}

enum Paths {
    /// ~/Movies/Oneshot. Not a privacy-protected folder, so no extra permission prompts.
    static var root: URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        let folder = movies.appendingPathComponent("Oneshot", isDirectory: true)
        let fileManager = FileManager.default
        // The app used to be called Reel: carry its recordings over the first time.
        let legacy = movies.appendingPathComponent("Reel", isDirectory: true)
        if !fileManager.fileExists(atPath: folder.path), fileManager.fileExists(atPath: legacy.path) {
            try? fileManager.moveItem(at: legacy, to: folder)
        }
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static var projects: URL {
        let folder = root.appendingPathComponent("Projects", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// ~/Movies/Oneshot/<name>.mp4, or "<name> 2.mp4", "<name> 3.mp4"… if that's taken.
    static func exportURL(name: String, fileExtension: String) -> URL {
        let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        var url = root.appendingPathComponent(safe).appendingPathExtension(fileExtension)
        var index = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = root.appendingPathComponent("\(safe) \(index)").appendingPathExtension(fileExtension)
            index += 1
        }
        return url
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

func clamp<T: Comparable>(_ value: T, _ low: T, _ high: T) -> T {
    min(max(value, low), high)
}

func cmTime(_ seconds: Double) -> CMTime {
    CMTime(seconds: seconds, preferredTimescale: 60_000)
}

func hostTimeSeconds() -> Double {
    CMClockGetTime(CMClockGetHostTimeClock()).seconds
}

/// 0:03.25 style timestamps.
func formatTime(_ seconds: Double) -> String {
    let t = seconds.isFinite ? max(0, seconds) : 0
    let minutes = Int(t) / 60
    let rest = t - Double(minutes * 60)
    return String(format: "%d:%05.2f", minutes, rest)
}

/// 0:05 style timestamps for the ruler.
func formatShortTime(_ seconds: Double) -> String {
    let t = Int(max(0, seconds.rounded()))
    return String(format: "%d:%02d", t / 60, t % 60)
}

func evenFloor(_ value: CGFloat) -> CGFloat {
    CGFloat(max(2, Int(value) & ~1))
}

enum Ease {
    static func inOutCubic(_ x: Double) -> Double {
        x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
    }

    static func outCubic(_ x: Double) -> Double {
        1 - pow(1 - x, 3)
    }
}

/// Draws an NSImage (e.g. a cursor) into a high-resolution bitmap and returns it with a content hash.
func rasterize(_ image: NSImage, scale: CGFloat) -> (image: CGImage, hash: Int)? {
    let width = Int(ceil(image.size.width * scale))
    let height = Int(ceil(image.size.height * scale))
    guard width > 0, height > 0,
          let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    context.scaleBy(x: scale, y: scale)
    image.draw(in: CGRect(origin: .zero, size: image.size))
    NSGraphicsContext.restoreGraphicsState()
    guard let cgImage = context.makeImage(), let data = context.data else { return nil }
    var hasher = Hasher()
    hasher.combine(bytes: UnsafeRawBufferPointer(start: data, count: width * height * 4))
    hasher.combine(width)
    hasher.combine(height)
    return (cgImage, hasher.finalize())
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}
