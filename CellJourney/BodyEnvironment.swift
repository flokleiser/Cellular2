import RealityKit
import UIKit
import simd

/// The living body around the viewer once the cell has grown around them. From far to near:
/// a painted wall of backlit tissue, a slowly turning veil of vessels in front of it, knots of gelatinous tissue
/// tied together by fibres, drifting glass bubbles, and motes floating in the fluid right around the viewer.
/// Everything breathes and drifts a little so it feels alive. Built in the background after the scene loads.
@MainActor
final class BodyEnvironment {
    static let skyRadius: Float = 250
    private static let veilRadius: Float = 210
    /// How many pixels each point of the painted wall gets. It is laid out on 2048 × 1024 points, so 6 gives a
    /// 12288 × 6144 texture; lower it if loading takes too long or memory runs short.
    private static let skyDetail: CGFloat = 6
    private static let veilDetail: CGFloat = 2
    /// How bright the body is: 1 as painted, lower is darker. The cell is lit separately and stays bright.
    private static let dimming: CGFloat = 0.4
    /// How strongly the cell is lit while inside the body; each step of 1 doubles it.
    private static let cellBrightness: Float = 0.6

    let root = Entity()
    /// The far wall. Named and grabbable like before, so dragging anywhere around the viewer turns the cell.
    let sky: ModelEntity
    private let veil = ModelEntity()
    private let structures = Entity()
    private let drifters = Entity()
    private let motes = Entity()
    /// The source of the warm image-based light everything in here is lit by.
    private let light = Entity()
    /// A bright, neutral light for the cell and its organelles, so they stand out against the dark body.
    private let cellLight = Entity()
    private var isCellLit = false
    private let drawOrder = ModelSortGroup(depthPass: nil)
    private var knots: [(entity: Entity, axis: SIMD3<Float>, speed: Float, period: Float, phase: Float)] = []
    private var time: Float = 0
    private var isBuilt = false

    init(center: SIMD3<Float>) {
        root.position = center
        root.isEnabled = false
        sky = ModelEntity(
            mesh: .generateSphere(radius: Self.skyRadius),
            materials: [UnlitMaterial(color: UIColor(red: 0.3, green: 0.03, blue: 0.05, alpha: 1))])
        sky.name = "sky"
        // Seen from inside.
        sky.scale = SIMD3<Float>(-1, 1, 1)
        sky.components.set(CollisionComponent(shapes: [.generateSphere(radius: Self.skyRadius)]))
        sky.components.set(ModelSortGroupComponent(group: drawOrder, order: 0))
        veil.scale = SIMD3<Float>(-1, 1, 1)
        veil.components.set(ModelSortGroupComponent(group: drawOrder, order: 1))
        root.addChild(sky)
        root.addChild(veil)
        root.addChild(structures)
        root.addChild(drifters)
        root.addChild(motes)
        root.addChild(light)
        root.addChild(cellLight)
    }

    /// 0 hides it all, 1 shows it fully.
    func setImmersion(_ immersion: Float) {
        root.isEnabled = immersion > 0.001
        root.components.set(OpacityComponent(opacity: immersion))
        // Particles don't fade with the rest, so they only come in once the body is mostly there.
        motes.isEnabled = immersion > 0.6
    }

    /// Paints the textures and shapes the tissue off the main thread, then puts it all in place.
    /// `avoid` is the space the grown cell takes up, in the same coordinates as `root`'s parent.
    func build(avoiding avoid: (center: SIMD3<Float>, radius: Float)) async {
        guard !isBuilt else { return }
        isBuilt = true
        let skyDetail = Self.skyDetail
        let veilDetail = Self.veilDetail
        let localAvoid = (center: avoid.center - root.position, radius: avoid.radius)
        let paintedSky = Task.detached(priority: .utility) { BodyPainting.backdrop(detail: skyDetail) }
        let paintedVeil = Task.detached(priority: .utility) { BodyPainting.veil(detail: veilDetail) }
        let shaped = Task.detached(priority: .utility) { Sculpture.make(avoiding: localAvoid) }

        if let image = await paintedSky.value {
            if let texture = try? await TextureResource(
                image: image, options: .init(semantic: .color, mipmapsMode: .allocateAndGenerateAll))
            {
                var material = UnlitMaterial()
                material.color = .init(tint: UIColor(white: Self.dimming, alpha: 1), texture: .init(texture))
                sky.model?.materials = [material]
            }
            let lighting = await Task.detached(priority: .utility) { BodyPainting.lighting(from: image) }.value
            if let lighting, let environment = try? await EnvironmentResource(equirectangular: lighting) {
                light.components.set(ImageBasedLightComponent(source: .single(environment), intensityExponent: -0.9))
            }
        }
        if let image = await paintedVeil.value,
            let texture = try? await TextureResource(
                image: image, options: .init(semantic: .color, mipmapsMode: .allocateAndGenerateAll))
        {
            var material = UnlitMaterial()
            material.color = .init(tint: UIColor(white: Self.dimming, alpha: 1), texture: .init(texture))
            material.blending = .transparent(opacity: .init(floatLiteral: 1))
            veil.model = ModelComponent(mesh: .generateSphere(radius: Self.veilRadius), materials: [material])
        }

        if let image = BodyPainting.cellLight(), let environment = try? await EnvironmentResource(equirectangular: image) {
            cellLight.components.set(
                ImageBasedLightComponent(source: .single(environment), intensityExponent: Self.cellBrightness))
        }

        let sculpture = await shaped.value
        let materials = Self.materials()
        for knot in sculpture.knots {
            let holder = Entity()
            holder.position = knot.position
            for look in BodyLook.allCases {
                guard let data = knot.meshes[look], let entity = makeModel(data, material: materials[look]) else { continue }
                holder.addChild(entity)
            }
            structures.addChild(holder)
            var generator = SeededGenerator(seed: UInt64(abs(knot.position.x * 1000 + knot.position.z)))
            knots.append((
                holder, Sculpture.randomUnit(&generator), .random(in: 0.015...0.04, using: &generator),
                .random(in: 6...11, using: &generator), .random(in: 0...(2 * .pi), using: &generator)))
        }
        if let tendrils = makeModel(sculpture.tendrils, material: materials[.fibre]) {
            structures.addChild(tendrils)
        }
        if let glass = makeModel(sculpture.drifters, material: materials[.glass]) {
            drifters.addChild(glass)
        }
        makeMotes()
    }

    /// Lights the given entities and everything under them with the bright cell light, or hands them back to the
    /// usual lighting. Does nothing until the light is ready.
    func brighten(_ entities: [Entity], isOn: Bool) {
        guard isOn != isCellLit, cellLight.components.has(ImageBasedLightComponent.self) else { return }
        isCellLit = isOn
        func apply(_ entity: Entity) {
            if entity.components.has(ModelComponent.self) {
                if isOn {
                    entity.components.set(ImageBasedLightReceiverComponent(imageBasedLight: cellLight))
                } else {
                    entity.components.remove(ImageBasedLightReceiverComponent.self)
                }
            }
            entity.children.forEach(apply)
        }
        entities.forEach(apply)
    }

    /// Called every frame: the veil and the tissue turn very slowly in opposite directions, which gives depth, and
    /// each knot breathes and tumbles on its own.
    func update(by seconds: Float) {
        guard root.isEnabled else { return }
        time += seconds
        veil.orientation = simd_normalize(simd_quatf(angle: 0.004 * seconds, axis: SIMD3<Float>(0, 1, 0)) * veil.orientation)
        structures.orientation = simd_normalize(
            simd_quatf(angle: -0.006 * seconds, axis: SIMD3<Float>(0, 1, 0)) * structures.orientation)
        drifters.orientation = simd_normalize(
            simd_quatf(angle: 0.009 * seconds, axis: simd_normalize(SIMD3<Float>(0.2, 1, 0.1))) * drifters.orientation)
        for knot in knots {
            knot.entity.orientation = simd_normalize(
                simd_quatf(angle: knot.speed * seconds, axis: knot.axis) * knot.entity.orientation)
            let breath = 1 + 0.03 * sin(2 * .pi * time / knot.period + knot.phase)
            knot.entity.scale = SIMD3<Float>(breath, 2 - breath, breath)
        }
    }

    private func makeModel(_ data: MeshData, material: (any Material)?) -> ModelEntity? {
        guard !data.isEmpty, let material else { return nil }
        var descriptor = MeshDescriptor()
        descriptor.positions = MeshBuffer(data.positions)
        descriptor.normals = MeshBuffer(data.normals)
        descriptor.primitives = .triangles(data.indices)
        guard let mesh = try? MeshResource.generate(from: [descriptor]) else { return nil }
        let entity = ModelEntity(mesh: mesh, materials: [material])
        entity.components.set(ImageBasedLightReceiverComponent(imageBasedLight: light))
        // Drawn after the wall and the veil, so see-through tissue tints what lies behind it.
        entity.components.set(ModelSortGroupComponent(group: drawOrder, order: 2))
        return entity
    }

    /// Wet, glossy and partly see-through, with a faint inner glow standing in for light scattering inside.
    private static func materials() -> [BodyLook: any Material] {
        func gel(
            _ color: UIColor, opacity: Float, roughness: Float, glow: UIColor, glowStrength: Float,
            sheen: UIColor = UIColor(red: 1, green: 0.92, blue: 0.85, alpha: 1)
        ) -> PhysicallyBasedMaterial {
            var material = PhysicallyBasedMaterial()
            material.baseColor = .init(tint: color)
            material.roughness = .init(floatLiteral: roughness)
            material.metallic = .init(floatLiteral: 0)
            material.clearcoat = .init(floatLiteral: 1)
            material.clearcoatRoughness = .init(floatLiteral: 0.03)
            material.sheen = .init(tint: sheen)
            material.emissiveColor = .init(color: glow)
            material.emissiveIntensity = glowStrength
            if opacity < 1 {
                material.blending = .transparent(opacity: .init(floatLiteral: opacity))
            }
            // Both sides, so the far inside wall of a see-through bubble shows through its front.
            material.faceCulling = .none
            return material
        }
        let dim = Float(dimming)
        return [
            .bubble: gel(
                UIColor(red: 0.97, green: 0.68, blue: 0.68, alpha: 1), opacity: 0.42, roughness: 0.08,
                glow: UIColor(red: 0.95, green: 0.45, blue: 0.42, alpha: 1), glowStrength: 0.35 * dim),
            .core: gel(
                UIColor(red: 1.0, green: 0.74, blue: 0.62, alpha: 1), opacity: 0.55, roughness: 0.1,
                glow: UIColor(red: 0.98, green: 0.55, blue: 0.40, alpha: 1), glowStrength: 0.45 * dim),
            .nucleus: gel(
                UIColor(red: 0.72, green: 0.16, blue: 0.18, alpha: 1), opacity: 1, roughness: 0.25,
                glow: UIColor(red: 0.55, green: 0.06, blue: 0.10, alpha: 1), glowStrength: 0.4 * dim),
            .fibre: gel(
                UIColor(red: 0.98, green: 0.80, blue: 0.76, alpha: 1), opacity: 1, roughness: 0.22,
                glow: UIColor(red: 0.85, green: 0.42, blue: 0.38, alpha: 1), glowStrength: 0.2 * dim),
            .bead: gel(
                UIColor(red: 0.99, green: 0.92, blue: 0.80, alpha: 1), opacity: 1, roughness: 0.3,
                glow: UIColor(red: 0.98, green: 0.70, blue: 0.40, alpha: 1), glowStrength: 0.18 * dim,
                sheen: UIColor(red: 1, green: 0.8, blue: 0.55, alpha: 1)),
            .glass: gel(
                UIColor(red: 1.0, green: 0.9, blue: 0.86, alpha: 1), opacity: 0.22, roughness: 0.03,
                glow: UIColor(red: 1.0, green: 0.75, blue: 0.62, alpha: 1), glowStrength: 0.15 * dim),
        ]
    }

    /// Fine warm motes drifting in the fluid close by, and larger soft specks of light further out.
    private func makeMotes() {
        func emitter(
            space: SIMD3<Float>, rate: Float, life: Double, size: Float, from: UIColor, to: UIColor
        ) -> ParticleEmitterComponent {
            var particles = ParticleEmitterComponent()
            particles.emitterShape = .sphere
            particles.birthLocation = .volume
            particles.emitterShapeSize = space
            particles.speed = 0.04
            particles.speedVariation = 0.03
            particles.mainEmitter.birthRate = rate
            particles.mainEmitter.lifeSpan = life
            particles.mainEmitter.lifeSpanVariation = life * 0.3
            particles.mainEmitter.size = size
            particles.mainEmitter.sizeVariation = size * 0.6
            particles.mainEmitter.spreadingAngle = .pi
            particles.mainEmitter.noiseStrength = 0.06
            particles.mainEmitter.noiseScale = 0.5
            particles.mainEmitter.noiseAnimationSpeed = 0.15
            particles.mainEmitter.opacityCurve = .gradualFadeInOut
            particles.mainEmitter.blendMode = .additive
            particles.mainEmitter.isLightingEnabled = false
            particles.mainEmitter.color = .evolving(start: .single(from), end: .single(to))
            return particles
        }
        let near = Entity()
        near.components.set(emitter(
            space: SIMD3<Float>(24, 14, 24), rate: 260, life: 14, size: 0.025,
            from: UIColor(red: 1, green: 0.78, blue: 0.5, alpha: 0.45),
            to: UIColor(red: 0.95, green: 0.5, blue: 0.5, alpha: 0.25)))
        let far = Entity()
        far.components.set(emitter(
            space: SIMD3<Float>(160, 90, 160), rate: 45, life: 22, size: 0.7,
            from: UIColor(red: 1, green: 0.85, blue: 0.7, alpha: 0.12),
            to: UIColor(red: 0.9, green: 0.4, blue: 0.4, alpha: 0.07)))
        motes.addChild(near)
        motes.addChild(far)
    }
}
