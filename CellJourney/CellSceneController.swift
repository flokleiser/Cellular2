import RealityKit
import RealityKitContent
import SwiftUI
import UIKit
import simd

private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) {
        state = seed &+ 0x9E3779B97F4A7C15
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

@MainActor
final class CellSceneController {
    weak var model: AppModel?

    private static let cellDiameter: Float = 1.1
    static let minScale: Float = 0.5
    static let maxScale: Float = 8

    private let cellHome = SIMD3<Float>(0, 1.35, -1.9)
    private let immersiveCenter = SIMD3<Float>(0, 1.45, 0)
    private let immersedHUD = SIMD3<Float>(0, 1.05, -0.9)
    private let scatterGap: Float = 0.32

    private let root = Entity()
    private let cellRoot = Entity()
    private let scatterRoot = Entity()
    private let introAnchor = Entity()
    private let membraneHolder = Entity()
    private let hudHolder = Entity()
    private var sky: ModelEntity?

    private var organelles: [OrganelleKind: Entity] = [:]
    private var extents: [OrganelleKind: SIMD3<Float>] = [:]
    private var infoButtons: [OrganelleKind: Entity] = [:]
    private var infoPanels: [OrganelleKind: Entity] = [:]
    private var hudEntity: Entity?
    private var introEntity: Entity?
    private var protein: ModelEntity?
    private var pulses: [Entity] = []
    private var proteinJob: Task<Void, Never>?
    private var drags: [ObjectIdentifier: (position: SIMD3<Float>, pointer: SIMD3<Float>)] = [:]
    private var magnifyStart: Float?
    private var epoch = 0
    private var unit: Float = 0.1
    private var cellRadius: Float = 0.55
    private var isLoaded = false

    func load(into content: RealityViewContent, model: AppModel) async {
        self.model = model
        guard !isLoaded else { return }
        isLoaded = true

        content.add(root)
        root.addChild(cellRoot)
        root.addChild(scatterRoot)
        root.addChild(introAnchor)
        root.addChild(hudHolder)
        cellRoot.position = cellHome

        if let membrane = await loadCentered(named: "Cell_Membrane") {
            let largest = max(membrane.extents.x, membrane.extents.y, membrane.extents.z)
            unit = Self.cellDiameter / largest
            cellRadius = Self.cellDiameter / 2
            let visual = Entity()
            visual.scale = SIMD3<Float>(repeating: unit)
            visual.addChild(membrane.entity)
            Self.makeTransparent(visual)
            membraneHolder.name = "cell"
            membraneHolder.addChild(visual)
            membraneHolder.components.set(CollisionComponent(shapes: [.generateSphere(radius: cellRadius)]))
            cellRoot.addChild(membraneHolder)
        }

        for spec in OrganelleCatalog.order {
            guard let loaded = await loadCentered(named: spec.assetName) else { continue }
            let scale = unit * spec.fit
            let visual = Entity()
            visual.scale = SIMD3<Float>(repeating: scale)
            visual.orientation = spec.orientation
            visual.addChild(loaded.entity)
            let wrapper = Entity()
            wrapper.name = spec.kind.rawValue
            wrapper.addChild(visual)
            let size = loaded.extents * scale
            extents[spec.kind] = size
            let grab = simd_max(size, SIMD3<Float>(repeating: 0.14))
            wrapper.components.set(CollisionComponent(shapes: [.generateBox(size: grab)]))
            wrapper.position = spec.slot * unit
            cellRoot.addChild(wrapper)
            organelles[spec.kind] = wrapper
        }

        let skyEntity = makeSky()
        root.addChild(skyEntity)
        sky = skyEntity

        layoutAroundCell()
        setInteractive(membraneHolder, true, hover: true)
        model.sceneReady = true
    }

    func mountIntro(_ entity: Entity) {
        guard introEntity == nil else { return }
        introEntity = entity
        entity.components.set(BillboardComponent())
        introAnchor.addChild(entity)
    }

    func mountHUD(_ entity: Entity) {
        guard hudEntity == nil else { return }
        hudEntity = entity
        entity.components.set(BillboardComponent())
        hudHolder.addChild(entity)
    }

    func mountInfoButton(_ entity: Entity, kind: OrganelleKind) {
        guard infoButtons[kind] == nil, let wrapper = organelles[kind], let size = extents[kind] else { return }
        infoButtons[kind] = entity
        entity.components.set(BillboardComponent())
        entity.position = SIMD3<Float>(max(size.x, 0.14) / 2 + 0.06, 0, 0)
        wrapper.addChild(entity)
    }

    func mountInfoPanel(_ entity: Entity, kind: OrganelleKind) {
        guard infoPanels[kind] == nil, let wrapper = organelles[kind], let size = extents[kind] else { return }
        infoPanels[kind] = entity
        entity.components.set(BillboardComponent())
        entity.position = SIMD3<Float>(0, max(size.y, 0.14) / 2 + 0.17, 0)
        wrapper.addChild(entity)
    }

    func applyState() {
        guard let model, model.sceneReady else { return }
        let phase = model.phase
        introEntity?.isEnabled = phase == .intro
        hudEntity?.isEnabled = phase != .intro
        for spec in OrganelleCatalog.order {
            let kind = spec.kind
            let visible = phase == .scatter && !model.placedKinds.contains(kind)
            infoButtons[kind]?.isEnabled = visible
            infoPanels[kind]?.isEnabled = visible && model.openInfo.contains(kind)
        }
    }

    func handleTap(on entity: Entity) {
        guard let model, model.phase == .intro, entity.name == "cell" else { return }
        beginScatter()
    }

    func dragChanged(_ value: EntityTargetValue<DragGesture.Value>) {
        guard let model, model.phase == .scatter,
              let kind = OrganelleKind(rawValue: value.entity.name),
              !model.placedKinds.contains(kind),
              let parent = value.entity.parent else { return }
        let entity = value.entity
        let key = ObjectIdentifier(entity)
        let pointer = value.convert(value.location3D, from: .local, to: parent)
        if drags[key] == nil {
            let origin = value.convert(value.startLocation3D, from: .local, to: parent)
            drags[key] = (entity.position, origin)
        }
        guard let state = drags[key] else { return }
        entity.position = state.position + (pointer - state.pointer)
    }

    func dragEnded(_ value: EntityTargetValue<DragGesture.Value>) {
        drags[ObjectIdentifier(value.entity)] = nil
        guard let model, model.phase == .scatter,
              let kind = OrganelleKind(rawValue: value.entity.name),
              !model.placedKinds.contains(kind) else { return }
        let distance = simd_distance(value.entity.position(relativeTo: nil), cellRoot.position(relativeTo: nil))
        guard distance < cellRadius * model.cellScale * 0.85 else { return }
        guard let next = model.nextSpec else { return }
        if kind == next.kind {
            Task { await place(kind) }
        } else {
            sendHome(kind)
            model.showHint("Not yet. The \(next.shortName) comes first.")
        }
    }

    func magnifyChanged(_ value: EntityTargetValue<MagnifyGesture.Value>) {
        guard let model, model.phase == .assembled else { return }
        let start = magnifyStart ?? model.cellScale
        magnifyStart = start
        let factor = powf(Float(value.magnification), 1.6)
        setCellScale(start * factor)
    }

    func magnifyEnded() {
        magnifyStart = nil
    }

    func reset() {
        guard let model else { return }
        epoch += 1
        let token = epoch
        proteinJob?.cancel()
        proteinJob = nil
        protein?.removeFromParent()
        protein = nil
        for pulse in pulses {
            pulse.removeFromParent()
        }
        pulses.removeAll()
        drags.removeAll()
        magnifyStart = nil
        model.placedKinds = []
        model.openInfo = []
        model.hint = nil
        model.caption = nil
        model.phase = .scatter
        sky?.components.remove(InputTargetComponent.self)
        setInteractive(membraneHolder, false, hover: false)
        for entity in organelles.values {
            setInteractive(entity, false, hover: false)
        }
        Task {
            if model.cellScale != 1 {
                await animateCellScale(to: 1, duration: 0.9, token: token)
            }
            guard token == epoch else { return }
            scatterAll(duration: 1.4)
            try? await Task.sleep(for: .milliseconds(1500))
            guard token == epoch else { return }
            for entity in organelles.values {
                setInteractive(entity, true, hover: true)
            }
        }
    }

    private func beginScatter() {
        guard let model else { return }
        epoch += 1
        let token = epoch
        model.phase = .scatter
        setInteractive(membraneHolder, false, hover: false)
        scatterAll(duration: 1.6)
        Task {
            try? await Task.sleep(for: .milliseconds(1700))
            guard token == epoch else { return }
            for entity in organelles.values {
                setInteractive(entity, true, hover: true)
            }
        }
    }

    private func scatterAll(duration: TimeInterval) {
        for spec in OrganelleCatalog.order {
            guard let entity = organelles[spec.kind] else { continue }
            entity.setParent(scatterRoot, preservingWorldTransform: true)
            entity.move(
                to: scatterTransform(for: spec),
                relativeTo: scatterRoot,
                duration: duration,
                timingFunction: .easeInOut
            )
        }
    }

    private func sendHome(_ kind: OrganelleKind) {
        guard let entity = organelles[kind] else { return }
        entity.move(
            to: scatterTransform(for: OrganelleCatalog.spec(for: kind)),
            relativeTo: scatterRoot,
            duration: 0.7,
            timingFunction: .easeInOut
        )
    }

    /// A spot on a vertical ring around the cell, facing the user. `scatterRoot` follows the cell, so this is cell-relative.
    private func scatterTransform(for spec: OrganelleSpec) -> Transform {
        let angle = spec.scatterAngle * .pi / 180
        let ring = cellRadius + scatterGap
        let position = SIMD3<Float>(cos(angle) * ring, sin(angle) * ring, 0)
        return Transform(scale: .one, rotation: spec.scatterTilt, translation: position)
    }

    private func place(_ kind: OrganelleKind) async {
        guard let model, let entity = organelles[kind] else { return }
        let spec = OrganelleCatalog.spec(for: kind)
        let token = epoch
        model.placedKinds.insert(kind)
        model.openInfo.remove(kind)
        model.hint = nil
        setInteractive(entity, false, hover: false)
        entity.setParent(cellRoot, preservingWorldTransform: true)
        entity.move(
            to: Transform(scale: .one, translation: spec.slot * unit),
            relativeTo: cellRoot,
            duration: 0.6,
            timingFunction: .easeOut
        )
        try? await Task.sleep(for: .milliseconds(650))
        guard token == epoch else { return }
        // One protein travels through the whole cell, so each step waits for the previous one to finish.
        let previous = proteinJob
        let job = Task {
            await previous?.value
            guard token == epoch else { return }
            model.caption = spec.caption
            await advanceProtein(for: spec, token: token)
        }
        proteinJob = job
        await job.value
        guard token == epoch, proteinJob == job else { return }
        if model.placedKinds.count == OrganelleCatalog.order.count {
            finishAssembly()
        }
    }

    private func advanceProtein(for spec: OrganelleSpec, token: Int) async {
        let start = spec.slot * unit
        let size = extents[spec.kind] ?? SIMD3<Float>(repeating: 0.2)
        let outward = simd_length(start) > 0.001 ? simd_normalize(start) : SIMD3<Float>(0, 1, 0)
        let surface = start + outward * (max(size.x, max(size.y, size.z)) * 0.5 + 0.05)
        let destination: SIMD3<Float>
        switch spec.destination {
        case .organelle(let kind):
            destination = OrganelleCatalog.spec(for: kind).slot * unit
        case .outsideCell:
            destination = outward * cellRadius * 1.6
        case .energizeProtein:
            await energizeProtein(from: surface, color: spec.proteinColor, token: token)
            return
        }
        let middle = (surface + destination) / 2 + SIMD3<Float>(0, 0.08, 0)

        let ball: ModelEntity
        if let protein {
            ball = protein
        } else {
            ball = makeProtein(color: spec.proteinColor)
            ball.position = start
            ball.scale = SIMD3<Float>(repeating: 0.05)
            cellRoot.addChild(ball)
            protein = ball
        }
        Self.tint(ball, spec.proteinColor)

        let steps: [(Transform, TimeInterval, AnimationTimingFunction)] = [
            (Transform(scale: .one, translation: surface), 0.8, .easeOut),
            (Transform(scale: .one, translation: middle), 0.8, .easeIn),
            (Transform(scale: .one, translation: destination), 0.8, .easeOut),
            (Transform(scale: SIMD3<Float>(repeating: 2.2), translation: destination), 0.25, .easeOut),
            (Transform(scale: .one, translation: destination), 0.25, .easeIn)
        ]
        await run(steps, on: ball, token: token)
    }

    /// A short-lived energy spark that flies to the protein and makes it pulse.
    private func energizeProtein(from start: SIMD3<Float>, color: UIColor, token: Int) async {
        guard let protein else { return }
        let target = protein.position
        let spark = makeProtein(color: color)
        spark.position = start
        spark.scale = SIMD3<Float>(repeating: 0.05)
        cellRoot.addChild(spark)
        pulses.append(spark)
        let middle = (start + target) / 2 + SIMD3<Float>(0, 0.08, 0)
        await run([
            (Transform(scale: SIMD3<Float>(repeating: 0.7), translation: middle), 0.7, .easeOut),
            (Transform(scale: SIMD3<Float>(repeating: 0.7), translation: target), 0.7, .easeIn),
            (Transform(scale: SIMD3<Float>(repeating: 0.01), translation: target), 0.15, .easeIn)
        ], on: spark, token: token)
        spark.removeFromParent()
        pulses.removeAll { $0 === spark }
        guard token == epoch else { return }
        await run([
            (Transform(scale: SIMD3<Float>(repeating: 2.2), translation: target), 0.25, .easeOut),
            (Transform(scale: .one, translation: target), 0.25, .easeIn)
        ], on: protein, token: token)
    }

    private func run(_ steps: [(Transform, TimeInterval, AnimationTimingFunction)], on entity: Entity, token: Int) async {
        for (target, duration, timing) in steps {
            entity.move(to: target, relativeTo: cellRoot, duration: duration, timingFunction: timing)
            try? await Task.sleep(for: .milliseconds(Int(duration * 1000) + 50))
            guard token == epoch else { return }
        }
    }

    private func makeProtein(color: UIColor) -> ModelEntity {
        let core = ModelEntity(mesh: .generateSphere(radius: 0.016), materials: [UnlitMaterial(color: color)])
        let halo = ModelEntity(mesh: .generateSphere(radius: 0.034), materials: [UnlitMaterial(color: color)])
        halo.components.set(OpacityComponent(opacity: 0.28))
        core.addChild(halo)
        return core
    }

    private static func tint(_ protein: ModelEntity, _ color: UIColor) {
        protein.model?.materials = [UnlitMaterial(color: color)]
        for case let halo as ModelEntity in protein.children {
            halo.model?.materials = [UnlitMaterial(color: color)]
        }
    }

    private func finishAssembly() {
        guard let model else { return }
        model.phase = .assembled
        model.openInfo = []
        for entity in organelles.values {
            setInteractive(entity, false, hover: false)
        }
        setInteractive(membraneHolder, true, hover: false)
        sky?.components.set(InputTargetComponent())
    }

    func setCellScale(_ requested: Float) {
        guard let model else { return }
        let scale = min(max(requested, Self.minScale), Self.maxScale)
        model.cellScale = scale
        cellRoot.scale = SIMD3<Float>(repeating: scale)
        let travel = Self.smoothstep(1.5, 3.5, scale)
        cellRoot.position = cellHome + (immersiveCenter - cellHome) * travel
        layoutAroundCell()
        let immersion = Self.smoothstep(3.0, 6.0, scale)
        model.immersion = immersion
        sky?.isEnabled = immersion > 0.001
        sky?.components.set(OpacityComponent(opacity: immersion))
        if model.wantsFullImmersion {
            model.wantsFullImmersion = immersion > 0.85
        } else {
            model.wantsFullImmersion = immersion > 0.97
        }
    }

    /// Keeps the scattered organelles, the intro card and the banner attached to the cell as it grows.
    private func layoutAroundCell() {
        let scale = model?.cellScale ?? 1
        let center = cellRoot.position
        let radius = cellRadius * scale
        scatterRoot.position = center
        scatterRoot.scale = SIMD3<Float>(repeating: scale)
        introAnchor.position = center + SIMD3<Float>(0, radius + 0.2, 0)
        let below = center + SIMD3<Float>(0, -(radius + 0.15), 0.25)
        var spot = below + (immersedHUD - below) * Self.smoothstep(1.5, 3.5, scale)
        spot.y = max(spot.y, 0.6)
        hudHolder.position = spot
    }

    private func animateCellScale(to target: Float, duration: Double, token: Int) async {
        guard let model else { return }
        let start = model.cellScale
        let steps = max(1, Int(duration * 60))
        for index in 1...steps {
            guard token == epoch else { return }
            let t = Float(index) / Float(steps)
            let eased = t * t * (3 - 2 * t)
            setCellScale(start + (target - start) * eased)
            try? await Task.sleep(for: .milliseconds(16))
        }
    }

    private func setInteractive(_ entity: Entity, _ enabled: Bool, hover: Bool) {
        if enabled {
            entity.components.set(InputTargetComponent())
        } else {
            entity.components.remove(InputTargetComponent.self)
        }
        if enabled && hover {
            entity.components.set(HoverEffectComponent())
        } else {
            entity.components.remove(HoverEffectComponent.self)
        }
    }

    private func loadCentered(named name: String) async -> (entity: Entity, extents: SIMD3<Float>)? {
        do {
            let loaded = try await Entity(named: name, in: realityKitContentBundle)
            let holder = Entity()
            holder.addChild(loaded)
            let bounds = holder.visualBounds(relativeTo: holder)
            loaded.position -= bounds.center
            return (holder, bounds.extents)
        } catch {
            print("Could not load \(name): \(error)")
            return nil
        }
    }

    private static func makeTransparent(_ entity: Entity) {
        if var component = entity.components[ModelComponent.self] {
            component.materials = component.materials.map { material -> any RealityKit.Material in
                var pbr = (material as? PhysicallyBasedMaterial) ?? PhysicallyBasedMaterial()
                if !(material is PhysicallyBasedMaterial) {
                    pbr.baseColor = .init(tint: UIColor(red: 0.0, green: 0.58, blue: 0.8, alpha: 1))
                }
                pbr.blending = .transparent(opacity: .init(floatLiteral: 0.22))
                pbr.faceCulling = .none
                return pbr
            }
            entity.components.set(component)
        }
        for child in entity.children {
            makeTransparent(child)
        }
    }

    private func makeSky() -> ModelEntity {
        var material = UnlitMaterial()
        if let image = Self.cytoplasmImage(),
           let texture = try? TextureResource.generate(from: image, options: .init(semantic: .color)) {
            material.color = .init(tint: .white, texture: .init(texture))
        } else {
            material.color = .init(tint: UIColor(red: 0.05, green: 0.2, blue: 0.3, alpha: 1))
        }
        let entity = ModelEntity(mesh: .generateSphere(radius: 20), materials: [material])
        entity.name = "sky"
        entity.scale = SIMD3<Float>(-1, 1, 1)
        entity.position = immersiveCenter
        entity.components.set(CollisionComponent(shapes: [.generateSphere(radius: 20)]))
        entity.components.set(OpacityComponent(opacity: 0))
        entity.isEnabled = false
        return entity
    }

    private static func cytoplasmImage() -> CGImage? {
        let size = CGSize(width: 2048, height: 1024)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { context in
            let cg = context.cgContext
            let colors = [
                UIColor(red: 0.10, green: 0.42, blue: 0.55, alpha: 1).cgColor,
                UIColor(red: 0.04, green: 0.16, blue: 0.30, alpha: 1).cgColor,
                UIColor(red: 0.02, green: 0.07, blue: 0.16, alpha: 1).cgColor
            ] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.5, 1]) {
                cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            }
            var generator = SeededGenerator(seed: 7)
            for _ in 0..<900 {
                let radius = CGFloat.random(in: 4...26, using: &generator)
                let x = CGFloat.random(in: 0...size.width, using: &generator)
                let y = CGFloat.random(in: 0...size.height, using: &generator)
                let alpha = CGFloat.random(in: 0.03...0.12, using: &generator)
                cg.setFillColor(UIColor(white: 1, alpha: alpha).cgColor)
                cg.fillEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
            }
        }
        return image.cgImage
    }

    private static func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }
}
