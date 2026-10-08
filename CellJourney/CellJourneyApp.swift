import SwiftUI

@main
struct CellJourneyApp: App {
    @State private var model = AppModel()
    @State private var immersionStyle: any ImmersionStyle = .mixed

    var body: some Scene {
        WindowGroup(id: "launcher") {
            LauncherView()
                .environment(model)
        }
        .defaultSize(width: 560, height: 440)

        ImmersiveSpace(id: "cell") {
            ImmersiveView(immersionStyle: $immersionStyle)
                .environment(model)
        }
        .immersionStyle(selection: $immersionStyle, in: .mixed, .full)
    }
}
