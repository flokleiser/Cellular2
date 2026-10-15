import SwiftUI
import Observation

enum Phase {
    case intro
    case scatter
    case assembled
}

@MainActor
@Observable
final class AppModel {
    /// true: the journey starts by tapping a printed picture, and the cell pops out of it (see PaperTracker).
    /// false: the cell is already there and you tap it to begin.
    static let startFromPaper = true

    var phase: Phase = .intro
    /// The cell stays hidden until the picture is tapped. Cleared right away when the picture can't be looked for.
    var waitingForPaper = AppModel.startFromPaper
    var paperFound = false
    var placedKinds: Set<OrganelleKind> = []
    var openInfo: Set<OrganelleKind> = []
    /// Organelles held by a hand right now; their info cards hide meanwhile.
    var draggingKinds: Set<OrganelleKind> = []
    var hint: String?
    var cellScale: Float = 1
    var immersion: Float = 0
    var wantsFullImmersion = false
    var sceneReady = false
    var showDebug = false
    var handMenuAvailable = false

    @ObservationIgnored private var hintTask: Task<Void, Never>?

    var nextSpec: OrganelleSpec? {
        OrganelleCatalog.order.first { !placedKinds.contains($0.kind) }
    }

    func toggleInfo(_ kind: OrganelleKind) {
        if openInfo.contains(kind) {
            openInfo.remove(kind)
        } else {
            openInfo.insert(kind)
        }
    }

    func showHint(_ text: String) {
        hint = text
        hintTask?.cancel()
        hintTask = Task {
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled {
                hint = nil
            }
        }
    }

    /// Called before the immersive space opens, so the paper search never sees the last visit's state.
    /// Not part of `resetProgress`, which runs alongside the search and could undo its fallback.
    func prepareForEntry() {
        waitingForPaper = Self.startFromPaper
        paperFound = false
    }

    func resetProgress() {
        phase = .intro
        placedKinds = []
        openInfo = []
        draggingKinds = []
        hint = nil
        cellScale = 1
        immersion = 0
        wantsFullImmersion = false
        sceneReady = false
        showDebug = false
    }
}
