import Foundation
import simd

/// Triangles for one material, collected from many shapes so each material draws in one go.
struct MeshData: Sendable {
    var positions: [SIMD3<Float>] = []
    var normals: [SIMD3<Float>] = []
    var indices: [UInt32] = []

    var isEmpty: Bool { indices.isEmpty }

    /// A sphere, optionally squashed per axis. Fewer segments for small ones.
    mutating func addSphere(center: SIMD3<Float>, radius: Float, squash: SIMD3<Float> = .one, detail: Float = 1) {
        let segments = max(10, min(44, Int((radius * 2.2 + 10) * detail)))
        let rings = max(6, segments / 2)
        let base = UInt32(positions.count)
        for ring in 0...rings {
            let theta = Float.pi * Float(ring) / Float(rings)
            for segment in 0...segments {
                let phi = 2 * Float.pi * Float(segment) / Float(segments)
                let unit = SIMD3<Float>(sin(theta) * cos(phi), cos(theta), sin(theta) * sin(phi))
                positions.append(center + unit * radius * squash)
                normals.append(simd_normalize(unit / squash))
            }
        }
        let row = UInt32(segments + 1)
        for ring in 0..<UInt32(rings) {
            for segment in 0..<UInt32(segments) {
                let a = base + ring * row + segment
                let b = a + row
                indices += [a, a + 1, b, a + 1, b + 1, b]
            }
        }
    }

    /// A tube through `points`, its radius running from `radii.first` to `radii.last` with an optional bulge.
    mutating func addTube(_ points: [SIMD3<Float>], from start: Float, to end: Float, sides: Int = 8) {
        guard points.count > 1 else { return }
        let base = UInt32(positions.count)
        // A frame carried along the curve so the rings don't twist.
        var tangent = simd_normalize(points[1] - points[0])
        var normal = simd_normalize(simd_cross(tangent, abs(tangent.y) < 0.9 ? SIMD3<Float>(0, 1, 0) : SIMD3<Float>(1, 0, 0)))
        for (index, point) in points.enumerated() {
            let next = points[min(index + 1, points.count - 1)]
            let previous = points[max(index - 1, 0)]
            let direction = next - previous
            if simd_length(direction) > 1e-5 {
                let newTangent = simd_normalize(direction)
                let axis = simd_cross(tangent, newTangent)
                if simd_length(axis) > 1e-6 {
                    let angle = acos(min(max(simd_dot(tangent, newTangent), -1), 1))
                    normal = simd_act(simd_quatf(angle: angle, axis: simd_normalize(axis)), normal)
                }
                tangent = newTangent
            }
            let binormal = simd_cross(tangent, normal)
            let t = Float(index) / Float(points.count - 1)
            let radius = start + (end - start) * t
            for side in 0...sides {
                let angle = 2 * Float.pi * Float(side) / Float(sides)
                let out = normal * cos(angle) + binormal * sin(angle)
                positions.append(point + out * radius)
                normals.append(out)
            }
        }
        let row = UInt32(sides + 1)
        for index in 0..<UInt32(points.count - 1) {
            for side in 0..<UInt32(sides) {
                let a = base + index * row + side
                let b = a + row
                indices += [a, b, a + 1, a + 1, b, b + 1]
            }
        }
    }
}

/// What a piece of the body is made of; each look gets its own material.
enum BodyLook: Int, CaseIterable, Sendable {
    /// Translucent pink bubbles.
    case bubble
    /// The large gelatinous cores of each knot.
    case core
    /// The darker body inside each core.
    case nucleus
    /// Glossy pale-pink fibres.
    case fibre
    /// Ivory beads and grains.
    case bead
    /// Nearly clear glass-like bubbles drifting on their own.
    case glass
}

/// A knot of tissue: a gelatinous core with bubbles strung around it on fibres, beaded chains and grains.
struct Knot: Sendable {
    var position: SIMD3<Float>
    var meshes: [BodyLook: MeshData]
    /// Roughly how far it reaches from its centre.
    var reach: Float
}

struct Sculpture: Sendable {
    var knots: [Knot] = []
    /// Big fibres slung from knot to knot.
    var tendrils = MeshData()
    /// Free-floating glass bubbles.
    var drifters = MeshData()

    /// Lays out the body around the viewer, who is at the origin. Nothing comes within `avoid.radius` of
    /// `avoid.center`, where the grown cell hangs.
    static func make(avoiding avoid: (center: SIMD3<Float>, radius: Float)) -> Sculpture {
        var generator = SeededGenerator(seed: 41)
        var sculpture = Sculpture()
        let count = 10
        for index in 0..<count {
            let size = Float.random(in: 5...11, using: &generator)
            let reach = size * 4.2
            var spot: SIMD3<Float>?
            for attempt in 0..<12 {
                let yaw = (Float(index) + Float.random(in: -0.35...0.35, using: &generator)) / Float(count) * 2 * .pi
                    + Float(attempt) * 0.37
                let pitch = Float.random(in: -0.6...0.45, using: &generator)
                let distance = Float.random(in: 70...150, using: &generator)
                let candidate = SIMD3<Float>(cos(pitch) * sin(yaw), sin(pitch), -cos(pitch) * cos(yaw)) * distance
                if simd_distance(candidate, avoid.center) > avoid.radius + reach {
                    spot = candidate
                    break
                }
            }
            guard let spot else { continue }
            sculpture.knots.append(makeKnot(at: spot, size: size, &generator))
        }
        sculpture.slingTendrils(avoiding: avoid, &generator)
        sculpture.scatterDrifters(avoiding: avoid, &generator)
        return sculpture
    }

    private static func makeKnot(at position: SIMD3<Float>, size: Float, _ generator: inout SeededGenerator) -> Knot {
        var meshes: [BodyLook: MeshData] = [:]
        func add(_ look: BodyLook, _ build: (inout MeshData) -> Void) {
            var mesh = meshes[look] ?? MeshData()
            build(&mesh)
            meshes[look] = mesh
        }
        let squash = SIMD3<Float>(
            .random(in: 0.85...1.15, using: &generator), .random(in: 0.8...1.1, using: &generator),
            .random(in: 0.85...1.15, using: &generator))
        add(.core) { $0.addSphere(center: .zero, radius: size, squash: squash) }
        add(.nucleus) {
            $0.addSphere(center: randomUnit(&generator) * size * 0.2, radius: size * 0.42, squash: SIMD3<Float>(squash.y, squash.z, squash.x))
        }

        // Bubbles around the core, each tied back by a fibre; neighbours are tied to each other too.
        var bubbles: [(center: SIMD3<Float>, radius: Float)] = []
        for _ in 0..<Int.random(in: 18...30, using: &generator) {
            let radius = size * (0.07 + pow(.random(in: 0...1, using: &generator), 1.8) * 0.33)
            let center = randomUnit(&generator) * size * Float.random(in: 1.25...2.6, using: &generator)
            bubbles.append((center, radius))
            add(.bubble) { $0.addSphere(center: center, radius: radius) }
            let anchor = simd_normalize(center) * size * 0.95 * squash
            add(.fibre) {
                $0.addTube(
                    curve(from: anchor, to: center, sag: size * 0.25, &generator),
                    from: size * 0.06, to: radius * 0.22, sides: 7)
            }
        }
        for (index, bubble) in bubbles.enumerated() {
            let nearest = bubbles.enumerated()
                .filter { $0.offset != index }
                .sorted { simd_distance($0.element.center, bubble.center) < simd_distance($1.element.center, bubble.center) }
                .prefix(2)
            for other in nearest where other.offset > index {
                add(.fibre) {
                    $0.addTube(
                        curve(from: bubble.center, to: other.element.center, sag: size * 0.2, &generator),
                        from: bubble.radius * 0.14, to: other.element.radius * 0.14, sides: 6)
                }
            }
        }

        // Roots reaching out from the core and forking once.
        for _ in 0..<Int.random(in: 4...7, using: &generator) {
            let direction = randomUnit(&generator)
            let start = direction * size * 0.9
            let end = start + simd_normalize(direction + randomUnit(&generator) * 0.5) * size * Float.random(in: 2.6...4.2, using: &generator)
            let path = curve(from: start, to: end, sag: size * 0.6, &generator)
            add(.fibre) { $0.addTube(path, from: size * 0.11, to: size * 0.012, sides: 8) }
            let fork = path[path.count * 3 / 5]
            let forkEnd = fork + simd_normalize(randomUnit(&generator) + direction) * size * 1.4
            add(.fibre) {
                $0.addTube(curve(from: fork, to: forkEnd, sag: size * 0.3, &generator), from: size * 0.05, to: size * 0.008, sides: 6)
            }
        }

        // Beaded chains curling outwards, the beads shrinking towards the tip.
        for _ in 0..<Int.random(in: 3...6, using: &generator) {
            let direction = randomUnit(&generator)
            var point = direction * size * 0.95
            var heading = simd_normalize(direction + randomUnit(&generator) * 0.4)
            var radius = size * Float.random(in: 0.09...0.14, using: &generator)
            let curl = randomUnit(&generator) * 0.18
            for _ in 0..<Int.random(in: 8...15, using: &generator) {
                point += heading * radius * 1.75
                let bead = point
                let beadRadius = radius
                add(.bead) { $0.addSphere(center: bead, radius: beadRadius, squash: SIMD3<Float>(1, 0.92, 1), detail: 0.8) }
                heading = simd_normalize(heading + curl)
                radius *= 0.93
            }
        }

        // Fine grains clinging around the knot.
        for _ in 0..<Int.random(in: 30...55, using: &generator) {
            let center = randomUnit(&generator) * size * Float.random(in: 1.0...2.2, using: &generator)
            let radius = size * Float.random(in: 0.015...0.05, using: &generator)
            add(.bead) { $0.addSphere(center: center, radius: radius, detail: 0.6) }
        }
        return Knot(position: position, meshes: meshes, reach: size * 4.2)
    }

    /// Each knot is tied to its two nearest neighbours by a long, heavy fibre that sags between them.
    private mutating func slingTendrils(avoiding avoid: (center: SIMD3<Float>, radius: Float), _ generator: inout SeededGenerator) {
        var tied: Set<[Int]> = []
        for (index, knot) in knots.enumerated() {
            let nearest = knots.enumerated()
                .filter { $0.offset != index }
                .sorted { simd_distance($0.element.position, knot.position) < simd_distance($1.element.position, knot.position) }
                .prefix(2)
            for other in nearest {
                let pair = [min(index, other.offset), max(index, other.offset)]
                guard !tied.contains(pair) else { continue }
                tied.insert(pair)
                let start = knot.position
                let end = other.element.position
                let span = simd_distance(start, end)
                let path = Self.curve(from: start, to: end, sag: span * 0.18, &generator, steps: 36)
                // Keep clear of the viewer and the grown cell.
                guard path.allSatisfy({ simd_length($0) > 35 && simd_distance($0, avoid.center) > avoid.radius })
                else { continue }
                let radius = Float.random(in: 0.5...1.3, using: &generator)
                tendrils.addTube(path, from: radius, to: radius * 0.7, sides: 12)
                // A thinner strand twisting alongside.
                let offset = Self.randomUnit(&generator) * radius * 2.5
                tendrils.addTube(
                    Self.curve(from: start + offset, to: end - offset, sag: span * 0.22, &generator, steps: 30),
                    from: radius * 0.35, to: radius * 0.25, sides: 8)
            }
        }
    }

    /// Glass bubbles drifting between the knots, alone and in small clutches.
    private mutating func scatterDrifters(avoiding avoid: (center: SIMD3<Float>, radius: Float), _ generator: inout SeededGenerator) {
        var placed = 0
        while placed < 70 {
            let center = Self.randomUnit(&generator) * Float.random(in: 30...140, using: &generator)
            guard simd_distance(center, avoid.center) > avoid.radius + 5 else { continue }
            placed += 1
            let radius = 0.3 + pow(Float.random(in: 0...1, using: &generator), 2) * 3.2
            drifters.addSphere(center: center, radius: radius)
            if Double.random(in: 0...1, using: &generator) < 0.3 {
                for _ in 0..<Int.random(in: 3...8, using: &generator) {
                    let small = radius * Float.random(in: 0.15...0.4, using: &generator)
                    drifters.addSphere(center: center + Self.randomUnit(&generator) * radius * Float.random(in: 1.3...2.5, using: &generator), radius: small)
                }
            }
        }
    }

    // MARK: Helpers

    static func randomUnit(_ generator: inout SeededGenerator) -> SIMD3<Float> {
        let z = Float.random(in: -1...1, using: &generator)
        let angle = Float.random(in: 0...(2 * .pi), using: &generator)
        let r = sqrt(1 - z * z)
        return SIMD3<Float>(r * cos(angle), z, r * sin(angle))
    }

    /// A gently bent curve from `start` to `end`, sagging sideways by up to `sag`.
    static func curve(
        from start: SIMD3<Float>, to end: SIMD3<Float>, sag: Float, _ generator: inout SeededGenerator, steps: Int = 18
    ) -> [SIMD3<Float>] {
        let control = (start + end) / 2 + randomUnit(&generator) * sag + SIMD3<Float>(0, -sag * 0.5, 0)
        return (0...steps).map { step in
            let t = Float(step) / Float(steps)
            return (1 - t) * (1 - t) * start + 2 * (1 - t) * t * control + t * t * end
        }
    }
}
