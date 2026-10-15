import RealityKit
import RealityKitContent
import SwiftUI
import UIKit
import simd

private struct SeededGenerator: RandomNumberGenerator {
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

@MainActor
final class CellSceneController {
    weak var model: AppModel?

    private static let cellDiameter: Float = 1.35
    static let minScale: Float = 0.5
    static let maxScale: Float = 20
    private static let turnPerMeter: Float = 4
    /// true: Cellmembrane.usdz with its own material. false: Cell_Membrane with the see-through material made in code.
//    private static let useCustomMembrane = true
//    private static let useCustomMembrane = false
    private static let useCustomMembrane = true
    /// true: organelles are always drawn before the see-through membrane, so it can't hide them while rotating.
    private static let forceOrganellesBeforeMembrane = true

    private let cellHome = SIMD3<Float>(0, 1.45, -2.0)
    private let immersiveCenter = SIMD3<Float>(0, 1.45, 0)
    /// Once big, the cell hangs in front and above: its lowest point ends up this far above eye level.
    private let overheadClearance: Float = 0.6
    /// How far back the cell moves per meter it grows. Below 1 its front creeps towards the viewer, so at full size
    /// it reaches over their head.
    private let growBack: Float = 0.95
    private static let skyRadius: Float = 60
    private let scatterGap: Float = 0.12

    private let root = Entity()
    private let cellRoot = Entity()
    private let scatterRoot = Entity()
    private let membraneHolder = Entity()
    private let panelHolder = Entity()
    private let cellDrawOrder = ModelSortGroup(depthPass: nil)
    private var sky: ModelEntity?
    /// Other cells drifting far off around the viewer, shown together with the sky.
    private let crowdRoot = Entity()
    private var crowd: [(entity: Entity, spin: simd_quatf)] = []
    private var crowdTemplate: Entity?

    private var organelles: [OrganelleKind: Entity] = [:]
    private var extents: [OrganelleKind: SIMD3<Float>] = [:]
    private var infoButtons: [OrganelleKind: Entity] = [:]
    private var infoPanels: [OrganelleKind: Entity] = [:]
    private var panelEntity: Entity?
    private var protein: ModelEntity?
    private var pulses: [Entity] = []
    private var proteinJob: Task<Void, Never>?
    private var drags: [ObjectIdentifier: (position: SIMD3<Float>, pointer: SIMD3<Float>)] = [:]
    private var magnifyStart: Float?
    private var turnStart: (orientation: simd_quatf, pointer: SIMD3<Float>)?
    private var epoch = 0
    private var unit: Float = 0.1
    private var cellRadius: Float = 0.675
    private var isLoaded = false
    private var panelSubscription: EventSubscription?
    private var panelHeight: Float = 0.2

    func load(into content: RealityViewContent, model: AppModel) async {
        self.model = model
        guard !isLoaded else { return }
        isLoaded = true

        content.add(root)
        panelSubscription = content.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            MainActor.assumeIsolated {
                self?.pinPanelEdge()
                self?.driftCrowd(by: Float(event.deltaTime))
            }
        }
        root.addChild(cellRoot)
        root.addChild(scatterRoot)
        root.addChild(panelHolder)
        cellRoot.position = cellHome

        let membraneName = Self.useCustomMembrane ? "Cellmembrane" : "Cell_Membrane"
        if let membrane = await loadCentered(named: membraneName) {
            let largest = max(membrane.extents.x, membrane.extents.y, membrane.extents.z)
            unit = Self.cellDiameter / largest
            cellRadius = Self.cellDiameter / 2
            let visual = Entity()
            visual.scale = SIMD3<Float>(repeating: unit)
            visual.addChild(membrane.entity)
            if !Self.useCustomMembrane {
                Self.makeTransparent(visual)
            }
            crowdTemplate = visual.clone(recursive: true)
            if Self.forceOrganellesBeforeMembrane {
                Self.setDrawOrder(visual, group: cellDrawOrder, order: 1)
            }
            membraneHolder.name = "cell"
            membraneHolder.addChild(visual)
            membraneHolder.components.set(
                CollisionComponent(shapes: [.generateSphere(radius: cellRadius)]))
            cellRoot.addChild(membraneHolder)
        }

        for spec in OrganelleCatalog.order {
            guard let loaded = await loadCentered(named: spec.assetName) else { continue }
            let scale = unit * spec.fit
            let visual = Entity()
            visual.scale = SIMD3<Float>(repeating: scale)
            visual.orientation = spec.orientation
            visual.addChild(loaded.entity)
//            let transparencyComponent = OpacityComponent(opacity: 0.5)
//            Self.makeGhostly(visual)
            if Self.forceOrganellesBeforeMembrane {
                Self.setDrawOrder(visual, group: cellDrawOrder, order: 0)
            }
            let wrapper = Entity()
            wrapper.name = spec.kind.rawValue
            wrapper.addChild(visual)
//            wrapper.components.set(transparencyComponent)
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
        makeCrowd()
        root.addChild(crowdRoot)

        layoutAroundCell()
        setInteractive(membraneHolder, true, hover: true)
        model.sceneReady = true
    }

    func mountPanel(_ entity: Entity) {
        guard panelEntity == nil else { return }
        panelEntity = entity
        entity.components.set(BillboardComponent())
        panelHolder.addChild(entity)
    }

    func mountInfoButton(_ entity: Entity, kind: OrganelleKind) {
        guard infoButtons[kind] == nil, let wrapper = organelles[kind] else { return }
        infoButtons[kind] = entity
        entity.components.set(BillboardComponent())
        // On the outer side, so it is not squeezed between the organelle and the cell.
        let angle = OrganelleCatalog.spec(for: kind).scatterAngle * .pi / 180
        let side: Float = cos(angle) < -0.01 ? -1 : 1
        entity.position = scatteredOffset(for: kind, toward: SIMD3<Float>(side, 0, 0), gap: 0.08)
        wrapper.addChild(entity)
    }

    /// The look target sits just in front of the organelle, so the system's eye tracking lands on it and reveals the panel.
    func mountInfoPanel(_ entity: Entity, kind: OrganelleKind) {
        guard infoPanels[kind] == nil, let wrapper = organelles[kind] else { return }
        infoPanels[kind] = entity
        entity.components.set(BillboardComponent())
        entity.position = scatteredOffset(for: kind, toward: SIMD3<Float>(0, 0, 1), gap: 0.02)
        wrapper.addChild(entity)
    }

    /// How big the look target over an organelle should be, in meters.
    func lookTargetSize(for kind: OrganelleKind) -> Float {
        let size = simd_max(extents[kind] ?? .zero, SIMD3<Float>(repeating: 0.14))
        return max(size.x, size.y, size.z) * 0.9
    }

    /// A spot just outside a scattered organelle in a room direction (right, up), expressed in the organelle's own
    /// tilted frame, so its info button and panel never end up behind it. Nudged towards the user so they stay in front.
    private func scatteredOffset(
        for kind: OrganelleKind, toward direction: SIMD3<Float>, gap: Float
    ) -> SIMD3<Float> {
        let spec = OrganelleCatalog.spec(for: kind)
        let half = simd_max(extents[kind] ?? .zero, SIMD3<Float>(repeating: 0.14)) / 2
        let tilt = spec.scatterTilt
        let rotation = simd_matrix3x3(tilt * spec.orientation)
        let reach =
            abs(simd_dot(rotation.columns.0, direction)) * half.x
            + abs(simd_dot(rotation.columns.1, direction)) * half.y
            + abs(simd_dot(rotation.columns.2, direction)) * half.z
        let world = direction * (reach + gap) + SIMD3<Float>(0, 0, 0.05)
        return tilt.inverse.act(world)
    }

    func applyState() {
        guard let model, model.sceneReady else { return }
        let phase = model.phase
        cellRoot.isEnabled = !model.waitingForPaper
        for spec in OrganelleCatalog.order {
            let kind = spec.kind
            let visible = phase == .scatter && !model.placedKinds.contains(kind)
            infoButtons[kind]?.isEnabled = visible
            infoPanels[kind]?.isEnabled = visible
        }
    }

    func handleTap(on entity: Entity) {
        guard let model, model.phase == .intro else { return }
        if model.waitingForPaper {
            if entity.name == "paper" {
                popOut(of: entity)
            }
        } else if entity.name == "cell" {
            beginScatter()
        }
    }

    /// The cell grows out of the tapped picture and floats up to its usual spot, then comes apart.
    private func popOut(of paper: Entity) {
        guard let model else { return }
        epoch += 1
        let token = epoch
        model.waitingForPaper = false
        let orientation = cellRoot.orientation
        cellRoot.transform = Transform(
            scale: SIMD3<Float>(repeating: 0.02), rotation: orientation,
            translation: paper.position(relativeTo: root))
        cellRoot.move(
            to: Transform(scale: .one, rotation: orientation, translation: cellHome),
            relativeTo: root,
            duration: 1.8,
            timingFunction: .easeOut
        )
        Task {
            try? await Task.sleep(for: .milliseconds(2800))
            guard token == epoch else { return }
            beginScatter()
        }
    }

    func dragChanged(_ value: EntityTargetValue<DragGesture.Value>) {
        if value.entity === membraneHolder || value.entity === sky {
            turnCell(value)
            return
        }
        guard let model, model.phase == .scatter,
            let kind = OrganelleKind(rawValue: value.entity.name),
            !model.placedKinds.contains(kind),
            let parent = value.entity.parent
        else { return }
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
        turnStart = nil
        guard let kind = OrganelleKind(rawValue: value.entity.name) else { return }
        release(kind)
    }

    /// Drag that starts on an organelle's look target. `translation` is in meters, in world space.
    func dragOrganelle(_ kind: OrganelleKind, by translation: SIMD3<Float>) {
        guard let model, model.phase == .scatter, !model.placedKinds.contains(kind),
            let entity = organelles[kind]
        else { return }
        let key = ObjectIdentifier(entity)
        if drags[key] == nil {
            drags[key] = (entity.position(relativeTo: nil), .zero)
        }
        guard let state = drags[key] else { return }
        entity.setPosition(state.position + translation, relativeTo: nil)
    }

    func dragOrganelleEnded(_ kind: OrganelleKind) {
        guard let entity = organelles[kind] else { return }
        drags[ObjectIdentifier(entity)] = nil
        release(kind)
    }

    /// Drops an organelle: into the cell if it is the next one and close enough, otherwise back to its spot.
    private func release(_ kind: OrganelleKind) {
        guard let model, model.phase == .scatter, !model.placedKinds.contains(kind),
            let entity = organelles[kind]
        else { return }
        let distance = simd_distance(
            entity.position(relativeTo: nil), cellRoot.position(relativeTo: nil))
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
        turnStart = nil
        let factor = powf(Float(value.magnification), 1.6)
        setCellScale(start * factor)
    }

    func magnifyEnded() {
        magnifyStart = nil
    }

    /// One-hand drag on the cell (or the space around it, once inside) turns it: sideways spins it, up and down tips it.
    /// Ignored while a two-hand pinch is scaling, and re-anchored afterwards so the cell does not jump.
    private func turnCell(_ value: EntityTargetValue<DragGesture.Value>) {
        guard let model, magnifyStart == nil else { return }
        let pointer = value.convert(value.location3D, from: .local, to: .scene)
        if turnStart == nil {
            turnStart = (cellRoot.orientation, pointer)
        }
        guard let start = turnStart else { return }
        let delta = pointer - start.pointer
        // From inside the cell you grab the far wall, so the directions flip to keep it following your hand.
        let sign: Float = model.immersion > 0.5 ? -1 : 1
        let spin = simd_quatf(
            angle: sign * delta.x * Self.turnPerMeter, axis: SIMD3<Float>(0, 1, 0))
        let tip = simd_quatf(
            angle: -sign * delta.y * Self.turnPerMeter, axis: SIMD3<Float>(1, 0, 0))
        cellRoot.orientation = simd_normalize(spin * tip * start.orientation)
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
        turnStart = nil
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
            if model.cellScale != 1 || cellRoot.orientation != simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
            {
                await animateCellHome(duration: 0.9, token: token)
            }
            guard token == epoch else { return }
            scatterAll(duration: 1.4)
            try? await Task.sleep(for: .milliseconds(1500))
            guard token == epoch else { return }
            setInteractive(membraneHolder, true, hover: false)
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
        // Stays grabbable so it can be turned; the tap highlight is only for the intro.
        setInteractive(membraneHolder, true, hover: false)
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
            // Dock on the near side of the target instead of its centre. The ER shares the nucleus slot,
            // so aiming at the centre would send the protein back into the nucleus.
            let center = OrganelleCatalog.spec(for: kind).slot * unit
            let half = simd_max(extents[kind] ?? .zero, SIMD3<Float>(repeating: 0.14)) / 2
            let toSource = surface - center
            if simd_length(toSource) > 0.001 {
                let direction = simd_normalize(toSource)
                let reach = 1 / simd_length(direction / half)
                destination = center + direction * min(reach * 0.85, simd_length(toSource))
            } else {
                destination = center
            }
        case .outsideCell:
            destination = outward * cellRadius * 1.6
        case .energizeProtein:
            await spreadEnergy(from: start, color: spec.proteinColor, token: token)
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
            (
                Transform(scale: SIMD3<Float>(repeating: 2.2), translation: destination), 0.25,
                .easeOut
            ),
            (Transform(scale: .one, translation: destination), 0.25, .easeIn),
        ]
        await run(steps, on: ball, token: token)
        if case .outsideCell = spec.destination {
            await fadeOutProtein(ball, token: token)
        }
    }

    /// Once the protein has left the cell it fades away.
    private func fadeOutProtein(_ ball: ModelEntity, token: Int) async {
        let frames = 40
        for frame in 1...frames {
            guard token == epoch else { return }
            ball.components.set(OpacityComponent(opacity: 1 - Float(frame) / Float(frames)))
            try? await Task.sleep(for: .milliseconds(16))
        }
        guard token == epoch else { return }
        ball.removeFromParent()
        if protein === ball {
            protein = nil
        }
    }

    /// ATP sparks that burst from the mitochondrion and spread through the cell.
    private func spreadEnergy(from start: SIMD3<Float>, color: UIColor, token: Int) async {
        var sparks: [(entity: ModelEntity, target: SIMD3<Float>)] = []
        for _ in 0..<32 {
            var direction = SIMD3<Float>(
                .random(in: -1...1), .random(in: -1...1), .random(in: -1...1))
            direction =
                simd_length(direction) > 0.001 ? simd_normalize(direction) : SIMD3<Float>(0, 1, 0)
            let target = direction * cellRadius * Float.random(in: 0.3...0.9)
            let spark = makeProtein(color: color)
            spark.position = start
            spark.scale = SIMD3<Float>(repeating: .random(in: 0.4...0.8))
            cellRoot.addChild(spark)
            pulses.append(spark)
            sparks.append((spark, target))
        }

        let frames = 120
        for frame in 1...frames {
            guard token == epoch else { return }
            let t = Float(frame) / Float(frames)
            let grow = 1 - powf(1 - t, 3)
            let sparkOpacity = 1 - Self.smoothstep(0.6, 1, t)
            for (spark, target) in sparks {
                spark.position = start + (target - start) * grow
                spark.components.set(OpacityComponent(opacity: sparkOpacity))
            }
            try? await Task.sleep(for: .milliseconds(16))
        }
        for (spark, _) in sparks {
            spark.removeFromParent()
        }
        pulses.removeAll { pulse in sparks.contains { $0.entity === pulse } }
        guard token == epoch, let protein else { return }
        let target = protein.position
        await run(
            [
                (
                    Transform(scale: SIMD3<Float>(repeating: 2.2), translation: target), 0.25,
                    .easeOut
                ),
                (Transform(scale: .one, translation: target), 0.25, .easeIn),
            ], on: protein, token: token)
    }

    private func run(
        _ steps: [(Transform, TimeInterval, AnimationTimingFunction)], on entity: Entity, token: Int
    ) async {
        for (target, duration, timing) in steps {
            entity.move(
                to: target, relativeTo: cellRoot, duration: duration, timingFunction: timing)
            try? await Task.sleep(for: .milliseconds(Int(duration * 1000) + 50))
            guard token == epoch else { return }
        }
    }

    private func makeProtein(color: UIColor) -> ModelEntity {
        let core = ModelEntity(
            mesh: .generateSphere(radius: 0.016), materials: [UnlitMaterial(color: color)])
        let halo = ModelEntity(
            mesh: .generateSphere(radius: 0.034), materials: [UnlitMaterial(color: color)])
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
        // Grows up and away from its base, so it never swallows the viewer or the panel below it, and its base
        // lifts above eye level on the way.
        let grown = max(scale - 1, 0) * cellRadius
        let lift = (immersiveCenter.y + overheadClearance - (cellHome.y - cellRadius))
            * Self.smoothstep(1, 3.5, scale)
        cellRoot.position = cellHome + SIMD3<Float>(0, grown + lift, -growBack * grown)
        layoutAroundCell()
        let immersion = Self.smoothstep(3.0, 6.0, scale)
        model.immersion = immersion
        sky?.isEnabled = immersion > 0.001
        sky?.components.set(OpacityComponent(opacity: immersion))
        crowdRoot.isEnabled = immersion > 0.001
        crowdRoot.components.set(OpacityComponent(opacity: immersion))
        if model.wantsFullImmersion {
            model.wantsFullImmersion = immersion > 0.85
        } else {
            model.wantsFullImmersion = immersion > 0.97
        }
    }

    /// Keeps the scattered organelles attached to the cell as it grows.
    private func layoutAroundCell() {
        let scale = model?.cellScale ?? 1
        scatterRoot.position = cellRoot.position
        scatterRoot.scale = SIMD3<Float>(repeating: scale)
        panelHolder.position = panelSpot()
    }

    /// Below the cell at its normal size, where the panel's top edge touches it. Stays put while the cell grows.
    /// The intro card and the progress banner share it.
    private func panelSpot() -> SIMD3<Float> {
        // Tucked up against the lower part of the cell, pulled forward so the membrane does not cut through it.
        var spot = cellHome + SIMD3<Float>(0, -(cellRadius - 0.12), cellRadius * 0.6)
        spot.y = max(spot.y, 0.5 + panelHeight)
        return spot
    }

    /// Hangs the panel off `panelHolder` by its edge, so it hugs the cell whatever height its content has.
    /// Eased per frame so the panel grows and shrinks smoothly downwards while its content morphs.
    private func pinPanelEdge() {
        guard let panelEntity else { return }
        let height = panelEntity.visualBounds(relativeTo: panelHolder).extents.y
        guard height > 0 else { return }
        panelHeight = height
        let target = -height / 2
        // Snap on the first measurement so the intro card does not slide into place on launch.
        let ease: Float = panelEntity.position.y == 0 ? 1 : 0.15
        panelEntity.position.y += (target - panelEntity.position.y) * ease
    }

    /// Shrinks the cell back to 1× and turns it upright again.
    private func animateCellHome(duration: Double, token: Int) async {
        guard let model else { return }
        let start = model.cellScale
        let startOrientation = cellRoot.orientation
        let upright = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        let steps = max(1, Int(duration * 60))
        for index in 1...steps {
            guard token == epoch else { return }
            let t = Float(index) / Float(steps)
            let eased = t * t * (3 - 2 * t)
            setCellScale(start + (1 - start) * eased)
            cellRoot.orientation = simd_slerp(startOrientation, upright, eased)
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

    private func loadCentered(named name: String) async -> (entity: Entity, extents: SIMD3<Float>)?
    {
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

    /// Slightly see-through organelles. The depth pre-pass keeps each one from showing its own hidden parts through itself.
    private static func makeGhostly(_ entity: Entity) {
        entity.components.set(OpacityComponent(opacity: 0.75))
        let group = ModelSortGroup(depthPass: .prePass)
        func assign(_ entity: Entity) {
            if entity.components.has(ModelComponent.self) {
                entity.components.set(ModelSortGroupComponent(group: group, order: 0))
            }
            entity.children.forEach(assign)
        }
        assign(entity)
    }

    /// Within one sort group, lower orders are drawn first.
    private static func setDrawOrder(_ entity: Entity, group: ModelSortGroup, order: Int32) {
        if entity.components.has(ModelComponent.self) {
            entity.components.set(ModelSortGroupComponent(group: group, order: order))
        }
        for child in entity.children {
            setDrawOrder(child, group: group, order: order)
        }
    }

    private func makeSky() -> ModelEntity {
        var material = UnlitMaterial()
        if let image = Self.bodyImage(),
            let texture = try? TextureResource.generate(
                from: image, options: .init(semantic: .color))
        {
            material.color = .init(tint: .white, texture: .init(texture))
        } else {
            material.color = .init(tint: UIColor(red: 0.3, green: 0.03, blue: 0.05, alpha: 1))
        }
        let entity = ModelEntity(mesh: .generateSphere(radius: Self.skyRadius), materials: [material])
        entity.name = "sky"
        entity.scale = SIMD3<Float>(-1, 1, 1)
        entity.position = immersiveCenter
        entity.components.set(CollisionComponent(shapes: [.generateSphere(radius: Self.skyRadius)]))
        entity.components.set(OpacityComponent(opacity: 0))
        entity.isEnabled = false
        return entity
    }

    /// Copies of the membrane scattered far away, so the viewer is one cell among many in the body.
    private func makeCrowd() {
        guard let template = crowdTemplate else { return }
        var generator = SeededGenerator(seed: 11)
        let count = 10
        crowdRoot.position = immersiveCenter
        crowdRoot.isEnabled = false
        for index in 0..<count {
            // Spread evenly around the viewer, jittered so they do not read as a ring.
            let yaw = Float(index) / Float(count) * 2 * .pi + .random(in: -0.25...0.25, using: &generator)
            let pitch = Float.random(in: -0.4...0.5, using: &generator)
            let distance = Float.random(in: 38...52, using: &generator)
            let direction = SIMD3<Float>(cos(pitch) * sin(yaw), sin(pitch), -cos(pitch) * cos(yaw))
            let cell = template.clone(recursive: true)
            let holder = Entity()
            holder.position = direction * distance
            holder.scale = SIMD3<Float>(repeating: .random(in: 4...7, using: &generator))
            holder.orientation = simd_quatf(
                angle: .random(in: 0...(2 * .pi), using: &generator), axis: Self.randomAxis(&generator))
            holder.addChild(cell)
            crowdRoot.addChild(holder)
            let spin = simd_quatf(angle: .random(in: 0.03...0.08, using: &generator), axis: Self.randomAxis(&generator))
            crowd.append((holder, spin))
        }
    }

    /// Each distant cell tumbles slowly, and the whole crowd circles the viewer very slowly.
    private func driftCrowd(by seconds: Float) {
        guard crowdRoot.isEnabled else { return }
        crowdRoot.orientation = simd_normalize(
            simd_quatf(angle: 0.01 * seconds, axis: SIMD3<Float>(0, 1, 0)) * crowdRoot.orientation)
        for (entity, spin) in crowd {
            entity.orientation = simd_normalize(
                simd_quatf(angle: spin.angle * seconds, axis: spin.axis) * entity.orientation)
        }
    }

    private static func randomAxis(_ generator: inout SeededGenerator) -> SIMD3<Float> {
        simd_normalize(SIMD3<Float>(
            .random(in: -1...1, using: &generator),
            .random(in: -1...1, using: &generator),
            .random(in: -1...1, using: &generator)) + SIMD3<Float>(0, 0.001, 0))
    }

    /// The inside of the body: deep reds, soft glowing patches, and red blood cells drifting far away.
    private static func bodyImage() -> CGImage? {
        let size = CGSize(width: 2048, height: 1024)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let space = CGColorSpaceCreateDeviceRGB()
        let image = renderer.image { context in
            let cg = context.cgContext
            let colors =
                [
                    UIColor(red: 0.55, green: 0.10, blue: 0.12, alpha: 1).cgColor,
                    UIColor(red: 0.32, green: 0.03, blue: 0.06, alpha: 1).cgColor,
                    UIColor(red: 0.12, green: 0.01, blue: 0.03, alpha: 1).cgColor,
                ] as CFArray
            if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 0.5, 1]) {
                cg.drawLinearGradient(
                    gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            }
            var generator = SeededGenerator(seed: 7)
            // Soft light and shadow in the tissue.
            for _ in 0..<60 {
                let radius = CGFloat.random(in: 60...220, using: &generator)
                let center = CGPoint(
                    x: .random(in: 0...size.width, using: &generator),
                    y: .random(in: 0...size.height, using: &generator))
                let light = Bool.random(using: &generator)
                let tone = light
                    ? UIColor(red: 0.95, green: 0.35, blue: 0.35, alpha: .random(in: 0.06...0.16, using: &generator))
                    : UIColor(red: 0.08, green: 0.0, blue: 0.02, alpha: .random(in: 0.15...0.3, using: &generator))
                let glow = [tone.cgColor, tone.withAlphaComponent(0).cgColor] as CFArray
                if let gradient = CGGradient(colorsSpace: space, colors: glow, locations: [0, 1]) {
                    cg.drawRadialGradient(
                        gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius,
                        options: [])
                }
            }
            // Red blood cells: discs with a darker dimple, blurred by distance.
            for _ in 0..<160 {
                let radius = CGFloat.random(in: 5...18, using: &generator)
                let center = CGPoint(
                    x: .random(in: 0...size.width, using: &generator),
                    y: .random(in: size.height * 0.15...size.height * 0.85, using: &generator))
                let alpha = CGFloat.random(in: 0.25...0.6, using: &generator)
                let squash = CGFloat.random(in: 0.45...1, using: &generator)
                let rim = UIColor(red: 0.85, green: 0.12, blue: 0.14, alpha: alpha)
                let dimple = UIColor(red: 0.45, green: 0.04, blue: 0.07, alpha: alpha)
                let disc = [dimple.cgColor, rim.cgColor, rim.withAlphaComponent(0).cgColor] as CFArray
                cg.saveGState()
                cg.translateBy(x: center.x, y: center.y)
                cg.rotate(by: .random(in: 0...(.pi), using: &generator))
                cg.scaleBy(x: 1, y: squash)
                if let gradient = CGGradient(colorsSpace: space, colors: disc, locations: [0, 0.65, 1]) {
                    cg.drawRadialGradient(
                        gradient, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: radius,
                        options: [])
                }
                cg.restoreGState()
            }
        }
        return image.cgImage
    }

    private static func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }
}
