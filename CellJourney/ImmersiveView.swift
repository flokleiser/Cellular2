import RealityKit
import SwiftUI

struct ImmersiveView: View {
    @Binding var immersionStyle: any ImmersionStyle
    @Environment(AppModel.self) private var model
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.openWindow) private var openWindow
    @State private var controller = CellSceneController()

    var body: some View {
        RealityView { content, _ in
            model.resetProgress()
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
        } attachments: {
            Attachment(id: "intro") {
                IntroCard()
            }
            Attachment(id: "hud") {
                HUDView(
                    model: model,
                    onReset: { controller.reset() },
                    onExit: { leave() }
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
