import Foundation

/// Critically damped spring, integrated implicitly so it's stable at any stiffness.
/// Lower omega = smoother, lazier motion.
func springSmooth(_ values: [Double], dt: Double, omega: Double) -> [Double] {
    guard var x = values.first else { return [] }
    var v = 0.0
    let f = 1 + 2 * dt * omega
    let oo = omega * omega
    let hoo = dt * oo
    let hhoo = dt * hoo
    let detInv = 1 / (f + hhoo)
    var out: [Double] = []
    out.reserveCapacity(values.count)
    for target in values {
        let detX = f * x + dt * v + hhoo * target
        let detV = v + hoo * (target - x)
        x = detX * detInv
        v = detV * detInv
        out.append(x)
    }
    return out
}

/// The spring run forwards then backwards. Same smoothness, but no lag: the smoothed path
/// stays centred on the real one instead of trailing behind it.
func springSmoothZeroPhase(_ values: [Double], dt: Double, omega: Double) -> [Double] {
    let forward = springSmooth(values, dt: dt, omega: omega)
    return Array(springSmooth(Array(forward.reversed()), dt: dt, omega: omega).reversed())
}

/// Smoothed cursor path on a uniform 120 Hz grid, plus visibility for hide-when-idle.
struct CursorMotion {
    static let rate = 120.0

    var x: [Double]
    var y: [Double]
    var alpha: [Double]

    struct Sample {
        var x: Double
        var y: Double
        var alpha: Double
        /// Velocity in normalised units per second.
        var vx: Double
        var vy: Double
    }

    static func build(track: CursorTrack, duration: Double, smoothing: Double, hideIdle: Bool) -> CursorMotion {
        let count = max(2, Int(ceil(duration * rate)) + 1)
        let samples = track.samples
        guard !samples.isEmpty else {
            return CursorMotion(x: Array(repeating: 0.5, count: count),
                                y: Array(repeating: 0.5, count: count),
                                alpha: Array(repeating: 0, count: count))
        }

        // Resample to a uniform grid.
        var rawX = [Double](repeating: 0, count: count)
        var rawY = [Double](repeating: 0, count: count)
        var j = 0
        for i in 0..<count {
            let t = Double(i) / rate
            while j + 1 < samples.count && samples[j + 1].t <= t { j += 1 }
            let a = samples[j]
            if j + 1 < samples.count, t > a.t {
                let b = samples[j + 1]
                let f = (t - a.t) / max(b.t - a.t, 1e-6)
                rawX[i] = a.x + (b.x - a.x) * f
                rawY[i] = a.y + (b.y - a.y) * f
            } else {
                rawX[i] = a.x
                rawY[i] = a.y
            }
        }

        // 0 → nearly raw (omega 70), 1 → very floaty (omega ~6). Two passes, so each pass is stiffer.
        let omega = 70 * pow(0.08, clamp(smoothing, 0, 1))
        let dt = 1 / rate
        let smoothX = springSmoothZeroPhase(rawX, dt: dt, omega: omega)
        let smoothY = springSmoothZeroPhase(rawY, dt: dt, omega: omega)

        var alpha = [Double](repeating: 1, count: count)
        if hideIdle {
            var lastMove = 0.0
            var value = 1.0
            for i in 0..<count {
                let t = Double(i) / rate
                if i > 0 && hypot(rawX[i] - rawX[i - 1], rawY[i] - rawY[i - 1]) > 0.0004 { lastMove = t }
                let target = (t - lastMove) > 1.5 ? 0.0 : 1.0
                if target > value {
                    value = min(target, value + dt / 0.12)
                } else {
                    value = max(target, value - dt / 0.35)
                }
                alpha[i] = value
            }
        }
        return CursorMotion(x: smoothX, y: smoothY, alpha: alpha)
    }

    func sample(at t: Double) -> Sample {
        let last = x.count - 1
        let f = clamp(t * Self.rate, 0, Double(last))
        let i = Int(f)
        let i1 = min(i + 1, last)
        let w = f - Double(i)
        let i0 = max(i - 1, 0)
        let i2 = min(i + 1, last)
        let span = Double(max(i2 - i0, 1)) / Self.rate
        return Sample(x: x[i] + (x[i1] - x[i]) * w,
                      y: y[i] + (y[i1] - y[i]) * w,
                      alpha: alpha[i] + (alpha[i1] - alpha[i]) * w,
                      vx: (x[i2] - x[i0]) / span,
                      vy: (y[i2] - y[i0]) / span)
    }
}

/// Zoom level and focus point over time on a 60 Hz grid.
struct CameraMotion {
    static let rate = 60.0
    static let transition = 0.75

    var scale: [Double]
    var x: [Double]
    var y: [Double]

    struct Frame {
        var scale: Double
        /// Focus in normalised source coordinates (top-left origin).
        var x: Double
        var y: Double
    }

    static func build(zooms: [ZoomSegment], cursor: CursorMotion, duration: Double, smoothing: Double) -> CameraMotion {
        let count = max(2, Int(ceil(duration * rate)) + 1)
        var scale = [Double](repeating: 1, count: count)
        var focusX = [Double](repeating: 0.5, count: count)
        var focusY = [Double](repeating: 0.5, count: count)
        let sorted = zooms.sorted { $0.start < $1.start }

        for i in 0..<count {
            let t = Double(i) / rate
            let c = cursor.sample(at: t)
            var best = 1.0
            var focus = (c.x, c.y)
            for zoom in sorted where t >= zoom.start && t <= zoom.end {
                let ramp = min(transition, (zoom.end - zoom.start) / 2)
                let rampIn = Ease.inOutCubic(clamp((t - zoom.start) / ramp, 0, 1))
                let rampOut = Ease.inOutCubic(clamp((zoom.end - t) / ramp, 0, 1))
                let value = 1 + (zoom.scale - 1) * min(rampIn, rampOut)
                if value > best {
                    best = value
                    focus = zoom.followsCursor ? (c.x, c.y) : (zoom.focusX, zoom.focusY)
                }
            }
            scale[i] = best
            focusX[i] = clamp(focus.0, 0, 1)
            focusY[i] = clamp(focus.1, 0, 1)
        }

        // 0 → snappy camera (omega 20), 1 → slow, cinematic (omega 4). Zero-phase, so the camera
        // eases toward where the cursor is going instead of chasing where it was.
        let omega = 20 * pow(0.2, clamp(smoothing, 0, 1))
        return CameraMotion(scale: scale,
                            x: springSmoothZeroPhase(focusX, dt: 1 / rate, omega: omega),
                            y: springSmoothZeroPhase(focusY, dt: 1 / rate, omega: omega))
    }

    func frame(at t: Double) -> Frame {
        let last = scale.count - 1
        let f = clamp(t * Self.rate, 0, Double(last))
        let i = Int(f)
        let i1 = min(i + 1, last)
        let w = f - Double(i)
        return Frame(scale: scale[i] + (scale[i1] - scale[i]) * w,
                     x: x[i] + (x[i1] - x[i]) * w,
                     y: y[i] + (y[i1] - y[i]) * w)
    }
}

/// Screen Studio style automatic zooms: cluster clicks that happen close together
/// and zoom in slightly before the first one, out a beat after the last.
enum AutoZoom {
    static func generate(clicks: [ClickEvent], duration: Double, scale: Double = 2) -> [ZoomSegment] {
        let valid = clicks
            .filter { $0.t >= 0 && $0.t <= duration && (0...1).contains($0.x) && (0...1).contains($0.y) }
            .sorted { $0.t < $1.t }

        var groups: [[ClickEvent]] = []
        for click in valid {
            if let last = groups.last?.last, click.t - last.t < 3 {
                groups[groups.count - 1].append(click)
            } else {
                groups.append([click])
            }
        }

        var zooms: [ZoomSegment] = []
        for group in groups {
            guard let first = group.first, let last = group.last else { continue }
            let start = max(0, first.t - 0.9)
            let end = min(duration, last.t + 2.2)
            guard end - start > 1 else { continue }
            if var previous = zooms.last, start < previous.end + 0.8 {
                previous.end = end
                zooms[zooms.count - 1] = previous
            } else {
                zooms.append(ZoomSegment(start: start, end: end, scale: scale, isAuto: true))
            }
        }
        return zooms
    }
}
