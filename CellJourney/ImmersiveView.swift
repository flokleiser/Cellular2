import RealityKit
import SwiftUI

struct ImmersiveView: View {
    @Binding var immersionStyle: any ImmersionStyle
    @Environment(AppModel.self) private var model
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.openWindow) private var openWindow
    @State private var controller = CellSceneController()
    @State private var handMenu = HandMenuController()
    @State private var paper = PaperTracker()

    var body: some View {
        RealityView { content, _ in
            model.resetProgress()
            content.add(handMenu.buttonAnchor)
            content.add(handMenu.panelAnchor)
            content.add(paper.target)
            controller.viewerPosition = { [handMenu] in
                handMenu.headTransform().map { SIMD3<Float>($0.columns.3.x, $0.columns.3.y, $0.columns.3.z) }
            }
            await controller.load(into: content, model: model)
        } update: { _, attachments in
            if model.sceneReady {
                if let panel = attachments.entity(for: "panel") {
                    controller.mountPanel(panel)
                }
                for kind in OrganelleKind.allCases {
                    if let card = attachments.entity(for: "card-\(kind.rawValue)") {
                        controller.mountInfoCard(card, kind: kind)
                    }
                    if let panel = attachments.entity(for: "panel-\(kind.rawValue)") {
                        controller.mountInfoPanel(panel, kind: kind)
                    }
                }
                controller.applyState()
            }
            if let palm = attachments.entity(for: "palm") {
                handMenu.mountButton(palm)
            }
            if let debug = attachments.entity(for: "debug") {
                handMenu.mountPanel(debug)
            }
            handMenu.applyState(model: model)
            paper.applyState(model: model)
        } attachments: {
            Attachment(id: "panel") {
                JourneyPanel(
                    model: model,
                    onReset: { controller.reset() },
                    onStep: { controller.stepBack(to: $0) },
                    onExit: { leave() }
                )
            }
            Attachment(id: "palm") {
                PalmButton(isOpen: model.showDebug) {
                    handMenu.togglePanel(model: model)
                }
            }
            Attachment(id: "debug") {
                DebugPanel(
                    model: model,
                    onScale: { controller.setCellScale($0) },
                    onClose: { model.showDebug = false }
                )
            }
            ForEach(OrganelleKind.allCases) { kind in
                Attachment(id: "card-\(kind.rawValue)") {
                    InfoCard(
                        spec: OrganelleCatalog.spec(for: kind),
                        model: model,
                        opensLeft: CellSceneController.opensLeft(kind)
                    )
                }
            }
            ForEach(OrganelleKind.allCases) { kind in
                Attachment(id: "panel-\(kind.rawValue)") {
                    LookTarget(
                        spec: OrganelleCatalog.spec(for: kind),
                        size: controller.lookTargetSize(for: kind),
                        onDrag: { controller.dragOrganelle(kind, by: $0, hand: $1, grip: $2) },
                        onDragEnded: { controller.dragOrganelleEnded(kind) }
                    )
                }
            }
        }
        .gesture(
            SpatialTapGesture()
                .targetedToAnyEntity()
                .onEnded { value in
                    controller.handleTap(on: value.entity)
                }
        )
        .gesture(
            DragGesture()
                .targetedToAnyEntity()
                .onChanged { value in
                    controller.dragChanged(value)
                }
                .onEnded { value in
                    controller.dragEnded(value)
                }
        )
        .gesture(
            MagnifyGesture()
                .targetedToAnyEntity()
                .onChanged { value in
                    controller.magnifyChanged(value)
                }
                .onEnded { _ in
                    controller.magnifyEnded()
                }
        )
        .task {
            await handMenu.run(model: model)
        }
        .task {
            await paper.run(model: model)
        }
        .onChange(of: model.waitingForPaper) { _, waiting in
            if !waiting {
                paper.stop()
            }
        }
        .onDisappear {
            // Ending the tasks does not stop the ARKit sessions, so they are stopped here.
            paper.stop()
            handMenu.stop()
            // Also when the system closed the space (Digital Crown), so reopening the app finds a window.
            openWindow(id: "launcher")
        }
        .onChange(of: model.wantsFullImmersion) { _, wantsFull in
            if wantsFull {
                immersionStyle = .full
            } else {
                immersionStyle = .mixed
            }
        }
    }

    /// The launcher comes back in `onDisappear`.
    private func leave() {
        Task {
            await dismissImmersiveSpace()
        }
    }
}
