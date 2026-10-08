import SwiftUI

struct IntroCard: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("Follow a protein through the cell")
                .font(.title.bold())
                .multilineTextAlignment(.center)
            Text("A protein is built, folded, packaged and shipped by a team of organelles. Take the cell apart, then put it back together in the right order.")
                .font(.body)
                .multilineTextAlignment(.center)
            Label("Tap the cell to begin", systemImage: "hand.tap")
                .font(.headline)
                .foregroundStyle(.tint)
        }
        .padding(28)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .glassBackgroundEffect()
    }
}

struct InfoButton: View {
    let kind: OrganelleKind
    let model: AppModel

    var body: some View {
        let isOpen = model.openInfo.contains(kind)
        Button {
            model.toggleInfo(kind)
        } label: {
            Image(systemName: isOpen ? "xmark" : "info")
                .font(.title2.weight(.semibold))
                .frame(width: 44, height: 44)
        }
        .buttonBorderShape(.circle)
    }
}

struct InfoPanel: View {
    let spec: OrganelleSpec

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(spec.title)
                .font(.title2.bold())
            Text(spec.role)
                .font(.callout)
        }
        .padding(22)
        .frame(width: 380, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .glassBackgroundEffect()
    }
}

struct HUDView: View {
    let model: AppModel
    let onReset: () -> Void
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
            return "Pinch with both hands and pull apart to grow the cell. Make it big enough and you step inside."
        }
        return model.caption
    }

    var body: some View {
        VStack(spacing: 12) {
            Text(headline)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            if let detail {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 14) {
                ForEach(OrganelleCatalog.order, id: \.kind) { spec in
                    Image(systemName: model.placedKinds.contains(spec.kind) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(model.placedKinds.contains(spec.kind) ? Color.green : Color.secondary)
                }
                Spacer().frame(width: 8)
                Button(action: onReset) {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                }
                Button(action: onExit) {
                    Label("Exit", systemImage: "xmark.circle")
                }
            }
        }
        .padding(24)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .glassBackgroundEffect()
    }
}
