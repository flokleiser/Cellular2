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
    /// The membrane's size relative to the organelles inside it. Above 1 leaves more room between them and the wall.
    private static let membraneScale: Float = 1.2
    static let minScale: Float = 0.5
    static let maxScale: Float = 62
    private static let turnPerMeter: Float = 4
    /// Stretches every protein and ATP animation; 2 runs them at half speed.
    private static let proteinPace: Double = 2
    /// The part of the cell that can be tapped and turned, as a share of its radius. Kept inside the membrane so
    /// organelles near its edge are grabbed instead of the cell.
    private static let membraneGrab: Float = 0.75
    /// A held organelle brought this close to the viewer's head, in meters, is drawn to the hand from then on.
    private static let magnetReach: Float = 0.75
    /// The same happens when the hand itself comes this close to the head.
    private static let handReach: Float = 0.3
    /// How strongly a held organelle is drawn to the hand: higher catches up faster.
    private static let magnetPull: Float = 10
    /// Slowest hand speed, in meters per second, that counts as a throw when letting go.
    private static let throwSpeed: Float = 0.7
    /// How far off, in radians, a throw may aim past the edge of the cell and still go in.
    private static let throwAim: Float = 0.35
    /// How quickly a released cell stops turning, per second. Higher stops sooner.
    private static let spinFriction: Float = 2.5
    /// Fastest a flick can set the cell turning, in radians per second.
    private static let maxSpin: Float = 10
    /// true: Cellmembrane.usdz with its own material. false: Cell_Membrane with the see-through material made in code.
//    private static let useCustomMembrane = true
//    private static let useCustomMembrane = false
    private static let useCustomMembrane = true
    /// true: organelles are always drawn before the see-through membrane, so it can't hide them while rotating.
    private static let forceOrganellesBeforeMembrane = true

    private let cellHome = SIMD3<Float>(0, 1.45, -2.0)
    private let immersiveCenter = SIMD3<Float>(0, 1.45, 0)
    /// How high the big cell ends up: its lowest point sits this many meters above eye level.
    /// 0 puts the bottom at eye height, negative values bring it lower still (it then starts to cover the panel).
    private let overheadClearance: Float = 0.2
    /// How far back the cell moves per meter it grows. Below 1 its front creeps towards the viewer, so at full size
    /// it reaches over their head.
    private let growBack: Float = 0.95
    private static let skyRadius: Float = 250
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
    private var holds: [OrganelleKind: Hold] = [:]
    /// Organelles on their way from a throw, which cannot be grabbed until they land.
    private var flying: Set<OrganelleKind> = []
    /// Held organelles turn with the hand: its rotation and the model's when the grip began, both in world space.
    private var grips: [OrganelleKind: (hand: simd_quatf, model: simd_quatf)] = [:]
    /// The model inside each organelle's wrapper, the part a hand turns.
    private var visuals: [OrganelleKind: Entity] = [:]
    private var magnifyStart: Float?
    private var turnStart: (orientation: simd_quatf, pointer: SIMD3<Float>, pace: Float)?
    /// Latest turn of the drag in progress (spin, tip in radians) and how fast it is changing.
    private var turnSample: (angles: SIMD2<Float>, time: Date)?
    private var turnVelocity = SIMD2<Float>.zero
    /// Keeps the cell turning after the drag lets go, slowing down until it stops.
    private var spinVelocity = SIMD2<Float>.zero
    private var shakeJob: Task<Void, Never>?
    private var epoch = 0
    private var unit: Float = 0.1
    private var cellRadius: Float = 0.675
    private var isLoaded = false
    /// The Reality Composer Pro scene that holds every model with the materials set up there.
    private static let sceneName = "CellOverview"
    private var scene: Entity?
    private var panelSubscription: EventSubscription?
    private var panelHeight: Float = 0.2
    /// Played from the picture when it is tapped, from the cell when it comes apart, from each organelle as it
    /// settles into the cell, and from one that is turned away.
    private var paperSound: AudioFileResource?
    /// Plays the paper sound where the picture was. The picture's own tap target is switched off as soon as it is
    /// tapped, which would cut the sound off.
    private let paperSpeaker = Entity()
    private var enterSound: AudioFileResource?
    private var placedSound: AudioFileResource?
    private var wrongSound: AudioFileResource?
    /// The cell is still growing out of the picture, so tapping it does nothing yet.
    private var isPoppingOut = false
    /// Where the viewer's head is, in world space, when the device reports it.
    var viewerPosition: () -> SIMD3<Float>? = { nil }

    /// An organelle in the hand. It follows the drag at a distance until it or the hand comes close to the viewer;
    /// then it turns `magnetic` and glides towards `target` every frame, held just in front of the hand.
    private struct Hold {
        var start: SIMD3<Float>
        var pointerStart: SIMD3<Float>
        var target: SIMD3<Float>
        var magnetic: Bool
        var sample: (point: SIMD3<Float>, time: Date)?
        var velocity = SIMD3<Float>.zero
    }

    func load(into content: RealityViewContent, model: AppModel) async {
        self.model = model
        guard !isLoaded else { return }
        isLoaded = true

        content.add(root)
        panelSubscription = content.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            MainActor.assumeIsolated {
                self?.pinPanelEdge()
                self?.driftCrowd(by: Float(event.deltaTime))
                self?.coast(by: Float(event.deltaTime))
                self?.glideHeld(by: Float(event.deltaTime))
            }
        }
        root.addChild(cellRoot)
        root.addChild(scatterRoot)
        root.addChild(panelHolder)
        root.addChild(paperSpeaker)
        cellRoot.position = cellHome
        do {
            scene = try await Entity(named: Self.sceneName, in: realityKitContentBundle)
        } catch {
            print("Could not load \(Self.sceneName), using the bare models: \(error)")
        }
        paperSound = try? await AudioFileResource(named: "paper_tap.wav")
        enterSound = try? await AudioFileResource(named: "enter cell journey sound.wav")
        placedSound = try? await AudioFileResource(named: "organells_placed.wav")
        wrongSound = try? await AudioFileResource(named: "wrong_organell.wav")

        let membraneName = Self.useCustomMembrane ? "Cellmembrane" : "Cell_Membrane"
        if let membrane = await loadCentered(named: membraneName) {
            let largest = max(membrane.extents.x, membrane.extents.y, membrane.extents.z)
            unit = Self.cellDiameter / largest
            cellRadius = Self.cellDiameter / 2 * Self.membraneScale
            let visual = Entity()
            visual.scale = SIMD3<Float>(repeating: unit * Self.membraneScale)
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
                CollisionComponent(shapes: [.generateSphere(radius: cellRadius * Self.membraneGrab)]))
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
            visuals[spec.kind] = visual
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

    /// Organelles that scatter to the left keep their info card on their left, so it opens away from the cell.
    static func opensLeft(_ kind: OrganelleKind) -> Bool {
        cos(OrganelleCatalog.spec(for: kind).scatterAngle * .pi / 180) < -0.01
    }

    /// The info card's button sits just outside the organelle; the card hangs off it so it grows outward and down
    /// without the button moving. The holder faces the user, so the card's offset is in screen directions.
    func mountInfoCard(_ entity: Entity, kind: OrganelleKind) {
        guard infoButtons[kind] == nil, let wrapper = organelles[kind] else { return }
        let spec = OrganelleCatalog.spec(for: kind)
        let side: Float = Self.opensLeft(kind) ? -1 : 1
        let holder = Entity()
        holder.components.set(BillboardComponent())
        // In front of the organelle's grab box and look target, so neither catches the taps meant for the button.
        let beside = SIMD3<Float>(side, 0, 0) * (reach(of: kind, toward: SIMD3<Float>(side, 0, 0)) + spec.infoGap)
        let ahead = SIMD3<Float>(0, 0, reach(of: kind, toward: SIMD3<Float>(0, 0, 1)) + 0.12)
        holder.position = spec.scatterTilt.inverse.act(beside + ahead)
        let corner = InfoCard.inset + InfoCard.buttonSide / 2
        entity.position = SIMD3<Float>(
            side * (InfoCard.size.x / 2 - corner), -(InfoCard.size.y / 2 - corner), 0)
        holder.addChild(entity)
        wrapper.addChild(holder)
        infoButtons[kind] = holder
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
        let world = direction * (reach(of: kind, toward: direction) + gap) + SIMD3<Float>(0, 0, 0.05)
        return OrganelleCatalog.spec(for: kind).scatterTilt.inverse.act(world)
    }

    /// How far a resting organelle's grab box reaches from its centre in a room direction.
    private func reach(of kind: OrganelleKind, toward direction: SIMD3<Float>) -> Float {
        let spec = OrganelleCatalog.spec(for: kind)
        let half = simd_max(extents[kind] ?? .zero, SIMD3<Float>(repeating: 0.14)) / 2
        let rotation = simd_matrix3x3(spec.scatterTilt * spec.orientation)
        return abs(simd_dot(rotation.columns.0, direction)) * half.x
            + abs(simd_dot(rotation.columns.1, direction)) * half.y
            + abs(simd_dot(rotation.columns.2, direction)) * half.z
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
        } else if entity.name == "cell", !isPoppingOut {
            beginScatter()
        }
    }

    /// The cell grows out of the tapped picture and floats up to its usual spot, where it waits to be tapped.
    private func popOut(of paper: Entity) {
        guard let model else { return }
        epoch += 1
        model.waitingForPaper = false
        isPoppingOut = true
        paperSpeaker.setPosition(paper.position(relativeTo: nil), relativeTo: nil)
        play(paperSound, from: paperSpeaker)
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
            try? await Task.sleep(for: .milliseconds(1800))
            isPoppingOut = false
        }
    }

    func dragChanged(_ value: EntityTargetValue<DragGesture.Value>) {
        if value.entity === membraneHolder || value.entity === sky {
            turnCell(value)
            return
        }
        guard let kind = OrganelleKind(rawValue: value.entity.name) else { return }
        hold(
            kind,
            pointer: value.convert(value.location3D, from: .local, to: .scene),
            pointerStart: value.convert(value.startLocation3D, from: .local, to: .scene),
            hand: value.inputDevicePose3D.map { value.convert($0.position, from: .local, to: .scene) },
            grip: value.inputDevicePose3D.map { Self.realityRotation($0.rotation) })
    }

    func dragEnded(_ value: EntityTargetValue<DragGesture.Value>) {
        if turnStart != nil {
            releaseTurn(value)
        }
        turnStart = nil
        guard let kind = OrganelleKind(rawValue: value.entity.name) else { return }
        letGo(kind)
    }

    /// A grabbed organelle closes its info card, which stays hidden until it is let go.
    private func startDragging(_ kind: OrganelleKind) {
        model?.openInfo.remove(kind)
        model?.draggingKinds.insert(kind)
    }

    /// Drag that starts on an organelle's look target. `translation` and `hand` are in meters, in world space;
    /// `hand` and `grip` are where the pinching hand is and how it is turned, when the system reports it.
    func dragOrganelle(
        _ kind: OrganelleKind, by translation: SIMD3<Float>, hand: SIMD3<Float>?, grip: simd_quatf?
    ) {
        hold(kind, pointer: translation, pointerStart: .zero, hand: hand, grip: grip)
    }

    /// Moves a held organelle along with the drag (`pointer` against `pointerStart`, both in world space). Once it
    /// or the hand comes close to the viewer, it is drawn to the hand like a magnet instead, for as long as it is
    /// held. The speed is kept for when it lets go.
    private func hold(
        _ kind: OrganelleKind, pointer: SIMD3<Float>, pointerStart: SIMD3<Float>, hand: SIMD3<Float>?,
        grip: simd_quatf?
    ) {
        guard let model, model.phase == .scatter, !model.placedKinds.contains(kind), !flying.contains(kind),
            let entity = organelles[kind]
        else { return }
        let viewer = viewerPosition() ?? immersiveCenter
        // A hand reported out of arm's reach is a pose in the wrong space, so it never pulls.
        let reachable = hand.map { simd_distance($0, viewer) < 1.2 } ?? false
        if holds[kind] == nil {
            let position = entity.position(relativeTo: nil)
            holds[kind] = Hold(start: position, pointerStart: pointerStart, target: position, magnetic: false)
            startDragging(kind)
        }
        guard var held = holds[kind] else { return }
        var point = held.start + (pointer - pointerStart)
        if !held.magnetic {
            held.target = point
            entity.setPosition(point, relativeTo: nil)
            if let hand, reachable,
                simd_distance(point, viewer) < Self.magnetReach || simd_distance(hand, viewer) < Self.handReach
            {
                held.magnetic = true
                // The hand is somewhere else than the drag point, so its speed is measured afresh.
                held.sample = nil
                held.velocity = .zero
            }
        }
        if held.magnetic {
            // Keeps the last target when the hand drops out for a moment.
            guard let hand, reachable else { return }
            point = hand
            held.target = hand + holdOffset(for: kind, hand: hand, viewer: viewer)
        }
        let now = Date()
        if let last = held.sample {
            let seconds = Float(now.timeIntervalSince(last.time))
            if seconds > 0.001 {
                // Smoothed, so one jittery hand sample does not decide the throw.
                held.velocity += ((point - last.point) / seconds - held.velocity) * 0.5
            }
        }
        held.sample = (point, now)
        holds[kind] = held
        turnWithHand(kind, grip: grip)
    }

    /// Holds the organelle just beyond the fingertips and a little up, so the hand does not disappear inside it.
    private func holdOffset(for kind: OrganelleKind, hand: SIMD3<Float>, viewer: SIMD3<Float>) -> SIMD3<Float> {
        var away = hand - viewer
        away.y = 0
        let forward = simd_length(away) > 0.001 ? simd_normalize(away) : SIMD3<Float>(0, 0, -1)
        let size = extents[kind] ?? SIMD3<Float>(repeating: 0.2)
        let radius = max(size.x, max(size.y, size.z)) / 2
        return forward * (radius + 0.04) + SIMD3<Float>(0, 0.03, 0)
    }

    /// Eases magnetic organelles towards the hand, every frame, so they keep coming while the hand is still.
    private func glideHeld(by seconds: Float) {
        let pull = 1 - exp(-Self.magnetPull * seconds)
        for (kind, held) in holds where held.magnetic {
            guard let entity = organelles[kind] else { continue }
            let position = entity.position(relativeTo: nil)
            entity.setPosition(position + (held.target - position) * pull, relativeTo: nil)
        }
    }

    /// Turns a held organelle by however much the hand has turned since it took hold.
    private func turnWithHand(_ kind: OrganelleKind, grip: simd_quatf?) {
        guard let grip, let visual = visuals[kind] else { return }
        guard let start = grips[kind] else {
            grips[kind] = (grip, visual.orientation(relativeTo: nil))
            return
        }
        let turned = grip * start.hand.inverse
        visual.setOrientation(simd_normalize(turned * start.model), relativeTo: nil)
    }

    /// SwiftUI's immersive space has y pointing down, RealityKit's up. Mirroring that axis flips the rotation
    /// direction around x and z.
    static func realityRotation(_ rotation: Rotation3D) -> simd_quatf {
        let q = rotation.quaternion
        return simd_normalize(simd_quatf(
            ix: Float(-q.imag.x), iy: Float(q.imag.y), iz: Float(-q.imag.z), r: Float(q.real)))
    }

    /// Back to the orientation the organelle was modelled in, which is how it sits in the cell.
    private func straighten(_ kind: OrganelleKind, duration: TimeInterval) {
        guard let visual = visuals[kind] else { return }
        var upright = visual.transform
        upright.rotation = OrganelleCatalog.spec(for: kind).orientation
        visual.move(to: upright, relativeTo: visual.parent, duration: duration, timingFunction: .easeInOut)
    }

    func dragOrganelleEnded(_ kind: OrganelleKind) {
        letGo(kind)
    }

    private func letGo(_ kind: OrganelleKind) {
        let held = holds.removeValue(forKey: kind)
        model?.draggingKinds.remove(kind)
        grips[kind] = nil
        var velocity = held?.velocity ?? .zero
        // A hand that had come to rest before opening is putting the organelle down, not throwing it.
        if let last = held?.sample, Date().timeIntervalSince(last.time) > 0.15 {
            velocity = .zero
        }
        release(kind, velocity: velocity, wasInHand: held?.magnetic ?? false)
    }

    /// Lets go of an organelle: dropped inside the cell or thrown at it, it goes in if it is the next one and bounces
    /// back otherwise. Anywhere else it stays where it was let go, unless it was in the hand, right by the viewer:
    /// then it floats back to its spot.
    private func release(_ kind: OrganelleKind, velocity: SIMD3<Float>, wasInHand: Bool) {
        guard let model, model.phase == .scatter, !model.placedKinds.contains(kind), !flying.contains(kind),
            let entity = organelles[kind], let next = model.nextSpec
        else { return }
        let position = entity.position(relativeTo: nil)
        let center = cellRoot.position(relativeTo: nil)
        let radius = cellRadius * model.cellScale
        if simd_distance(position, center) < radius * 0.85 {
            if kind == next.kind {
                Task { await place(kind) }
            } else {
                refuse(kind, next: next)
            }
        } else if isThrow(velocity, from: position, at: center, radius: radius) {
            throwIn(kind, velocity: velocity, isNext: kind == next.kind)
        } else if wasInHand {
            sendHome(kind)
        }
    }

    private func refuse(_ kind: OrganelleKind, next: OrganelleSpec) {
        play(wrongSound, from: organelles[kind] ?? cellRoot)
        sendHome(kind)
        shake()
        model?.showHint("Not yet. The \(next.shortName) comes first.")
    }

    /// Fast enough, and aimed at the cell give or take `throwAim`.
    private func isThrow(
        _ velocity: SIMD3<Float>, from position: SIMD3<Float>, at center: SIMD3<Float>, radius: Float
    ) -> Bool {
        let speed = simd_length(velocity)
        let toCell = center - position
        let distance = simd_length(toCell)
        guard speed >= Self.throwSpeed, distance > 0.001 else { return false }
        let edge = asin(min(radius / distance, 1))
        let cone = min(edge + Self.throwAim, .pi / 2.2)
        return simd_dot(velocity / speed, toCell / distance) >= cos(cone)
    }

    /// Flies a thrown organelle off the hand along the throw and curves it into its slot, or, when it is not its
    /// turn yet, onto the membrane, where it bounces back to its spot.
    private func throwIn(_ kind: OrganelleKind, velocity: SIMD3<Float>, isNext: Bool) {
        guard let model, let entity = organelles[kind], let next = model.nextSpec else { return }
        let token = epoch
        flying.insert(kind)
        setInteractive(entity, false, hover: false)
        let from = entity.position(relativeTo: nil)
        let slot = OrganelleCatalog.spec(for: kind).slot * unit
        // Recomputed every frame, since the cell may still be turning.
        let landing = { [self] () -> SIMD3<Float> in
            if isNext {
                return cellRoot.convert(position: slot, to: nil)
            }
            let center = cellRoot.position(relativeTo: nil)
            let outward = from - center
            let direction = simd_length(outward) > 0.001 ? simd_normalize(outward) : SIMD3<Float>(0, 0, 1)
            return center + direction * cellRadius * model.cellScale
        }
        let distance = simd_distance(from, landing())
        let speed = simd_length(velocity)
        let bend = from + velocity / speed * distance * 0.4 + SIMD3<Float>(0, 0.1, 0)
        let duration = min(max(distance / max(speed, 1.5), 0.35), 0.9)
        Task {
            let frames = max(Int(duration * 60), 1)
            for frame in 1...frames {
                guard token == epoch else {
                    flying.remove(kind)
                    return
                }
                let t = Float(frame) / Float(frames)
                let position = (1 - t) * (1 - t) * from + 2 * (1 - t) * t * bend + t * t * landing()
                entity.setPosition(position, relativeTo: nil)
                try? await Task.sleep(for: .milliseconds(16))
            }
            flying.remove(kind)
            guard token == epoch else { return }
            if isNext {
                await place(kind)
            } else {
                refuse(kind, next: next)
                try? await Task.sleep(for: .milliseconds(750))
                guard token == epoch else { return }
                setInteractive(entity, true, hover: true)
            }
        }
    }

    func magnifyChanged(_ value: EntityTargetValue<MagnifyGesture.Value>) {
        guard let model, model.phase == .assembled else { return }
        let start = magnifyStart ?? model.cellScale
        magnifyStart = start
        turnStart = nil
        spinVelocity = .zero
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
            // Grabbing a cell that is still coasting catches it.
            spinVelocity = .zero
            turnVelocity = .zero
            turnSample = nil
            turnStart = (cellRoot.orientation, pointer, Self.turnPace(grabbing: pointer, from: immersiveCenter))
        }
        guard let start = turnStart else { return }
        let delta = pointer - start.pointer
        // From inside the cell you grab the far wall, so the directions flip to keep it following your hand.
        let sign: Float = model.immersion > 0.5 ? -1 : 1
        let angles = SIMD2<Float>(sign * delta.x, -sign * delta.y) * Self.turnPerMeter * start.pace
        if let last = turnSample {
            let seconds = Float(value.time.timeIntervalSince(last.time))
            if seconds > 0.001 {
                // Smoothed, so one jittery hand sample does not decide the flick.
                turnVelocity += ((angles - last.angles) / seconds - turnVelocity) * 0.5
            }
        }
        turnSample = (angles, value.time)
        cellRoot.orientation = simd_normalize(Self.turn(by: angles) * start.orientation)
    }

    /// Sends the cell on as if the hand had kept going. SwiftUI predicts where a flick would have ended; coasting
    /// with friction covers exactly that leftover turn when it starts at leftover × friction. A hand that came to
    /// rest gets no prediction, so the cell stays put.
    private func releaseTurn(_ value: EntityTargetValue<DragGesture.Value>) {
        defer { turnSample = nil }
        let sign: Float = (model?.immersion ?? 0) > 0.5 ? -1 : 1
        let now = value.convert(value.location3D, from: .local, to: .scene)
        let predicted = value.convert(value.predictedEndLocation3D, from: .local, to: .scene)
        let leftover = predicted - now
        let pace = turnStart?.pace ?? 1
        var velocity = SIMD2<Float>(sign * leftover.x, -sign * leftover.y)
            * Self.turnPerMeter * pace * Self.spinFriction
        // Fall back on the speed measured during the drag when the system offers no prediction, as long as the
        // hand was still moving just before letting go.
        if simd_length(velocity) < 0.05, let last = turnSample, Date().timeIntervalSince(last.time) < 0.25 {
            velocity = turnVelocity
        }
        let speed = simd_length(velocity)
        spinVelocity = speed > Self.maxSpin ? velocity / speed * Self.maxSpin : velocity
        print("[Spin] predicted \(leftover), measured \(turnVelocity), coasting at \(spinVelocity)")
    }

    private func coast(by seconds: Float) {
        guard turnStart == nil, spinVelocity != .zero else { return }
        cellRoot.orientation = simd_normalize(Self.turn(by: spinVelocity * seconds) * cellRoot.orientation)
        spinVelocity *= exp(-Self.spinFriction * seconds)
        if simd_length(spinVelocity) < 0.02 {
            spinVelocity = .zero
        }
    }

    /// visionOS stretches an indirect drag with the distance to what was grabbed, so far-off things keep up with
    /// the hand. Turning is undone by that distance, so the same hand movement turns a huge cell as much as the
    /// normal one 2 m away.
    private static func turnPace(grabbing point: SIMD3<Float>, from viewer: SIMD3<Float>) -> Float {
        min(1, 2 / max(simd_distance(point, viewer), 0.1))
    }

    /// Sideways spins the cell around the vertical, up and down tips it towards or away from the viewer.
    private static func turn(by angles: SIMD2<Float>) -> simd_quatf {
        simd_quatf(angle: angles.x, axis: SIMD3<Float>(0, 1, 0))
            * simd_quatf(angle: angles.y, axis: SIMD3<Float>(1, 0, 0))
    }

    func reset() {
        rewind(to: 0)
    }

    /// Steps back to a completed step: that organelle and every later one leave the cell again.
    func stepBack(to index: Int) {
        guard let model, model.phase != .intro, OrganelleCatalog.order.indices.contains(index),
            model.placedKinds.contains(OrganelleCatalog.order[index].kind)
        else { return }
        rewind(to: index)
    }

    /// Undoes every step from `index` on: stops the protein, shrinks the cell home if it was grown, and scatters
    /// the undone organelles back to their spots. `rewind(to: 0)` starts over.
    private func rewind(to index: Int) {
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
        holds.removeAll()
        flying.removeAll()
        grips.removeAll()
        magnifyStart = nil
        turnStart = nil
        spinVelocity = .zero
        let order = OrganelleCatalog.order
        let undone = order[index...].map(\.kind)
        model.placedKinds = Set(order[..<index].map(\.kind))
        model.openInfo = []
        model.draggingKinds = []
        model.hint = nil
        model.phase = .scatter
        sky?.components.remove(InputTargetComponent.self)
        setInteractive(membraneHolder, false, hover: false)
        for kind in undone {
            if let entity = organelles[kind] {
                setInteractive(entity, false, hover: false)
            }
        }
        Task {
            if model.cellScale != 1 || cellRoot.orientation != simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
            {
                await animateCellHome(duration: 0.9, token: token)
            }
            guard token == epoch else { return }
            scatter(undone, duration: 1.4)
            try? await Task.sleep(for: .milliseconds(1500))
            guard token == epoch else { return }
            setInteractive(membraneHolder, true, hover: false)
            for kind in undone {
                if let entity = organelles[kind] {
                    setInteractive(entity, true, hover: true)
                }
            }
        }
    }

    private func beginScatter() {
        guard let model else { return }
        epoch += 1
        let token = epoch
        model.phase = .scatter
        play(enterSound, from: cellRoot)
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
        scatter(OrganelleCatalog.order.map(\.kind), duration: duration)
    }

    private func scatter(_ kinds: [OrganelleKind], duration: TimeInterval) {
        for kind in kinds {
            let spec = OrganelleCatalog.spec(for: kind)
            guard let entity = organelles[kind] else { continue }
            straighten(kind, duration: duration)
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
        straighten(kind, duration: 0.6)
        entity.setParent(cellRoot, preservingWorldTransform: true)
        entity.move(
            to: Transform(scale: .one, translation: spec.slot * unit),
            relativeTo: cellRoot,
            duration: 0.6,
            timingFunction: .easeOut
        )
        play(placedSound, from: entity)
        try? await Task.sleep(for: .milliseconds(650))
        guard token == epoch else { return }
        // One protein travels through the whole cell, so each step waits for the previous one to finish.
        let previous = proteinJob
        let job = Task {
            await previous?.value
            guard token == epoch else { return }
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
        // Organelles near the membrane would put this outside the cell, so it is kept inside.
        let surface = insideCell(start + outward * (max(size.x, max(size.y, size.z)) * 0.5 + 0.05))
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
                destination = insideCell(center + direction * min(reach * 0.85, simd_length(toSource)))
            } else {
                destination = center
            }
        case .outsideCell:
            destination = outward * cellRadius * 1.6
        case .energizeProtein:
            await spreadEnergy(from: start, color: spec.proteinColor, token: token)
            return
        }
        // Every point stays inside, so the straight hops between them do too; only the trip out of the cell leaves.
        let leaves: Bool
        if case .outsideCell = spec.destination { leaves = true } else { leaves = false }
        let middle = leaves
            ? (surface + destination) / 2 + SIMD3<Float>(0, 0.08, 0)
            : insideCell((surface + destination) / 2 + SIMD3<Float>(0, 0.08, 0))

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
            await floatToViewer(ball, token: token)
            await fadeOutProtein(ball, token: token)
        }
    }

    /// Pulls a point in cell space back inside the membrane, with a margin so the protein's halo stays in too.
    private func insideCell(_ point: SIMD3<Float>) -> SIMD3<Float> {
        let limit = cellRadius * 0.8
        let distance = simd_length(point)
        return distance > limit ? point / distance * limit : point
    }

    /// Once out of the cell, the protein drifts over to the viewer and stops just in front of their face.
    private func floatToViewer(_ ball: ModelEntity, token: Int) async {
        guard token == epoch else { return }
        let viewer = viewerPosition() ?? immersiveCenter
        // Out of the cell, so turning the cell no longer carries it along.
        ball.setParent(root, preservingWorldTransform: true)
        let from = ball.position(relativeTo: root)
        let away = from - viewer
        let distance = simd_length(away)
        guard distance > 0.5 else { return }
        var target = ball.transform
        target.translation = viewer + away / distance * 0.45 + SIMD3<Float>(0, -0.08, 0)
        let duration = 1.8 * Self.proteinPace
        ball.move(to: target, relativeTo: root, duration: duration, timingFunction: .easeInOut)
        try? await Task.sleep(for: .milliseconds(Int(duration * 1000)))
    }

    /// Once the protein has left the cell it fades away.
    private func fadeOutProtein(_ ball: ModelEntity, token: Int) async {
        let frames = Int(40 * Self.proteinPace)
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

        let frames = Int(120 * Self.proteinPace)
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
        for (target, step, timing) in steps {
            let duration = step * Self.proteinPace
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
        cellRoot.position = cellPosition(at: scale)
        layoutAroundCell()
        let immersion = Self.smoothstep(3.0, 6.0, scale)
        model.immersion = immersion
        SoundBoard.shared.setImmersion(immersion)
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

    /// Grows up and away from its base, so it never swallows the viewer or the panel below it, and its base
    /// lifts above eye level on the way.
    private func cellPosition(at scale: Float) -> SIMD3<Float> {
        let grown = max(scale - 1, 0) * cellRadius
        let lift = (immersiveCenter.y + overheadClearance - (cellHome.y - cellRadius))
            * Self.smoothstep(1, 3.5, scale)
        return cellHome + SIMD3<Float>(0, grown + lift, -growBack * grown)
    }

    /// A quick side-to-side wobble of the cell and the scattered organelles: that was the wrong one.
    private func shake() {
        shakeJob?.cancel()
        shakeJob = Task {
            let frames = 30
            for frame in 1...frames {
                guard !Task.isCancelled, let model else { return }
                let t = Float(frame) / Float(frames)
                let swing = 0.014 * sin(t * 2 * .pi * 4) * (1 - t)
                let rest = cellPosition(at: model.cellScale)
                cellRoot.position = rest + SIMD3<Float>(swing, 0, 0)
                scatterRoot.position = cellRoot.position
                try? await Task.sleep(for: .milliseconds(16))
            }
            guard let model else { return }
            cellRoot.position = cellPosition(at: model.cellScale)
            scatterRoot.position = cellRoot.position
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

    /// Plays `sound` as spatial audio coming from `entity`, so it moves with it.
    private func play(_ sound: AudioFileResource?, from entity: Entity) {
        guard let sound else { return }
        if !entity.components.has(SpatialAudioComponent.self) {
            entity.components.set(SpatialAudioComponent())
        }
        entity.playAudio(sound)
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

    /// A copy of the model as it sits in the Reality Composer Pro scene, so it keeps the materials applied there.
    /// Its place in the scene is dropped. Models that aren't in the scene are loaded from their own file.
    private func model(named name: String) async throws -> Entity {
        let primName = name.split(separator: "/").last.map(String.init) ?? name
        let sceneRoot = scene?.findEntity(named: "Root") ?? scene
        if let found = sceneRoot?.children.first(where: { $0.name == primName }) {
            let copy = found.clone(recursive: true)
            copy.transform = .identity
            return copy
        }
        return try await Entity(named: name, in: realityKitContentBundle)
    }

    private func loadCentered(named name: String) async -> (entity: Entity, extents: SIMD3<Float>)?
    {
        do {
            let loaded = try await model(named: name)
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
                from: image, options: .init(semantic: .color, mipmapsMode: .allocateAndGenerateAll))
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
            let distance = Float.random(in: 150...220, using: &generator)
            let direction = SIMD3<Float>(cos(pitch) * sin(yaw), sin(pitch), -cos(pitch) * cos(yaw))
            let cell = template.clone(recursive: true)
            let holder = Entity()
            holder.position = direction * distance
            holder.scale = SIMD3<Float>(repeating: .random(in: 15...25, using: &generator))
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
    /// How many pixels each point of the sky picture gets. It is drawn as 2048 × 1024 points, so 4 gives an
    /// 8192 × 4096 texture; lower it if loading takes too long or memory runs short.
    private static let skyDetail: CGFloat = 4

    private static func bodyImage() -> CGImage? {
        let size = CGSize(width: 2048, height: 1024)
        let format = UIGraphicsImageRendererFormat()
        format.scale = skyDetail
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
            // The image wraps around the sphere, so anything crossing the left or right edge is drawn again on the
            // other side; otherwise it is cut off there and leaves a visible seam.
            func wrapped(_ x: CGFloat, reach: CGFloat, draw: (CGFloat) -> Void) {
                draw(x)
                if x - reach < 0 { draw(x + size.width) }
                if x + reach > size.width { draw(x - size.width) }
            }
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
                    wrapped(center.x, reach: radius) { x in
                        let spot = CGPoint(x: x, y: center.y)
                        cg.drawRadialGradient(
                            gradient, startCenter: spot, startRadius: 0, endCenter: spot, endRadius: radius,
                            options: [])
                    }
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
                let angle = CGFloat.random(in: 0...(.pi), using: &generator)
                guard let gradient = CGGradient(colorsSpace: space, colors: disc, locations: [0, 0.65, 1])
                else { continue }
                wrapped(center.x, reach: radius) { x in
                    cg.saveGState()
                    cg.translateBy(x: x, y: center.y)
                    cg.rotate(by: angle)
                    cg.scaleBy(x: 1, y: squash)
                    cg.drawRadialGradient(
                        gradient, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: radius,
                        options: [])
                    cg.restoreGState()
                }
            }
        }
        return image.cgImage
    }

    private static func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }
}
