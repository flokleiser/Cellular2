import SwiftUI

struct InfoButton: View {
    let kind: OrganelleKind
    let model: AppModel

    var body: some View {
        let isOpen = model.openInfo.contains(kind)
        Button {
            model.toggleInfo(kind)
        } label: {
            Image(systemName: isOpen ? "xmark" : "info")
                .font(.title.weight(.semibold))
                .frame(width: 60, height: 60)
        }
        .buttonBorderShape(.circle)
    }
}

struct InfoPanel: View {
    let spec: OrganelleSpec

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(spec.title)
                .font(.largeTitle.bold())
            Text(spec.role)
                .font(.title3)
        }
        .padding(30)
        .frame(width: 520, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .glassBackgroundEffect()
    }
}

/// One panel for the whole journey: the intro card above the cell morphs into the progress banner below it.
struct JourneyPanel: View {
    let model: AppModel
    let onReset: () -> Void
    let onDebug: () -> Void
    let onExit: () -> Void

    private var headline: String {
        if let hint = model.hint {
            return hint
        }
        switch model.phase {
        case .intro:
            return ""
        case .scatter:
            if let next = model.nextSpec {
                return "Next, drag the \(next.shortName) into the cell"
            }
            return "Almost there"
        case .assembled:
            return "The cell is whole again"
        }
    }

    private var detail: String? {
        if model.phase == .assembled {
            return "Drag with one hand to turn the cell. Pinch with both hands and pull apart to grow it. Make it big enough and you step inside."
        }
        return model.caption
    }

    private var isIntro: Bool {
        model.phase == .intro
    }

    var body: some View {
        VStack(spacing: 12) {
            if isIntro {
                intro
                    .transition(.blurReplace)
            } else {
                progress
                    .transition(.blurReplace)
            }
        }
        .padding(isIntro ? 36 : 44)
        .frame(width: isIntro ? 700 : 940)
        .fixedSize(horizontal: false, vertical: true)
        .glassBackgroundEffect()
        .animation(.spring(duration: 0.9), value: isIntro)
    }

    private var intro: some View {
        VStack(spacing: 16) {
            Text("Follow a protein through the cell")
                .font(.extraLargeTitle2.bold())
                .multilineTextAlignment(.center)
            Text("A protein is built, folded, packaged and shipped by a team of organelles. Take the cell apart, then put it back together in the right order.")
                .font(.title3)
                .multilineTextAlignment(.center)
            Label("Tap the cell to begin", systemImage: "hand.tap")
                .font(.title2.bold())
                .foregroundStyle(.tint)
        }
    }

    private var progress: some View {
        VStack(spacing: 22) {
            Text(headline)
                .font(.extraLargeTitle2.bold())
                .multilineTextAlignment(.center)
            if let detail {
                Text(detail)
                    .font(.title)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 22) {
                ForEach(OrganelleCatalog.order, id: \.kind) { spec in
                    Image(systemName: model.placedKinds.contains(spec.kind) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(model.placedKinds.contains(spec.kind) ? Color.green : Color.secondary)
                        .font(.largeTitle)
                }
                Spacer().frame(width: 12)
                Button(action: onReset) {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                }
                Button(action: onExit) {
                    Label("Exit", systemImage: "xmark.circle")
                }
                if !model.handMenuAvailable {
                    Button(action: onDebug) {
                        Image(systemName: "ladybug")
                    }
                    .buttonBorderShape(.circle)
                }
            }
            .font(.title2)
            .controlSize(.extraLarge)
        }
    }
}
