import CoreGraphics
import Foundation

struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) {
        state = seed &+ 0x9E37_79B9_7F4A_7C15
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// A colour of the body's palette: soft pinks, ivory, peach, coral, amber and deeper organic reds.
struct Tone {
    var r: CGFloat
    var g: CGFloat
    var b: CGFloat

    static let ivory = Tone(r: 0.99, g: 0.93, b: 0.84)
    static let peach = Tone(r: 1.0, g: 0.78, b: 0.63)
    static let blush = Tone(r: 0.97, g: 0.71, b: 0.70)
    static let coral = Tone(r: 0.93, g: 0.47, b: 0.38)
    static let amber = Tone(r: 0.98, g: 0.66, b: 0.30)
    static let crimson = Tone(r: 0.62, g: 0.06, b: 0.14)
    static let wine = Tone(r: 0.33, g: 0.03, b: 0.07)
    static let night = Tone(r: 0.09, g: 0.01, b: 0.03)

    func mixed(with other: Tone, _ t: CGFloat) -> Tone {
        Tone(r: r + (other.r - r) * t, g: g + (other.g - g) * t, b: b + (other.b - b) * t)
    }

    func cg(_ alpha: CGFloat = 1) -> CGColor {
        CGColor(red: r, green: g, blue: b, alpha: alpha)
    }
}

/// Paints the pictures that wrap around the viewer once they are inside the body. Plain Core Graphics, so it can
/// run off the main thread. Pictures are equirectangular: x runs once around, y from straight up to straight down.
enum BodyPainting {
    /// Every picture is laid out on this many points; `detail` sets how many pixels each point gets.
    static let canvas = CGSize(width: 2048, height: 1024)

    /// The far wall: backlit tissue in peach and coral, packed with veined cells, crimson stains, fibre bundles
    /// and floating bubbles, darkening towards the depths above and below.
    static func backdrop(detail: CGFloat) -> CGImage? {
        guard let canvas = Canvas(detail: detail) else { return nil }
        var generator = SeededGenerator(seed: 7)
        canvas.paintBase()
        canvas.paintGlows(&generator)
        canvas.paintStains(&generator)
        canvas.paintTissueVeins(&generator)
        canvas.paintCells(&generator)
        canvas.paintFibres(&generator)
        canvas.paintBubbles(&generator, count: 170)
        canvas.paintBokeh(&generator)
        canvas.paintDepths()
        return canvas.cg.makeImage()
    }

    /// A see-through layer in front of the wall: branching vessels, webbing and specks, on a clear background.
    static func veil(detail: CGFloat) -> CGImage? {
        guard let canvas = Canvas(detail: detail, clear: true) else { return nil }
        var generator = SeededGenerator(seed: 23)
        canvas.paintWebs(&generator)
        canvas.paintVessels(&generator)
        canvas.paintBubbles(&generator, count: 40)
        canvas.paintSpecks(&generator)
        return canvas.cg.makeImage()
    }

    /// Soft, even, nearly white light from all around, a little brighter above, for the cell inside the dark body.
    static func cellLight() -> CGImage? {
        guard let canvas = Canvas(detail: 0.125) else { return nil }
        let light = canvas.gradient([
            (0, CGColor(red: 1, green: 1, blue: 1, alpha: 1)),
            (0.5, CGColor(red: 0.95, green: 0.93, blue: 0.91, alpha: 1)),
            (1, CGColor(red: 0.7, green: 0.66, blue: 0.64, alpha: 1)),
        ])
        canvas.cg.drawLinearGradient(light, start: .zero, end: CGPoint(x: 0, y: canvas.size.height), options: [])
        return canvas.cg.makeImage()
    }

    /// A small, brightened copy of the wall for image-based lighting, with a soft overhead glow so glossy surfaces
    /// catch highlights on top.
    static func lighting(from backdrop: CGImage) -> CGImage? {
        guard let canvas = Canvas(detail: 0.5) else { return nil }
        let size = canvas.size
        canvas.cg.saveGState()
        canvas.cg.translateBy(x: 0, y: size.height)
        canvas.cg.scaleBy(x: 1, y: -1)
        canvas.cg.draw(backdrop, in: CGRect(origin: .zero, size: size))
        canvas.cg.restoreGState()
        let glow = canvas.gradient([(0, Tone.ivory.cg(0.95)), (0.22, Tone.peach.cg(0.7)), (0.5, Tone.peach.cg(0))])
        canvas.cg.drawLinearGradient(glow, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
        return canvas.cg.makeImage()
    }
}

private final class Canvas {
    let cg: CGContext
    let size = BodyPainting.canvas
    private let space = CGColorSpace(name: CGColorSpace.sRGB)!

    init?(detail: CGFloat, clear: Bool = false) {
        let width = Int(size.width * detail)
        let height = Int(size.height * detail)
        guard let cg = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        self.cg = cg
        // Top-left origin, in points.
        cg.translateBy(x: 0, y: CGFloat(height))
        cg.scaleBy(x: detail, y: -detail)
        cg.setLineCap(.round)
        cg.setLineJoin(.round)
        if clear {
            cg.clear(CGRect(origin: .zero, size: size))
        }
    }

    // MARK: Helpers

    func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
        CGGradient(colorsSpace: space, colors: stops.map(\.1) as CFArray, locations: stops.map(\.0))!
    }

    /// How much wider than tall a shape must be drawn at height `y` to look round once wrapped on the sphere.
    func stretch(at y: CGFloat) -> CGFloat {
        let latitude = (0.5 - y / size.height) * .pi
        return min(1 / max(cos(latitude), 0.01), 4)
    }

    /// 0 around the horizon, 1 straight up or down.
    func depth(at y: CGFloat) -> CGFloat {
        abs(y / size.height - 0.5) * 2
    }

    /// Anything crossing the left or right edge is drawn again on the other side, so the seam doesn't show.
    func wrapped(_ x: CGFloat, reach: CGFloat, draw: (CGFloat) -> Void) {
        draw(x)
        if x - reach < 0 { draw(x + size.width) }
        if x + reach > size.width { draw(x - size.width) }
    }

    /// Draws in a frame centred on `point` and widened by the stretch there, so a circle of radius r comes out round.
    func local(at point: CGPoint, reach: CGFloat, rotation: CGFloat = 0, draw: () -> Void) {
        let k = stretch(at: point.y)
        wrapped(point.x, reach: reach * k) { x in
            cg.saveGState()
            cg.translateBy(x: x, y: point.y)
            cg.scaleBy(x: k, y: 1)
            cg.rotate(by: rotation)
            draw()
            cg.restoreGState()
        }
    }

    func softDot(radius: CGFloat, color: Tone, alpha: CGFloat) {
        let glow = gradient([(0, color.cg(alpha)), (1, color.cg(0))])
        cg.drawRadialGradient(glow, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: radius, options: [])
    }

    private static func smoothstep(_ a: CGFloat, _ b: CGFloat, _ x: CGFloat) -> CGFloat {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }

    private static func gaussian(_ generator: inout SeededGenerator) -> CGFloat {
        let u = CGFloat.random(in: 0.0001...1, using: &generator)
        let v = CGFloat.random(in: 0...1, using: &generator)
        return sqrt(-2 * log(u)) * cos(2 * .pi * v)
    }

    // MARK: Backdrop

    func paintBase() {
        let base = gradient([
            (0.0, Tone.night.cg()),
            (0.16, Tone.wine.cg()),
            (0.34, Tone.crimson.mixed(with: .coral, 0.55).cg()),
            (0.47, Tone.coral.mixed(with: .peach, 0.45).cg()),
            (0.55, Tone.coral.mixed(with: .peach, 0.2).cg()),
            (0.68, Tone.crimson.mixed(with: .coral, 0.4).cg()),
            (0.84, Tone.wine.cg()),
            (1.0, Tone.night.cg()),
        ])
        cg.drawLinearGradient(base, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
    }

    /// Light shining through thinner tissue, and darker, denser patches.
    func paintGlows(_ generator: inout SeededGenerator) {
        for _ in 0..<44 {
            let y = size.height * (0.5 + 0.36 * CGFloat.random(in: -1...1, using: &generator))
            let point = CGPoint(x: .random(in: 0...size.width, using: &generator), y: y)
            let radius = CGFloat.random(in: 70...300, using: &generator)
            let light = Bool.random(using: &generator)
            let tone = light ? (Bool.random(using: &generator) ? Tone.amber : Tone.ivory) : Tone.wine
            let alpha = light
                ? CGFloat.random(in: 0.18...0.42, using: &generator) * (1 - depth(at: y) * 0.7)
                : CGFloat.random(in: 0.2...0.45, using: &generator)
            local(at: point, reach: radius) {
                softDot(radius: radius, color: tone, alpha: alpha)
            }
        }
    }

    /// Grainy crimson stains spreading through the tissue, like dye under a microscope.
    func paintStains(_ generator: inout SeededGenerator) {
        for _ in 0..<34 {
            let center = CGPoint(
                x: .random(in: 0...size.width, using: &generator),
                y: size.height * .random(in: 0.18...0.82, using: &generator))
            let along = CGFloat.random(in: 30...140, using: &generator)
            let across = along * .random(in: 0.25...0.8, using: &generator)
            let angle = CGFloat.random(in: 0...(.pi), using: &generator)
            let dots = Int.random(in: 1500...3000, using: &generator)
            let tones = [Tone.crimson, Tone.crimson.mixed(with: .wine, 0.5), Tone.coral.mixed(with: .crimson, 0.5)]
            var paths = tones.map { _ in CGMutablePath() }
            let k = stretch(at: center.y)
            for _ in 0..<dots {
                let a = Self.gaussian(&generator) * along
                let b = Self.gaussian(&generator) * across
                let x = a * cos(angle) - b * sin(angle)
                let y = a * sin(angle) + b * cos(angle)
                let r = CGFloat.random(in: 0.3...1.5, using: &generator)
                let spot = CGRect(x: center.x + x * k - r, y: center.y + y - r, width: 2 * r, height: 2 * r)
                paths[Int.random(in: 0..<paths.count, using: &generator)].addEllipse(in: spot)
            }
            for (index, path) in paths.enumerated() {
                let alpha = CGFloat.random(in: 0.3...0.6, using: &generator)
                wrapped(center.x, reach: along * 3 * k) { x in
                    cg.saveGState()
                    cg.translateBy(x: x - center.x, y: 0)
                    cg.addPath(path)
                    cg.setFillColor(tones[index].cg(alpha))
                    cg.fillPath()
                    cg.restoreGState()
                }
            }
            paths.removeAll()
        }
    }

    /// A dense red network of vessels in the tissue, showing in the gaps between cells.
    func paintTissueVeins(_ generator: inout SeededGenerator) {
        for _ in 0..<240 {
            let y = size.height * .random(in: 0.12...0.88, using: &generator)
            let point = CGPoint(x: .random(in: 0...size.width, using: &generator), y: y)
            let length = CGFloat.random(in: 20...70, using: &generator)
            let angle = CGFloat.random(in: 0...(2 * .pi), using: &generator)
            let seed = UInt64.random(in: 0...UInt64.max, using: &generator)
            let alpha = 0.55 * (1 - depth(at: y) * 0.5)
            local(at: point, reach: length * 3) {
                var copy = SeededGenerator(seed: seed)
                cg.setStrokeColor(Tone.crimson.cg(alpha))
                branch(from: .zero, angle: angle, length: length, width: 1.6, depth: 5, &copy)
            }
        }
    }

    private struct Cell {
        var center: CGPoint
        var radius: CGFloat
    }

    /// Cells packed tightly, pale and glowing, with red-orange tissue showing in the gaps and veins inside.
    func paintCells(_ generator: inout SeededGenerator) {
        // Open patches where the stained tissue shows through, so the foam isn't one even sheet.
        var cells: [Cell] = (0..<9).map { _ in
            Cell(
                center: CGPoint(
                    x: .random(in: 0...size.width, using: &generator),
                    y: size.height * .random(in: 0.25...0.75, using: &generator)),
                radius: .random(in: 60...150, using: &generator))
        }
        let voids = cells.count
        let passes: [(radii: ClosedRange<CGFloat>, tries: Int, band: ClosedRange<CGFloat>)] = [
            (36...80, 260, 0.2...0.8),
            (16...36, 1600, 0.15...0.85),
            (7...16, 3000, 0.12...0.88),
            (2.5...7, 5000, 0.1...0.9),
        ]
        for pass in passes {
            for _ in 0..<pass.tries {
                let radius = CGFloat.random(in: pass.radii, using: &generator)
                var center = CGPoint(
                    x: .random(in: 0...size.width, using: &generator),
                    y: size.height * .random(in: pass.band, using: &generator))
                // Mostly nestled against a cell already there, so they pack into foam instead of scattering.
                if cells.count > voids, Double.random(in: 0...1, using: &generator) < 0.8 {
                    let neighbour = cells[Int.random(in: voids..<cells.count, using: &generator)]
                    let angle = CGFloat.random(in: 0...(2 * .pi), using: &generator)
                    let reach = neighbour.radius + radius + 1.5
                    center = CGPoint(
                        x: neighbour.center.x + cos(angle) * reach * stretch(at: neighbour.center.y),
                        y: neighbour.center.y + sin(angle) * reach)
                    center.x = (center.x + size.width).truncatingRemainder(dividingBy: size.width)
                    guard pass.band.contains(center.y / size.height) else { continue }
                }
                let candidate = Cell(center: center, radius: radius)
                if fits(candidate, among: cells, gap: radius > 16 ? 2 : 1) {
                    cells.append(candidate)
                }
            }
        }
        for cell in cells.dropFirst(voids) {
            paintCell(cell, &generator)
        }
    }

    private func fits(_ cell: Cell, among cells: [Cell], gap: CGFloat) -> Bool {
        for other in cells {
            var dx = abs(other.center.x - cell.center.x)
            dx = min(dx, size.width - dx) / stretch(at: (cell.center.y + other.center.y) / 2)
            let dy = other.center.y - cell.center.y
            let reach = cell.radius + other.radius + gap
            if dx * dx + dy * dy < reach * reach { return false }
        }
        return true
    }

    private func paintCell(_ cell: Cell, _ generator: inout SeededGenerator) {
        let r = cell.radius
        let dark = Self.smoothstep(0.3, 0.92, depth(at: cell.center.y))
        let fade = 1 - dark * 0.45
        // Some cells are lit more thinly, a few lean amber.
        let shade = CGFloat.random(in: 0...0.35, using: &generator)
        let warm = Double.random(in: 0...1, using: &generator) < 0.15 ? Tone.amber : Tone.peach
        let core = Tone.ivory.mixed(with: .coral, shade).mixed(with: .wine, dark * 0.75)
        let body = warm.mixed(with: .coral, shade).mixed(with: .wine, dark * 0.75)
        let rim = Tone.coral.mixed(with: .wine, dark * 0.6)
        let vein = Tone.crimson.mixed(with: .coral, 0.25)
        let squash = CGFloat.random(in: 0.82...1.0, using: &generator)
        let tilt = CGFloat.random(in: 0...(.pi), using: &generator)
        let veins = r > 14 ? (r > 40 ? 4 : r > 24 ? 3 : 2) : 0
        var seeds: [(start: CGPoint, direction: CGFloat)] = []
        for _ in 0..<veins {
            let angle = CGFloat.random(in: 0...(2 * .pi), using: &generator)
            seeds.append((
                CGPoint(x: cos(angle) * r, y: sin(angle) * r),
                angle + .pi + .random(in: -0.45...0.45, using: &generator)))
        }
        let body3 = gradient([(0, core.cg(0.9 * fade)), (0.6, body.cg(0.78 * fade)), (1, rim.cg(0.7 * fade))])
        let veinGenerator = SeededGenerator(seed: UInt64(cell.center.x * 31 + cell.center.y * 7919))
        local(at: cell.center, reach: r, rotation: tilt) {
            cg.scaleBy(x: 1, y: squash)
            let shape = CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r)
            cg.saveGState()
            cg.addEllipse(in: shape)
            cg.clip()
            cg.drawRadialGradient(
                body3, startCenter: CGPoint(x: -0.22 * r, y: -0.28 * r), startRadius: 0,
                endCenter: .zero, endRadius: r * 1.02, options: [.drawsAfterEndLocation])
            var copy = veinGenerator
            cg.setStrokeColor(vein.cg(0.5 * fade))
            for seed in seeds {
                branch(from: seed.start, angle: seed.direction, length: r * 0.55, width: max(0.5, r * 0.04), depth: 4, &copy)
            }
            cg.restoreGState()
            cg.addEllipse(in: shape)
            cg.setStrokeColor(rim.mixed(with: .crimson, 0.5).cg(0.55 * fade))
            cg.setLineWidth(0.6 + r * 0.03)
            cg.strokePath()
        }
    }

    private func branch(
        from start: CGPoint, angle: CGFloat, length: CGFloat, width: CGFloat, depth: Int,
        _ generator: inout SeededGenerator
    ) {
        let end = CGPoint(x: start.x + cos(angle) * length, y: start.y + sin(angle) * length)
        let bend = length * .random(in: -0.25...0.25, using: &generator)
        let control = CGPoint(
            x: (start.x + end.x) / 2 - sin(angle) * bend, y: (start.y + end.y) / 2 + cos(angle) * bend)
        cg.move(to: start)
        cg.addQuadCurve(to: end, control: control)
        cg.setLineWidth(width)
        cg.strokePath()
        guard depth > 1 else { return }
        let children = Double.random(in: 0...1, using: &generator) < 0.2 ? 3 : 2
        for child in 0..<children {
            let side: CGFloat = child % 2 == 0 ? 1 : -1
            let turn = side * .random(in: 0.3...0.75, using: &generator)
            branch(
                from: end, angle: angle + turn, length: length * .random(in: 0.58...0.74, using: &generator),
                width: width * 0.64, depth: depth - 1, &generator)
        }
    }

    /// Bundles of fine, near-parallel strands, like muscle fibre seen through resin.
    func paintFibres(_ generator: inout SeededGenerator) {
        for _ in 0..<18 {
            let lower = Bool.random(using: &generator)
            let middle = Double.random(in: 0...1, using: &generator) < 0.3
            let y = size.height * (middle
                ? .random(in: 0.3...0.7, using: &generator)
                : lower ? .random(in: 0.7...0.86, using: &generator) : .random(in: 0.14...0.3, using: &generator))
            let start = CGFloat.random(in: 0...size.width, using: &generator)
            let length = CGFloat.random(in: 300...900, using: &generator)
            let wave = CGFloat.random(in: 10...50, using: &generator)
            let frequency = CGFloat.random(in: 1...3, using: &generator)
            let phase = CGFloat.random(in: 0...(2 * .pi), using: &generator)
            let spread = CGFloat.random(in: 12...40, using: &generator)
            let tone = Bool.random(using: &generator) ? Tone.ivory : Tone.peach
            let strands = Int.random(in: 40...90, using: &generator)
            for _ in 0..<strands {
                let offset = Self.gaussian(&generator) * spread
                let drift = CGFloat.random(in: -0.15...0.15, using: &generator)
                let path = CGMutablePath()
                for step in 0...48 {
                    let t = CGFloat(step) / 48
                    let x = start + t * length
                    let py = y + offset * (1 + drift * t) + sin(t * frequency * 2 * .pi + phase) * wave
                    if step == 0 { path.move(to: CGPoint(x: x, y: py)) } else { path.addLine(to: CGPoint(x: x, y: py)) }
                }
                let alpha = CGFloat.random(in: 0.05...0.15, using: &generator) * (1 - depth(at: y) * 0.5)
                let width = CGFloat.random(in: 0.35...1.0, using: &generator)
                for shift in [0, -size.width] where start + length + shift > 0 {
                    cg.saveGState()
                    cg.translateBy(x: shift, y: 0)
                    cg.addPath(path)
                    cg.setStrokeColor(tone.cg(alpha))
                    cg.setLineWidth(width)
                    cg.strokePath()
                    cg.restoreGState()
                }
            }
        }
    }

    /// Gelatinous bubbles: tinted inside, a brighter rim and a wet highlight.
    func paintBubbles(_ generator: inout SeededGenerator, count: Int) {
        for _ in 0..<count {
            let y = size.height * .random(in: 0.08...0.92, using: &generator)
            let point = CGPoint(x: .random(in: 0...size.width, using: &generator), y: y)
            let r = 3 + pow(CGFloat.random(in: 0...1, using: &generator), 2.2) * 30
            let dark = depth(at: y) * 0.6
            let tint = Tone.blush.mixed(with: .wine, dark)
            let fill = gradient([(0, tint.cg(0.05)), (0.75, tint.cg(0.16)), (1, Tone.blush.cg(0.32))])
            let shine = gradient([(0, Tone.ivory.cg(0.7)), (1, Tone.ivory.cg(0))])
            let hasCore = Double.random(in: 0...1, using: &generator) < 0.15
            local(at: point, reach: r) {
                cg.drawRadialGradient(fill, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: r, options: [])
                if hasCore {
                    softDot(radius: r * 0.35, color: .crimson, alpha: 0.35)
                }
                cg.addEllipse(in: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r))
                cg.setStrokeColor(Tone.ivory.cg(0.32))
                cg.setLineWidth(0.5 + r * 0.035)
                cg.strokePath()
                let spot = CGPoint(x: -0.38 * r, y: -0.42 * r)
                cg.saveGState()
                cg.translateBy(x: spot.x, y: spot.y)
                cg.scaleBy(x: 1, y: 0.6)
                cg.drawRadialGradient(shine, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: r * 0.3, options: [])
                cg.restoreGState()
            }
        }
    }

    /// Out-of-focus motes of light.
    func paintBokeh(_ generator: inout SeededGenerator) {
        for _ in 0..<520 {
            let y = size.height * .random(in: 0.05...0.95, using: &generator)
            let point = CGPoint(x: .random(in: 0...size.width, using: &generator), y: y)
            let radius = CGFloat.random(in: 0.8...5, using: &generator)
            let tone = Bool.random(using: &generator) ? Tone.amber : Tone.ivory
            let alpha = CGFloat.random(in: 0.1...0.35, using: &generator)
            local(at: point, reach: radius) {
                softDot(radius: radius, color: tone, alpha: alpha)
            }
        }
    }

    /// The far depths above and below fade into darkness.
    func paintDepths() {
        let top = gradient([(0, Tone.night.cg(0.9)), (1, Tone.night.cg(0))])
        cg.drawLinearGradient(top, start: .zero, end: CGPoint(x: 0, y: size.height * 0.16), options: [])
        cg.drawLinearGradient(
            top, start: CGPoint(x: 0, y: size.height), end: CGPoint(x: 0, y: size.height * 0.84), options: [])
    }

    // MARK: Veil

    /// Branching vessels: a dark red tube with a lighter, glossy line down its middle.
    func paintVessels(_ generator: inout SeededGenerator) {
        for _ in 0..<34 {
            let y = size.height * .random(in: 0.1...0.9, using: &generator)
            let point = CGPoint(x: .random(in: 0...size.width, using: &generator), y: y)
            let length = CGFloat.random(in: 40...130, using: &generator)
            let width = CGFloat.random(in: 2.2...5.5, using: &generator)
            let angle = CGFloat.random(in: 0...(2 * .pi), using: &generator)
            let seed = UInt64.random(in: 0...UInt64.max, using: &generator)
            let alpha = 0.6 - depth(at: y) * 0.25
            local(at: point, reach: length * 3) {
                var outer = SeededGenerator(seed: seed)
                cg.setStrokeColor(Tone.crimson.mixed(with: .wine, 0.3).cg(0.6 * alpha))
                branch(from: .zero, angle: angle, length: length, width: width, depth: 5, &outer)
                var inner = SeededGenerator(seed: seed)
                cg.setStrokeColor(Tone.coral.mixed(with: .peach, 0.4).cg(0.45 * alpha))
                branch(from: .zero, angle: angle, length: length, width: width * 0.32, depth: 5, &inner)
                cg.setFillColor(Tone.blush.cg(0.45 * alpha))
                cg.fillEllipse(in: CGRect(x: -width * 1.6, y: -width * 1.6, width: width * 3.2, height: width * 3.2))
            }
        }
    }

    /// Fine sagging strands strung between points, like stretched gel.
    func paintWebs(_ generator: inout SeededGenerator) {
        for _ in 0..<150 {
            let y = size.height * .random(in: 0.12...0.88, using: &generator)
            let start = CGPoint(x: .random(in: 0...size.width, using: &generator), y: y)
            let k = stretch(at: y)
            let end = CGPoint(
                x: start.x + .random(in: -160...160, using: &generator) * k,
                y: start.y + .random(in: -70...70, using: &generator))
            let sag = CGFloat.random(in: 10...60, using: &generator)
            let control = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2 + sag)
            let alpha = CGFloat.random(in: 0.16...0.36, using: &generator) * (1 - depth(at: y) * 0.5)
            let width = CGFloat.random(in: 0.35...0.9, using: &generator)
            wrapped(start.x, reach: abs(end.x - start.x) + 1) { x in
                let shift = x - start.x
                cg.move(to: CGPoint(x: start.x + shift, y: start.y))
                cg.addQuadCurve(
                    to: CGPoint(x: end.x + shift, y: end.y), control: CGPoint(x: control.x + shift, y: control.y))
                cg.setStrokeColor(Tone.blush.mixed(with: .ivory, 0.4).cg(alpha))
                cg.setLineWidth(width)
                cg.strokePath()
            }
        }
    }

    func paintSpecks(_ generator: inout SeededGenerator) {
        let path = CGMutablePath()
        for _ in 0..<1600 {
            let y = size.height * .random(in: 0.05...0.95, using: &generator)
            let r = CGFloat.random(in: 0.4...1.4, using: &generator)
            let x = CGFloat.random(in: 0...size.width, using: &generator)
            path.addEllipse(in: CGRect(x: x - r * stretch(at: y), y: y - r, width: 2 * r * stretch(at: y), height: 2 * r))
        }
        cg.addPath(path)
        cg.setFillColor(Tone.ivory.cg(0.35))
        cg.fillPath()
    }
}
