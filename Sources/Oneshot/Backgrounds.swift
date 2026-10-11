import CoreImage
import ImageIO
import SwiftUI

enum Backgrounds {
    struct Gradient {
        let name: String
        let a: RGBColor
        let b: RGBColor
    }

    static let gradients: [Gradient] = [
        Gradient(name: "Dusk", a: RGBColor(hex: 0x8E2DE2), b: RGBColor(hex: 0x4A00E0)),
        Gradient(name: "Electric", a: RGBColor(hex: 0x1653FF), b: RGBColor(hex: 0x121212)),
        Gradient(name: "Sunset", a: RGBColor(hex: 0xFF7E5F), b: RGBColor(hex: 0xFEB47B)),
        Gradient(name: "Ocean", a: RGBColor(hex: 0x2E3192), b: RGBColor(hex: 0x1BFFFF)),
        Gradient(name: "Mint", a: RGBColor(hex: 0x43E97B), b: RGBColor(hex: 0x38F9D7)),
        Gradient(name: "Candy", a: RGBColor(hex: 0xF857A6), b: RGBColor(hex: 0xFF5858)),
        Gradient(name: "Lavender", a: RGBColor(hex: 0xE0C3FC), b: RGBColor(hex: 0x8EC5FC)),
        Gradient(name: "Peach", a: RGBColor(hex: 0xFFDEE9), b: RGBColor(hex: 0xB5FFFC)),
        Gradient(name: "Night", a: RGBColor(hex: 0x0F2027), b: RGBColor(hex: 0x2C5364)),
        Gradient(name: "Graphite", a: RGBColor(hex: 0x232526), b: RGBColor(hex: 0x414345)),
    ]

    static func gradient(at index: Int) -> Gradient {
        gradients[((index % gradients.count) + gradients.count) % gradients.count]
    }

    static func gradientImage(index: Int, size: CGSize) -> CIImage {
        let gradient = gradient(at: index)
        let filter = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: size.height),
            "inputPoint1": CIVector(x: size.width, y: 0),
            "inputColor0": gradient.a.ciColor,
            "inputColor1": gradient.b.ciColor,
        ])
        return (filter?.outputImage ?? CIImage(color: .black)).cropped(to: CGRect(origin: .zero, size: size))
    }

    static func aspectFill(_ image: CIImage, size: CGSize) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: size)) }
        let k = max(size.width / extent.width, size.height / extent.height)
        let dx = (extent.width * k - size.width) / 2
        let dy = (extent.height * k - size.height) / 2
        let transform = CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
            .concatenating(CGAffineTransform(scaleX: k, y: k))
            .concatenating(CGAffineTransform(translationX: -dx, y: -dy))
        return image.clampedToExtent().transformed(by: transform).cropped(to: CGRect(origin: .zero, size: size))
    }

    /// The Mac's built-in desktop pictures.
    static let wallpapers: [URL] = {
        let folder = URL(fileURLWithPath: "/System/Library/Desktop Pictures", isDirectory: true)
        let allowed: Set<String> = ["heic", "jpg", "jpeg", "png"]
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return urls
            .filter { allowed.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }()

    /// Downsampled image via ImageIO (fast, low memory, works for HEIC).
    static func loadImage(at url: URL, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

extension RGBColor {
    var ciColor: CIColor { CIColor(red: CGFloat(r), green: CGFloat(g), blue: CGFloat(b)) }
    var color: Color { Color(red: r, green: g, blue: b) }

    init(color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
        self.init(r: Double(ns.redComponent), g: Double(ns.greenComponent), b: Double(ns.blueComponent))
    }
}
