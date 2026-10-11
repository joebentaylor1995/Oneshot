import CoreImage

/// Screen Studio style "lens" click: a ring of glass expands from the click point, magnifying
/// whatever it passes over with a slight colour split (orange inside, blue outside), and fades out.
enum LensRipple {
    static let duration = 0.6

    /// Pulls samples toward the ring's centre line, so content inside the band is magnified like
    /// a lens. `x` is the signed distance across the band in band-widths; outside |x| ≈ 3 it's a no-op.
    private static let kernel: CIWarpKernel? = CIWarpKernel(source: """
    kernel vec2 oneshotLensRipple(vec2 center, float radius, float width, float strength) {
        vec2 p = destCoord();
        vec2 d = p - center;
        float dist = length(d);
        float x = (dist - radius) / width;
        float g = exp(-x * x * 2.0);
        vec2 dir = dist > 0.001 ? d / dist : vec2(0.0, 0.0);
        return p - dir * (strength * width * x * g);
    }
    """)

    /// - Parameters:
    ///   - progress: 0…1 through the effect's life.
    ///   - scale: canvas short side in pixels; sizes are relative to it so every export size matches.
    static func apply(to image: CIImage, center: CGPoint, progress: Double, scale: CGFloat) -> CIImage {
        guard progress >= 0, progress < 1 else { return image }
        let p = CGFloat(progress)
        let eased = CGFloat(Ease.outCubic(progress))

        let radius = scale * (0.03 + 0.30 * eased)
        let width = scale * (0.035 + 0.035 * eased)
        // Strong at first, gone by the end.
        let strength = 1.1 * pow(1 - p, 1.6)
        guard strength > 0.01 else { return image }

        guard let kernel else {
            // Fallback if Core Image kernels are unavailable: a soft expanding bulge.
            return image.applyingFilter("CIBumpDistortion", parameters: [
                kCIInputCenterKey: CIVector(cgPoint: center),
                kCIInputRadiusKey: radius + width,
                kCIInputScaleKey: 0.25 * strength,
            ]).cropped(to: image.extent)
        }

        // Only the band around the ring changes; work on that patch and lay it back over the frame.
        let reach = radius + width * 3
        let area = CGRect(x: center.x - reach, y: center.y - reach, width: reach * 2, height: reach * 2)
            .intersection(image.extent)
        guard !area.isNull, area.width > 1, area.height > 1 else { return image }

        let maxShift = strength * width * 0.5 + 2
        let source = image.clampedToExtent()
        func warped(_ s: CGFloat) -> CIImage? {
            kernel.apply(extent: area,
                         roiCallback: { _, rect in rect.insetBy(dx: -maxShift * 1.4, dy: -maxShift * 1.4) },
                         image: source,
                         arguments: [CIVector(cgPoint: center), radius, width, s])
        }
        // Each colour channel refracts by a slightly different amount (chromatic dispersion).
        guard let red = warped(strength * 1.25), let green = warped(strength), let blue = warped(strength * 0.75) else {
            return image
        }
        let r = red.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
        let g = green.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
        ])
        let b = blue.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 1, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
        ])
        let combined = r
            .applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: g])
            .applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: b])
            .cropped(to: area)
        return combined.composited(over: image)
    }
}
