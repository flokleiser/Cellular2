import ARKit
import RealityKit
import SwiftUI
import UIKit

/// Finds the printed picture the journey starts from and lays an invisible tap target over it.
/// Touching the paper with a fingertip touches the target, so the tap lands like any other entity tap.
/// The pictures it looks for are the AR reference images in the `Paper` group of Assets.xcassets.
@MainActor
final class PaperTracker {
    static let groupName = "Paper"

    /// Sits on the picture, flat on the paper. Named so `CellSceneController.handleTap` recognises it.
    let target = Entity()

    private let session = ARKitSession()
    private var glow: ModelEntity?

    init() {
        target.name = "paper"
        target.isEnabled = false
    }

    /// Runs until the immersive space closes. Falls back to "tap the cell to begin" whenever the picture
    /// cannot be looked for: in the simulator, without permission, or with no reference images in the asset catalog.
    func run(model: AppModel) async {
        guard AppModel.startFromPaper else { return }
        let images = ReferenceImage.loadReferenceImages(inGroupNamed: Self.groupName)
        print("[Paper] start: waiting \(model.waitingForPaper), \(images.count) reference images")
        guard ImageTrackingProvider.isSupported, !images.isEmpty else {
            print("[Paper] image tracking unsupported or no images, starting with the cell instead")
            model.waitingForPaper = false
            return
        }
        let authorization = await session.requestAuthorization(for: [.worldSensing])
        guard authorization[.worldSensing] == .allowed else {
            print("[Paper] world sensing not allowed")
            model.waitingForPaper = false
            return
        }
        let provider = ImageTrackingProvider(referenceImages: images)
        do {
            try await session.run([provider])
        } catch {
            print("[Paper] image tracking unavailable: \(error)")
            model.waitingForPaper = false
            return
        }
        print("[Paper] looking for the picture")
        // Ends when `stop()` stops the session.
        for await update in provider.anchorUpdates {
            let anchor = update.anchor
            print("[Paper] \(update.event) tracked \(anchor.isTracked), waiting \(model.waitingForPaper)")
            // The paper lies still, so a picture that drops out of tracking keeps its last spot.
            guard model.waitingForPaper, anchor.isTracked else { continue }
            place(on: anchor)
            model.paperFound = true
        }
        print("[Paper] stopped")
    }

    /// Stopped explicitly: a session still running from the last visit seems to starve the next one of image updates.
    func stop() {
        session.stop()
    }

    func applyState(model: AppModel) {
        target.isEnabled = model.waitingForPaper && model.paperFound
    }

    /// ARKit lays the picture in the anchor's x-z plane, with y pointing up out of the paper.
    private func place(on anchor: ImageAnchor) {
        target.transform = Transform(matrix: anchor.originFromAnchorTransform)
        guard glow == nil else { return }
        let printed = anchor.referenceImage.physicalSize
        let scale = Float(anchor.estimatedScaleFactor)
        let width = Float(printed.width) * scale
        let depth = Float(printed.height) * scale
        target.components.set(CollisionComponent(shapes: [.generateBox(width: width, height: 0.02, depth: depth)]))
        target.components.set(InputTargetComponent())
        target.components.set(HoverEffectComponent())

        // A faint sheen over the picture shows it has been found, and lights up when looked at.
        var material = UnlitMaterial(color: .white)
        material.blending = .transparent(opacity: 0.08)
        let sheen = ModelEntity(
            mesh: .generatePlane(width: width, depth: depth, cornerRadius: 0.01), materials: [material])
        sheen.position.y = 0.002
        target.addChild(sheen)
        glow = sheen
    }
}
