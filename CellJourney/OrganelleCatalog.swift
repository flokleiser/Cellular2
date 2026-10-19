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
    /// Room between the organelle's bounding box and its info button, in meters. Negative pulls the button inside
    /// the box, for models whose visible shape is much smaller than their bounds.
    var infoGap: Float = 0.08
}

enum OrganelleCatalog {
    static let order: [OrganelleSpec] = [
        OrganelleSpec(
            kind: .mitochondrion,
            assetName: "Mitochondrion_New",
            title: "Mitochondrion",
            shortName: "mitochondrion",
            role:
                "The cell’s main energy supplier. Mitochondria produce ATP (adenosine triphosphate, C₁₀H₁₆N₅O₁₃P₃), a molecule that stores usable energy. For example, ATP powers the molecular machinery that links amino acids together to build a protein.",
            caption:
                "The mitochondrion produces ATP, the energy that powers the protein’s journey through the cell.",
            slot: SIMD3<Float>(2.05, -1.35, 0.85),
            fit: 1.0,
            scatterAngle: 18,
            scatterTilt: simd_quatf(angle: 0.9, axis: SIMD3<Float>(0, 1, 0)),
            proteinColor: UIColor(red: 1.0, green: 0.85, blue: 0.2, alpha: 1),
            destination: .energizeProtein,
            orientation: simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 1, 0))
        ),
        OrganelleSpec(
            kind: .nucleus,
//            assetName: "Nucleus",
            assetName: "Nucleus_New_4",
            title: "Nucleus",
            shortName: "nucleus",
            role:
                "The nucleus stores the cell’s DNA, which contains instructions for making proteins. When a protein is needed, a specific gene is transcribed into messenger RNA (mRNA). This RNA copy carries the instructions out through a nuclear pore, where ribosomes can read them to assemble amino acids into a protein.",
            caption:
                "The nucleus copies the gene into mRNA and sent the message out to the ribosomes.",
            slot: SIMD3<Float>(0.0, 0.7, -0.3),
            fit: 1.0,
            scatterAngle: 162,
            scatterTilt: simd_quatf(angle: 0.4, axis: SIMD3<Float>(0, 1, 0)),
            proteinColor: UIColor(red: 0.75, green: 0.45, blue: 1.0, alpha: 1),
            destination: .organelle(.ribosomes)
        ),
        OrganelleSpec(
            kind: .ribosomes,
            assetName: "Ribosomes_New_2",
            //            assetName: "Ribosomes",
            title: "Ribosomes",
            shortName: "ribosomes",
            role:
                "Ribosomes are tiny protein factories found throughout the cytoplasm, either floating freely or attached to the endoplasmic reticulum (ER). They read the instructions carried by messenger RNA (mRNA) and assemble amino acids in the correct order to build a protein. When ribosomes attach to the ER, it is called the rough endoplasmic reticulum (RER). In our example, the protein is made by a ribosome attached to the RER, allowing the growing protein to enter the ER as it is produced.",
            caption:
                "A ribosome attached to the rough endoplasmic reticulum reads the mRNA and builds a chain of amino acids.",
            slot: SIMD3<Float>(-1.7, 2.2, 0.85),
            fit: 2.0,
            scatterAngle: 90,
            scatterTilt: simd_quatf(angle: -0.6, axis: SIMD3<Float>(1, 0, 0)),
            proteinColor: UIColor(red: 1.0, green: 0.55, blue: 0.3, alpha: 1),
            destination: .organelle(.endoplasmicReticulum)
        ),
        OrganelleSpec(
            kind: .endoplasmicReticulum,
            //            assetName: "ER",
//            assetName: "ER_NEW/ER_New2",
            assetName: "ER_New_2",
            title: "Endoplasmic Reticulum",
            shortName: "endoplasmic reticulum",
            role:
                "A folded network of membranes with two forms: the rough endoplasmic reticulum (RER), covered with ribosomes, and the smooth endoplasmic reticulum (SER), which has no attached ribosomes and helps make lipids and regulate calcium. In our example, the growing protein enters the RER, where it folds into a specific 3D structure and undergoes quality checks before moving on.",
            caption:
                "Inside the rough endoplasmic reticulum, the new chain of amino acids folds into the 3D structure the protein needs to function.",
            // Wraps around the nucleus: the nucleus sits high up inside it, so the ER's centre is below and behind the
            // nucleus slot. Placed for a fit of 0.9; down to about 0.7 it still clears the nucleus.
            slot: SIMD3<Float>(-0.05, -0.08, -0.56),
            fit: 0.8,
            scatterAngle: 306,
            scatterTilt: simd_quatf(angle: -0.5, axis: SIMD3<Float>(0, 1, 0)),
            proteinColor: UIColor(red: 0.35, green: 0.85, blue: 1.0, alpha: 1),
            destination: .organelle(.golgi),
            // The tubes fill only the middle of its bounding box.
            infoGap: -0.18
        ),
        OrganelleSpec(
            kind: .golgi,
//            assetName: "Golgi",
            assetName: "Golgi_New_2",
            //            assetName: "Golgi_New",
            title: "Golgi Apparatus",
            shortName: "Golgi apparatus",
            role:
                "The cell’s sorting and shipping centre. The Golgi apparatus receives proteins from the endoplasmic reticulum and sorts them according to their destination. It then packages them into membrane-bound vesicles. In our example, a vesicle carries the protein to the cell membrane, where it will be released outside the cell.",
            caption:
                "The Golgi apparatus packages the protein into a vesicle, which travels to the cell membrane and releases the protein outside the cell.",
            slot: SIMD3<Float>(-1.8, -2.0, 1.0),
            fit: 0.85,
            scatterAngle: 234,
            scatterTilt: simd_quatf(angle: 0.7, axis: SIMD3<Float>(0, 0, 1)),
            proteinColor: UIColor(red: 0.45, green: 1.0, blue: 0.55, alpha: 1),
            destination: .outsideCell
        ),
    ]

    static func spec(for kind: OrganelleKind) -> OrganelleSpec {
        order.first { $0.kind == kind }!
    }

    /// Its step in the journey, counting from 1.
    static func number(for kind: OrganelleKind) -> Int {
        (order.firstIndex { $0.kind == kind } ?? 0) + 1
    }
}
