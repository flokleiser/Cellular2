import SwiftUI

/// The info button next to a scattered organelle, which opens into a card about it and closes back into the button.
/// The button keeps its spot while the card grows outward (away from the cell) and down; `mountInfoCard` places the
/// attachment so that its corner lands where the button belongs, which is why the sizes are in meters.
struct InfoCard: View {
    let spec: OrganelleSpec
    let model: AppModel
    let opensLeft: Bool

    /// Room the card can take up, in meters.
    static let size = SIMD2<Float>(0.7, 0.58)
    static let buttonSide: Float = 0.056
    /// Gap between the card's edge and the button.
    static let inset: Float = 0.02

    @Environment(\.physicalMetrics) private var metrics

    var body: some View {
        let isOpen = model.openInfo.contains(spec.kind)
        let isDragged = model.draggingKinds.contains(spec.kind)
        let inset = points(Self.inset)
        VStack(alignment: opensLeft ? .trailing : .leading, spacing: 14) {
            HStack(spacing: 16) {
                if opensLeft {
                    title(isOpen)
                    button(isOpen)
                } else {
                    button(isOpen)
                    title(isOpen)
                }
            }
            if isOpen {
                Text(spec.role)
                    .font(.app(.title))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }
        }
        .padding(inset)
        .frame(width: isOpen ? points(Self.size.x) : nil, alignment: opensLeft ? .trailing : .leading)
        .glassBackgroundEffect(
            in: RoundedRectangle(cornerRadius: 30, style: .continuous), displayMode: isOpen ? .always : .never)
        .frame(
            width: points(Self.size.x), height: points(Self.size.y),
            alignment: opensLeft ? .topTrailing : .topLeading)
        .opacity(isDragged ? 0 : 1)
        .animation(.spring(duration: 0.4), value: isOpen)
        .animation(.easeOut(duration: 0.2), value: isDragged)
    }

    private func button(_ isOpen: Bool) -> some View {
        Button {
            model.toggleInfo(spec.kind)
        } label: {
            Image(systemName: isOpen ? "xmark" : "info")
                .font(.largeTitle.weight(.semibold))
                .frame(width: points(Self.buttonSide), height: points(Self.buttonSide))
        }
        .buttonBorderShape(.circle)
    }

    @ViewBuilder
    private func title(_ isOpen: Bool) -> some View {
        if isOpen {
            Text("\(OrganelleCatalog.number(for: spec.kind))  \(spec.title)")
                .font(.app(.extraLargeTitle2).bold())
                .lineLimit(2)
                .transition(.opacity)
        }
    }

    private func points(_ meters: Float) -> CGFloat {
        metrics.convert(CGFloat(meters), from: .meters)
    }
}

/// Sits over a scattered organelle. Apps never learn where the eyes are, so its label is revealed by a system hover
/// effect: looking at the organelle shows its number and name below it.
/// It covers the organelle, so dragging the organelle happens here too.
struct LookTarget: View {
    let spec: OrganelleSpec
    /// Side of the target in meters.
    let size: Float
    /// Translation in meters, and the pinching hand's position (in meters, world space) and rotation when the
    /// system reports them.
    let onDrag: (SIMD3<Float>, SIMD3<Float>?, simd_quatf?) -> Void
    let onDragEnded: () -> Void

    @Environment(\.physicalMetrics) private var metrics
    /// Room below the target for the label, mirrored above so the target stays centred on the organelle.
    private let labelRoom: CGFloat = 80
    private let gap: CGFloat = 16

    var body: some View {
        let side = metrics.convert(CGFloat(size), from: .meters)
        VStack(spacing: gap) {
            Color.clear
                .frame(height: labelRoom)
            // Invisible: only here so gaze and drags land on something over the organelle.
            Color.clear
                .frame(width: side, height: side)
                .contentShape(.hoverEffect, .rect(cornerRadius: side / 4))
                .contentShape(.rect(cornerRadius: side / 4))
                .gesture(drag)
            Text("\(OrganelleCatalog.number(for: spec.kind))  \(spec.title)")
                .font(.app(.title).bold())
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 26)
                .padding(.vertical, 12)
                .glassBackgroundEffect(in: Capsule())
                .hoverEffect { effect, isActive, _ in
                    effect.animation(.easeOut(duration: 0.2).delay(isActive ? 0.15 : 0.3)) {
                        $0.opacity(isActive ? 1 : 0)
                            .scaleEffect(isActive ? 1 : 0.9, anchor: .top)
                    }
                }
                .frame(height: labelRoom, alignment: .top)
        }
        .hoverEffectGroup()
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .immersiveSpace)
            .onChanged { value in
                onDrag(
                    meters(value.translation3D.x, value.translation3D.y, value.translation3D.z),
                    value.inputDevicePose3D.map { meters($0.position.x, $0.position.y, $0.position.z) },
                    value.inputDevicePose3D.map { CellSceneController.realityRotation($0.rotation) }
                )
            }
            .onEnded { _ in onDragEnded() }
    }

    /// SwiftUI's y axis points down, RealityKit's up.
    private func meters(_ x: Double, _ y: Double, _ z: Double) -> SIMD3<Float> {
        SIMD3<Float>(
            Float(metrics.convert(x, to: .meters)),
            -Float(metrics.convert(y, to: .meters)),
            Float(metrics.convert(z, to: .meters)))
    }
}

/// The panel below the cell. The intro card morphs into two stacked panels: what to do on top, the numbered steps
/// and controls below. The steps panel grows downward to describe the organelle the current step is about.
struct JourneyPanel: View {
    let model: AppModel
    let onReset: () -> Void
    let onStep: (Int) -> Void
    let onExit: () -> Void

    /// Reset and Exit share one width so they read as a pair.
    private let controlWidth: CGFloat = 170

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
        return nil
    }

    /// The organelle of the step in progress, described in the steps panel.
    private var described: OrganelleSpec? {
        model.phase == .scatter ? model.nextSpec : nil
    }

    private var startLabel: String {
        if !model.waitingForPaper {
            return "Tap the cell to begin"
        }
        return model.paperFound ? "Tap the picture to begin" : "Open the book to the picture of the cell"
    }

    private var isIntro: Bool {
        model.phase == .intro
    }

    var body: some View {
        VStack(spacing: 16) {
            if isIntro {
                intro
                    .padding(36)
                    .frame(width: 700)
                    .glassBackgroundEffect()
                    .transition(.blurReplace)
            } else {
                instructions
                    .padding(40)
                    .frame(width: 940)
                    .glassBackgroundEffect()
                    .transition(.blurReplace)
                controls
                    .padding(.horizontal, 30)
                    .padding(.vertical, 20)
                    .frame(width: 940)
                    .glassBackgroundEffect()
                    .transition(.blurReplace)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .animation(.spring(duration: 0.9), value: isIntro)
    }

    private var intro: some View {
        VStack(spacing: 16) {
            Text("Follow a protein through the cell")
                .font(.app(.extraLargeTitle2).bold())
                .multilineTextAlignment(.center)
            Text("A protein is built, folded, packaged and shipped by a team of organelles. Take the cell apart, then put it back together in the right order.")
                .font(.app(.title3))
                .multilineTextAlignment(.center)
            Label(startLabel, systemImage: model.waitingForPaper ? "book" : "hand.tap")
                .font(.app(.title2).bold())
                .foregroundStyle(.tint)
        }
    }

    private var instructions: some View {
        VStack(spacing: 18) {
            Text(headline)
                .font(.app(.extraLargeTitle2).bold())
                .multilineTextAlignment(.center)
            if let detail {
                Text(detail)
                    .font(.app(.title))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 20) {
            stepsRow
            if let spec = described {
                Text(spec.caption)
                    .font(.app(.largeTitle))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .id(spec.kind)
                    .transition(.blurReplace)
            }
        }
        .animation(.spring(duration: 0.6), value: described?.kind)
    }

    private var stepsRow: some View {
        HStack(spacing: 18) {
            ForEach(Array(OrganelleCatalog.order.enumerated()), id: \.element.kind) { index, spec in
                StepButton(
                    number: index + 1,
                    isDone: model.placedKinds.contains(spec.kind),
                    isNext: model.phase == .scatter && model.nextSpec?.kind == spec.kind
                ) {
                    onStep(index)
                }
            }
            Spacer().frame(width: 16)
            Button(action: onReset) {
                Label("Reset", systemImage: "arrow.counterclockwise")
                    .frame(width: controlWidth)
            }
            Button(action: onExit) {
                Label("Exit", systemImage: "xmark.circle")
                    .frame(width: controlWidth)
            }
        }
        .font(.app(.title2))
        .controlSize(.extraLarge)
    }
}

/// One numbered step in the control bar. Completed steps are green and can be tapped to go back to them;
/// the step that comes next is outlined.
struct StepButton: View {
    let number: Int
    let isDone: Bool
    let isNext: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("\(number)")
                .font(.app(.title).bold())
                .monospacedDigit()
                .foregroundStyle(isDone ? Color.white : isNext ? Color.primary : Color.secondary)
                .frame(width: 60, height: 60)
                .background(Circle().fill(isDone ? Color.green : Color.clear))
                .overlay(
                    Circle().strokeBorder(
                        isNext ? Color.accentColor : Color.secondary.opacity(isDone ? 0 : 0.5),
                        lineWidth: isNext ? 3 : 2))
                .contentShape(.hoverEffect, Circle())
                .hoverEffect(.highlight)
        }
        .buttonStyle(.plain)
        .disabled(!isDone)
        .help(isDone ? "Go back to step \(number)" : "")
    }
}
