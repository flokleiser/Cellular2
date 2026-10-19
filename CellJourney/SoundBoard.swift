import AVFoundation

/// The sounds that don't come from a spot in the scene: button taps and the two background loops.
/// The base loop starts with the journey and gives way to the ambiance as the cell grows around the viewer.
@MainActor
final class SoundBoard {
    static let shared = SoundBoard()

    private static let baseVolume: Float = 0.18
    private static let ambianceVolume: Float = 0.7
    private static let tapVolume: Float = 0.7

    private let base = SoundBoard.player("base_sound.wav", loops: true)
    private let ambiance = SoundBoard.player("ambiance_vr.wav", loops: true)
    private let tapSound = SoundBoard.player("info_button.wav", loops: false)

    private init() {}

    func tap() {
        guard let tapSound else { return }
        tapSound.volume = Self.tapVolume
        tapSound.currentTime = 0
        tapSound.play()
    }

    func startJourney() {
        ambiance?.stop()
        ambiance?.currentTime = 0
        base?.volume = 0
        base?.currentTime = 0
        base?.play()
        base?.setVolume(Self.baseVolume, fadeDuration: 1.5)
    }

    func stopJourney() {
        base?.stop()
        ambiance?.stop()
    }

    /// 0 while the cell is in front of the viewer, 1 once it surrounds them.
    func setImmersion(_ value: Float) {
        base?.volume = Self.baseVolume * (1 - value)
        guard let ambiance else { return }
        ambiance.volume = Self.ambianceVolume * value
        if value > 0.001, !ambiance.isPlaying {
            ambiance.play()
        } else if value <= 0.001, ambiance.isPlaying {
            ambiance.pause()
        }
    }

    private static func player(_ name: String, loops: Bool) -> AVAudioPlayer? {
        guard let url = Bundle.main.url(forResource: name, withExtension: nil),
            let player = try? AVAudioPlayer(contentsOf: url)
        else {
            print("[Sound] missing \(name)")
            return nil
        }
        player.numberOfLoops = loops ? -1 : 0
        player.prepareToPlay()
        return player
    }
}
