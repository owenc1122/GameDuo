import AVFoundation
import CoreHaptics
import UIKit

/// PS2 case / memory card / tray sounds and their haptics. Same engine approach as
/// `CartridgeFeedback`: buffers are decoded once, played on an ambient, mix-with-others session.
/// The disc latch and lift reuse `CartridgeFeedback` (finger snap, and the snap reversed).
/// Every open/close movement has a sound; a closing movement without its own recording plays
/// the opening sound reversed.
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
    /// Case/card clicks, the tray motor and the memory card door get separate players so one
    /// never cuts another.
    private let clickPlayer = AVAudioPlayerNode()
    private let motorPlayer = AVAudioPlayerNode()
    private let doorPlayer = AVAudioPlayerNode()
    private var buffers: [Sound: AVAudioPCMBuffer] = [:]
    /// Memory card leaving the slot: the insert reversed.
    private var memoryCardWithdrawBuffer: AVAudioPCMBuffer?
    /// Slot door: a short, quieter slice of the case-open latch pop; closing plays it reversed.
    private var doorOpenBuffer: AVAudioPCMBuffer?
    private var doorCloseBuffer: AVAudioPCMBuffer?
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
        memoryCardWithdrawBuffer = buffers[.memoryCardInsert].flatMap { Self.reversed($0) }
        doorOpenBuffer = buffers[.caseOpen].flatMap { Self.slice($0, from: 0.025, duration: 0.115, gain: 0.45) }
        doorCloseBuffer = doorOpenBuffer.flatMap { Self.reversed($0) }
        // All approved clips are mono 44.1 kHz; connect with the first clip's format.
        let format = buffers.values.first?.format ?? AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        for player in [clickPlayer, motorPlayer, doorPlayer] {
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
        play(buffers[.caseOpen], on: clickPlayer, name: "case-open")
    }

    /// Lid snapping shut.
    func playCaseClose() {
        rigidImpact.impactOccurred(intensity: 0.7)
        play(buffers[.caseClose], on: clickPlayer, name: "case-close")
    }

    /// Card seated in the slot.
    func playMemoryCardInsert() {
        transient(intensity: 0.85, sharpness: 0.9)
        play(buffers[.memoryCardInsert], on: clickPlayer, name: "memory-card-insert")
    }

    /// Card pulled out of the slot (the insert reversed).
    func playMemoryCardWithdraw() {
        lightImpact.impactOccurred(intensity: 0.45)
        play(memoryCardWithdrawBuffer, on: clickPlayer, name: "memory-card-withdraw(reversed insert)")
    }

    /// Memory card slot door swinging open / shut.
    func playSlotDoor(open: Bool) {
        play(open ? doorOpenBuffer : doorCloseBuffer, on: doorPlayer,
             name: open ? "slot-door-open(case-open slice)" : "slot-door-close(reversed slice)")
    }

    func playTrayEject() { play(buffers[.trayEject], on: motorPlayer, name: "tray-eject") }

    func playTrayRetract() {
        lightImpact.impactOccurred(intensity: 0.35)
        play(buffers[.trayRetract], on: motorPlayer, name: "tray-retract")
    }

    /// Disc snapping onto the tray.
    func playDiscLatch() {
        CartridgeFeedback.shared.playInsertionLatch()
        Self.log("disc-latch(finger snap)")
    }

    /// Disc lifted off the tray (the snap reversed).
    func playDiscLift() {
        CartridgeFeedback.shared.playEjectionRelease()
        Self.log("disc-lift(reversed snap)")
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

    private func play(_ buffer: AVAudioPCMBuffer?, on player: AVAudioPlayerNode, name: String) {
        Self.log(name)
        if !audioIsPrepared || !audioEngine.isRunning { prepare() }
        guard audioIsPrepared, let buffer else { return }
        player.stop()
        player.scheduleBuffer(buffer, at: nil, options: .interrupts)
        player.play()
    }

    private static func log(_ name: String) {
        #if DEBUG
        NSLog("DUO_PS2_SOUND %@", name)
        #endif
    }

    // MARK: Derived buffers

    /// `source` backwards, without the trailing silence (which would otherwise delay it), with a
    /// short fade-in so the reversed tail does not click.
    private static func reversed(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let input = source.floatChannelData else { return nil }
        let channels = Int(source.format.channelCount)
        var end = Int(source.frameLength)
        while end > 1, (0..<channels).allSatisfy({ abs(input[$0][end - 1]) < 0.002 }) { end -= 1 }
        guard let output = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: AVAudioFrameCount(end)),
              let destination = output.floatChannelData else { return nil }
        output.frameLength = AVAudioFrameCount(end)
        let fade = min(end, Int(source.format.sampleRate * 0.004))
        for channel in 0..<channels {
            for frame in 0..<end {
                let gain = frame < fade ? Float(frame) / Float(max(1, fade)) : 1
                destination[channel][frame] = input[channel][end - 1 - frame] * gain
            }
        }
        return output
    }

    /// A `duration`-second piece of `source` from `start`, scaled by `gain`, with 2 ms / 20 ms fades.
    private static func slice(_ source: AVAudioPCMBuffer, from start: Double, duration: Double,
                              gain: Float) -> AVAudioPCMBuffer? {
        guard let input = source.floatChannelData else { return nil }
        let rate = source.format.sampleRate
        let first = min(Int(source.frameLength), Int(start * rate))
        let count = min(Int(source.frameLength) - first, Int(duration * rate))
        guard count > 0, let output = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: AVAudioFrameCount(count)),
              let destination = output.floatChannelData else { return nil }
        output.frameLength = AVAudioFrameCount(count)
        let fadeIn = Int(rate * 0.002), fadeOut = Int(rate * 0.02)
        for channel in 0..<Int(source.format.channelCount) {
            for frame in 0..<count {
                var g = gain
                if frame < fadeIn { g *= Float(frame) / Float(max(1, fadeIn)) }
                if frame > count - fadeOut { g *= Float(count - frame) / Float(max(1, fadeOut)) }
                destination[channel][frame] = input[channel][first + frame] * g
            }
        }
        return output
    }
}
