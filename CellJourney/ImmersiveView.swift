import RealityKit
import SwiftUI

struct ImmersiveView: View {
    @Binding var immersionStyle: any ImmersionStyle
    @Environment(AppModel.self) private var model
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.openWindow) private var openWindow
    @State private var controller = CellSceneController()
    @State private var handMenu = HandMenuController()

    var body: some View {
        RealityView { content, _ in
            model.resetProgress()
            content.add(handMenu.buttonAnchor)
            content.add(handMenu.panelAnchor)
            await controller.load(into: content, model: model)
        } update: { _, attachments in
            if model.sceneReady {
                if let intro = attachments.entity(for: "intro") {
                    controller.mountIntro(intro)
                }
                if let hud = attachments.entity(for: "hud") {
                    controller.mountHUD(hud)
                }
                for kind in OrganelleKind.allCases {
                    if let button = attachments.entity(for: "button-\(kind.rawValue)") {
                        controller.mountInfoButton(button, kind: kind)
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
        } attachments: {
            Attachment(id: "intro") {
                IntroCard()
            }
            Attachment(id: "hud") {
                HUDView(
                    model: model,
                    onReset: { controller.reset() },
                    onDebug: { handMenu.togglePanel(model: model) },
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
                Attachment(id: "button-\(kind.rawValue)") {
                    InfoButton(kind: kind, model: model)
                }
            }
            ForEach(OrganelleKind.allCases) { kind in
                Attachment(id: "panel-\(kind.rawValue)") {
                    InfoPanel(spec: OrganelleCatalog.spec(for: kind))
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
        .onChange(of: model.wantsFullImmersion) { _, wantsFull in
            if wantsFull {
                immersionStyle = .full
            } else {
                immersionStyle = .mixed
            }
        }
    }

    private func leave() {
        openWindow(id: "launcher")
        Task {
            await dismissImmersiveSpace()
        }
    }
}
