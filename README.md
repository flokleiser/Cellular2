# Cell Journey (visionOS 2, Xcode 16+)

Open `CellJourney.xcodeproj`, pick your Team under Signing & Capabilities, run on Apple Vision Pro or the simulator.

Copy a fresh `Package.realitycomposerpro` from a new visionOS app template into `Packages/RealityKitContent/`, then open it in Reality Composer Pro.

## Models
`Packages/RealityKitContent/Sources/RealityKitContent/RealityKitContent.rkassets` holds your six models after `Tools/normalize_usd.py` converted them: Blender's Z-up became Y-up and every model was recentered on its own origin. Re-run it after re-exporting from Blender:

    pip install usd-core numpy
    python3 Tools/normalize_usd.py path/to/*.usdc --out Packages/RealityKitContent/Sources/RealityKitContent/RealityKitContent.rkassets

## Where to tweak
`OrganelleCatalog.swift`: lesson order, texts, assembled position (`slot`, in model units from the cell centre), size (`fit`), place on the scatter ring (`scatterAngle`, degrees, 90 = top), protein colour and destination.
`CellSceneController.swift`: cell size (`cellDiameter`), cell scale limits, where the cell sits (`cellHome`), scatter ring distance (`scatterGap`), banner placement (`layoutAroundCell`), when the sky fades in and full immersion starts (`setCellScale`).

## Known limits
visionOS never tells an app where the user is looking, so the gaze highlight is the system hover effect and the info buttons are always visible next to unplaced organelles.
The Nucleus has about 600k triangles; decimate it in Blender if frame rate drops.
No app icon is included.
