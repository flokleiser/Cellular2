import SwiftUI

struct LauncherView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var isOpening = false

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "circle.hexagongrid.fill")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            Text("Cell Journey")
                .font(.app(.extraLargeTitle))
            Text("Watch how a protein is built, folded, packaged and shipped by the organelles of a cell.")
                .font(.app(.title3))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button {
                Task {
                    isOpening = true
                    model.prepareForEntry()
                    SoundBoard.shared.startJourney()
                    let result = await openImmersiveSpace(id: "cell")
                    if case .opened = result {
                        dismissWindow(id: "launcher")
                    } else {
                        SoundBoard.shared.stopJourney()
                    }
                    isOpening = false
                }
            } label: {
                Text("Enter the cell")
                    .font(.app(.title2))
                    .padding(.horizontal, 24)
                    .padding(.vertical, 6)
            }
            .disabled(isOpening)
        }
        .padding(40)
    }
}
