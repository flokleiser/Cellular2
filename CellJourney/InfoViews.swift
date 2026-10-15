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

/// Sits over a scattered organelle. Apps never learn where the eyes are, so the panel is revealed by a system hover
/// effect: looking at the organelle (or the panel itself) opens it, the info button pins it open.
/// It covers the organelle, so dragging the organelle happens here too.
struct LookTarget: View {
    let spec: OrganelleSpec
    let model: AppModel
    /// Side of the target in meters.
    let size: Float
    let onDrag: (SIMD3<Float>) -> Void
    let onDragEnded: () -> Void

    @Environment(\.physicalMetrics) private var metrics
    /// Room above the target for the panel, mirrored below so the target stays centred on the organelle.
    private let reserve: CGFloat = 420
    private let gap: CGFloat = 24

    var body: some View {
        let side = metrics.convert(CGFloat(size), from: .meters)
        let pinned = model.openInfo.contains(spec.kind)
        VStack(spacing: gap) {
            InfoPanel(spec: spec)
                .hoverEffect { effect, isActive, _ in
                    effect.animation(.easeOut(duration: 0.25).delay(isActive ? 0.25 : 0.6)) {
                        $0.opacity(isActive || pinned ? 1 : 0)
                            .scaleEffect(isActive || pinned ? 1 : 0.92, anchor: .bottom)
                    }
                }
                .frame(height: reserve, alignment: .bottom)
            // Invisible: only here so gaze and drags land on something over the organelle.
            Color.clear
                .frame(width: side, height: side)
                .contentShape(.hoverEffect, .rect(cornerRadius: side / 4))
                .contentShape(.rect(cornerRadius: side / 4))
                .gesture(drag)
            Color.clear
                .frame(height: reserve)
        }
        .hoverEffectGroup()
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .immersiveSpace)
            .onChanged { value in
                let moved = value.translation3D
                // SwiftUI's y axis points down, RealityKit's up.
                onDrag(SIMD3<Float>(
                    Float(metrics.convert(moved.x, to: .meters)),
                    -Float(metrics.convert(moved.y, to: .meters)),
                    Float(metrics.convert(moved.z, to: .meters))
                ))
            }
            .onEnded { _ in onDragEnded() }
    }
}

/// One panel for the whole journey, below the cell: the intro card morphs into the progress banner.
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
                let lead = model.placedKinds.isEmpty ? "First" : "Next"
                return "\(lead), drag the \(next.shortName) into the cell"
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
