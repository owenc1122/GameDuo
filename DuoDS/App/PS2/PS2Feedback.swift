import AVFoundation
import CoreHaptics
import UIKit

/// PS2 case / memory card / tray sounds and their haptics. Same engine approach as
/// `CartridgeFeedback`: buffers are decoded once, played on an ambient, mix-with-others session.
/// The disc latch itself reuses `CartridgeFeedback.playInsertionLatch()`.
@MainActor
final class PS2Feedback {
    static let shared = PS2Feedback()

    enum Sound: String, CaseIterable {
        case caseOpen = "PS2-Case-Open"
        case caseClose = "PS2-Case-Close"
        case memoryCardInsert = "PS2-MemoryCard-Insert"
        case trayEject = "PS2-Tray-Eject"
        case trayRetract = "PS2-Tray-Retract"
    }

    private let audioEngine = AVAudioEngine()
    /// Case/card clicks and the tray motor get separate players so a click never cuts the motor.
    private let clickPlayer = AVAudioPlayerNode()
    private let motorPlayer = AVAudioPlayerNode()
    private var buffers: [Sound: AVAudioPCMBuffer] = [:]
    private var audioIsPrepared = false
    private var hapticEngine: CHHapticEngine?
    private let lightImpact = UIImpactFeedbackGenerator(style: .light)
    private let rigidImpact = UIImpactFeedbackGenerator(style: .rigid)

    private init() {
        if CHHapticEngine.capabilitiesForHardware().supportsHaptics {
            hapticEngine = try? CHHapticEngine()
            hapticEngine?.isAutoShutdownEnabled = true
        }
        for sound in Sound.allCases {
            guard let url = Bundle.main.url(forResource: sound.rawValue, withExtension: "wav", subdirectory: "PS2Audio")
                    ?? Bundle.main.url(forResource: sound.rawValue, withExtension: "wav"),
                  let file = try? AVAudioFile(forReading: url),
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                frameCapacity: AVAudioFrameCount(file.length)),
                  (try? file.read(into: buffer)) != nil else { continue }
            buffers[sound] = buffer
        }
        // All approved clips are mono 44.1 kHz; connect with the first clip's format.
        let format = buffers.values.first?.format ?? AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        for player in [clickPlayer, motorPlayer] {
            audioEngine.attach(player)
            audioEngine.connect(player, to: audioEngine.mainMixerNode, format: format)
        }
        audioEngine.mainMixerNode.outputVolume = 0.72
        audioEngine.isAutoShutdownEnabled = true
    }

    func prepare() {
        lightImpact.prepare()
        rigidImpact.prepare()
        try? hapticEngine?.start()
        guard !audioEngine.isRunning else { audioIsPrepared = true; return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            audioEngine.prepare()
            try audioEngine.start()
            audioIsPrepared = true
        } catch {
            audioIsPrepared = false
        }
    }

    /// Lid unlatching from the tray.
    func playCaseOpen() {
        lightImpact.impactOccurred(intensity: 0.55)
        play(.caseOpen, on: clickPlayer)
    }

    /// Lid snapping shut.
    func playCaseClose() {
        rigidImpact.impactOccurred(intensity: 0.7)
        play(.caseClose, on: clickPlayer)
    }

    /// Card seated in the slot.
    func playMemoryCardInsert() {
        transient(intensity: 0.85, sharpness: 0.9)
        play(.memoryCardInsert, on: clickPlayer)
    }

    func playTrayEject() { play(.trayEject, on: motorPlayer) }

    func playTrayRetract() {
        lightImpact.impactOccurred(intensity: 0.35)
        play(.trayRetract, on: motorPlayer)
    }

    /// Stops the tray motor (a pull released before the latch).
    func stopTray() { motorPlayer.stop() }

    private func transient(intensity: Float, sharpness: Float) {
        guard let hapticEngine else { rigidImpact.impactOccurred(intensity: CGFloat(intensity)); return }
        let event = CHHapticEvent(eventType: .hapticTransient, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness)
        ], relativeTime: 0)
        if let pattern = try? CHHapticPattern(events: [event], parameters: []),
           let player = try? hapticEngine.makePlayer(with: pattern) {
            try? player.start(atTime: CHHapticTimeImmediate)
        }
    }

    private func play(_ sound: Sound, on player: AVAudioPlayerNode) {
        if !audioIsPrepared || !audioEngine.isRunning { prepare() }
        guard audioIsPrepared, let buffer = buffers[sound] else { return }
        player.stop()
        player.scheduleBuffer(buffer, at: nil, options: .interrupts)
        player.play()
    }
}
