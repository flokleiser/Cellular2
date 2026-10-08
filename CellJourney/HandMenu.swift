import ARKit
import QuartzCore
import RealityKit
import SwiftUI
import simd

/// A debug menu that works like Control Center: turn your left palm towards you,
/// a button appears above it, and tapping it opens the panel in front of you.
@MainActor
final class HandMenuController {
    let buttonAnchor = Entity()
    let panelAnchor = Entity()

    private let session = ARKitSession()
    private let hands = HandTrackingProvider()
    private let world = WorldTrackingProvider()
    private var palmFacing = false
    private var buttonEntity: Entity?
    private var panelEntity: Entity?

    init() {
        buttonAnchor.isEnabled = false
        panelAnchor.isEnabled = false
    }

    func mountButton(_ entity: Entity) {
        guard buttonEntity == nil else { return }
        buttonEntity = entity
        entity.components.set(BillboardComponent())
        buttonAnchor.addChild(entity)
    }

    func mountPanel(_ entity: Entity) {
        guard panelEntity == nil else { return }
        panelEntity = entity
        entity.components.set(BillboardComponent())
        panelAnchor.addChild(entity)
    }

    func togglePanel(model: AppModel) {
        model.showDebug.toggle()
        if model.showDebug {
            panelAnchor.position = spotInFrontOfHead()
        }
    }

    func applyState(model: AppModel) {
        panelAnchor.isEnabled = model.showDebug
    }

    /// Runs until the immersive space closes. Falls back to a HUD button when hand tracking is unavailable (e.g. simulator).
    func run(model: AppModel) async {
        guard HandTrackingProvider.isSupported else {
            if WorldTrackingProvider.isSupported {
                try? await session.run([world])
            }
            return
        }
        let authorization = await session.requestAuthorization(for: [.handTracking])
        guard authorization[.handTracking] == .allowed else { return }
        do {
            try await session.run([hands, world])
        } catch {
            print("Hand menu unavailable: \(error)")
            return
        }
        model.handMenuAvailable = true
        for await update in hands.anchorUpdates {
            guard update.anchor.chirality == .left else { continue }
            follow(update.anchor)
        }
    }

    private func follow(_ anchor: HandAnchor) {
        guard anchor.isTracked,
              let skeleton = anchor.handSkeleton,
              let head = headTransform() else {
            setPalmFacing(false)
            return
        }
        func point(_ name: HandSkeleton.JointName) -> SIMD3<Float> {
            let joint = anchor.originFromAnchorTransform * skeleton.joint(name).anchorFromJointTransform
            return SIMD3<Float>(joint.columns.3.x, joint.columns.3.y, joint.columns.3.z)
        }
        let wrist = point(.wrist)
        let index = point(.indexFingerKnuckle)
        let little = point(.littleFingerKnuckle)
        let palm = (wrist + index + little) / 3
        // On the left hand, little × index points out of the palm.
        let normal = simd_normalize(simd_cross(little - wrist, index - wrist))
        let eye = SIMD3<Float>(head.columns.3.x, head.columns.3.y, head.columns.3.z)
        let facing = simd_dot(normal, simd_normalize(eye - palm))
        // Hysteresis so the button does not flicker at the threshold.
        setPalmFacing(palmFacing ? facing > 0.45 : facing > 0.7)
        if palmFacing {
            buttonAnchor.position = palm + normal * 0.07
        }
    }

    private func setPalmFacing(_ facing: Bool) {
        palmFacing = facing
        buttonAnchor.isEnabled = facing
    }

    private func headTransform() -> simd_float4x4? {
        guard world.state == .running,
              let device = world.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()) else { return nil }
        return device.originFromAnchorTransform
    }

    private func spotInFrontOfHead() -> SIMD3<Float> {
        guard let head = headTransform() else { return SIMD3<Float>(0, 1.2, -0.7) }
        let eye = SIMD3<Float>(head.columns.3.x, head.columns.3.y, head.columns.3.z)
        var forward = -SIMD3<Float>(head.columns.2.x, 0, head.columns.2.z)
        forward = simd_length(forward) > 0.001 ? simd_normalize(forward) : SIMD3<Float>(0, 0, -1)
        return eye + forward * 0.65 + SIMD3<Float>(0, -0.15, 0)
    }
}

struct PalmButton: View {
    let isOpen: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Image(systemName: isOpen ? "xmark" : "slider.horizontal.3")
                .font(.title3.weight(.semibold))
                .frame(width: 44, height: 44)
        }
        .buttonBorderShape(.circle)
    }
}

struct DebugPanel: View {
    let model: AppModel
    let onScale: (Float) -> Void
    let onClose: () -> Void

    private var logScale: Binding<Double> {
        Binding(
            get: { Double(log2(model.cellScale)) },
            set: { onScale(exp2(Float($0))) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Debug", systemImage: "ladybug")
                    .font(.title3.bold())
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonBorderShape(.circle)
            }
            HStack {
                Text("Cell scale")
                Spacer()
                Text(String(format: "%.2f×", model.cellScale))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button {
                    onScale(model.cellScale / 1.25)
                } label: {
                    Image(systemName: "minus")
                }
                .buttonBorderShape(.circle)
                Slider(
                    value: logScale,
                    in: Double(log2(CellSceneController.minScale))...Double(log2(CellSceneController.maxScale))
                )
                Button {
                    onScale(model.cellScale * 1.25)
                } label: {
                    Image(systemName: "plus")
                }
                .buttonBorderShape(.circle)
            }
            Button("Reset to 1×") {
                onScale(1)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(24)
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
        .glassBackgroundEffect()
    }
}
