import SwiftUI

struct LauncherView: View {
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var isOpening = false

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "circle.hexagongrid.fill")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            Text("Cell Journey")
                .font(.extraLargeTitle)
            Text("Watch how a protein is built, folded, packaged and shipped by the organelles of a cell.")
                .font(.title3)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button {
                Task {
                    isOpening = true
                    let result = await openImmersiveSpace(id: "cell")
                    if case .opened = result {
                        dismissWindow(id: "launcher")
                    }
                    isOpening = false
                }
            } label: {
                Text("Enter the cell")
                    .font(.title2)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 6)
            }
            .disabled(isOpening)
        }
        .padding(40)
    }
}
