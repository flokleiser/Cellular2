import UIKit
import simd

enum OrganelleKind: String, CaseIterable, Identifiable {
    case nucleus
    case ribosomes
    case endoplasmicReticulum
    case golgi
    case mitochondrion

    var id: String { rawValue }
}

enum ProteinDestination {
    case organelle(OrganelleKind)
    case outsideCell
    case energizeProtein
}

struct OrganelleSpec {
    let kind: OrganelleKind
    let assetName: String
    let title: String
    let shortName: String
    let role: String
    let caption: String
    let slot: SIMD3<Float>
    let fit: Float
    let scatterAngle: Float
    let scatterTilt: simd_quatf
    let proteinColor: UIColor
    let destination: ProteinDestination
    var orientation = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
}

enum OrganelleCatalog {
    static let order: [OrganelleSpec] = [
        OrganelleSpec(
            kind: .nucleus,
            assetName: "Nucleus",
            title: "Nucleus",
            shortName: "nucleus",
            role: "The control centre of the cell. DNA is stored here, and the gene for our protein is copied into a messenger RNA (mRNA) strand that leaves through pores in the nuclear envelope.",
            caption: "The nucleus copied the gene into mRNA and sent the message out to the ribosomes.",
            slot: SIMD3<Float>(0.0, 1.3, 0.0),
            fit: 1.0,
            scatterAngle: 162,
            scatterTilt: simd_quatf(angle: 0.4, axis: SIMD3<Float>(0, 1, 0)),
            proteinColor: UIColor(red: 0.75, green: 0.45, blue: 1.0, alpha: 1),
            destination: .organelle(.ribosomes)
        ),
        OrganelleSpec(
            kind: .mitochondrion,
            assetName: "Mitochondrion_open_3",
            title: "Mitochondrion",
            shortName: "mitochondrion",
            role: "The powerhouse of the cell. It makes ATP, the energy that fuels every step of building, folding and moving proteins.",
            caption: "The mitochondrion charged the protein's journey with ATP, the energy every next step runs on.",
            slot: SIMD3<Float>(2.0, 0.3, 0.9),
            fit: 1.0,
            scatterAngle: 18,
            scatterTilt: simd_quatf(angle: 0.9, axis: SIMD3<Float>(0, 1, 0)),
            proteinColor: UIColor(red: 1.0, green: 0.85, blue: 0.2, alpha: 1),
            destination: .energizeProtein,
            orientation: simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 1, 0))
        ),
        OrganelleSpec(
            kind: .ribosomes,
            assetName: "Ribosomes",
            title: "Ribosomes",
            shortName: "ribosomes",
            role: "Tiny protein factories. They read the mRNA message and link amino acids together, one by one, into a brand new protein chain.",
            caption: "The ribosomes read the mRNA and built a chain of amino acids.",
            slot: SIMD3<Float>(1.2, -0.4, 1.2),
            fit: 2.0,
            scatterAngle: 90,
            scatterTilt: simd_quatf(angle: -0.6, axis: SIMD3<Float>(1, 0, 0)),
            proteinColor: UIColor(red: 1.0, green: 0.55, blue: 0.3, alpha: 1),
            destination: .organelle(.endoplasmicReticulum)
        ),
        OrganelleSpec(
            kind: .endoplasmicReticulum,
            assetName: "ER",
            title: "Endoplasmic Reticulum",
            shortName: "endoplasmic reticulum",
            role: "A folded network of membranes. New proteins slip inside, fold into their 3D shape and are quality-checked before they move on.",
            caption: "The endoplasmic reticulum folded the new protein into shape.",
            slot: SIMD3<Float>(0.0, 1.3, 0.0),
            fit: 0.7,
            scatterAngle: 306,
            scatterTilt: simd_quatf(angle: -0.5, axis: SIMD3<Float>(0, 1, 0)),
            proteinColor: UIColor(red: 0.35, green: 0.85, blue: 1.0, alpha: 1),
            destination: .organelle(.golgi)
        ),
        OrganelleSpec(
            kind: .golgi,
            assetName: "Golgi",
            title: "Golgi Apparatus",
            shortName: "Golgi apparatus",
            role: "The cell's post office. It adds the finishing touches to proteins, sorts them and packs them into vesicles addressed to their destination.",
            caption: "The Golgi apparatus packaged the protein and shipped it out of the cell.",
            slot: SIMD3<Float>(-1.7, 0.1, 1.0),
            fit: 0.85,
            scatterAngle: 234,
            scatterTilt: simd_quatf(angle: 0.7, axis: SIMD3<Float>(0, 0, 1)),
            proteinColor: UIColor(red: 0.45, green: 1.0, blue: 0.55, alpha: 1),
            destination: .outsideCell
        )
    ]

    static func spec(for kind: OrganelleKind) -> OrganelleSpec {
        order.first { $0.kind == kind }!
    }
}
