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
    var phase: Phase = .intro
    var placedKinds: Set<OrganelleKind> = []
    var openInfo: Set<OrganelleKind> = []
    var hint: String?
    var caption: String?
    var cellScale: Float = 1
    var immersion: Float = 0
    var wantsFullImmersion = false
    var sceneReady = false

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

    func resetProgress() {
        phase = .intro
        placedKinds = []
        openInfo = []
        hint = nil
        caption = nil
        cellScale = 1
        immersion = 0
        wantsFullImmersion = false
        sceneReady = false
    }
}
