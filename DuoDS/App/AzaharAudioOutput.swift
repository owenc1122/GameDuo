import AVFoundation
import Foundation
#if DEBUG
import Synchronization
#endif

/// Streams the core's native interleaved 16-bit stereo PCM continuously.
/// Normal samples pass unchanged. A short fade is used only when the producer
/// stalls, preventing missing samples from becoming repeated electrical clicks.
final class AzaharAudioOutput {
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var ringBuffer: AudioRingBuffer?
    private var generation = 0
    private var volume: Float = 1
    private(set) var isRunning = false
    #if DEBUG
    private let underrunFrames = Atomic<UInt64>(0)
    private let renderedFrames = Atomic<UInt64>(0)
    var diagnosticCounts: (underrun: UInt64, rendered: UInt64, queuedBytes: Int) {
        (underrunFrames.load(ordering: .relaxed), renderedFrames.load(ordering: .relaxed), ringBuffer?.availableBytesForReading ?? 0)
    }
    #endif

    func start(sampleRate: Double) {
        stop()
        #if DEBUG
        underrunFrames.store(0, ordering: .relaxed)
        renderedFrames.store(0, ordering: .relaxed)
        #endif
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: 2,
            interleaved: true
        ), let ringBuffer = AudioRingBuffer(preferredBufferSize: Int(sampleRate * 4)) else { return }

        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [])
        try? session.setPreferredSampleRate(sampleRate)
        try? session.setPreferredIOBufferDuration(0.02)
        try? session.setActive(true)
        #endif

        let generation = self.generation
        let channelCount = Int(format.channelCount)
        let bytesPerFrame = channelCount * MemoryLayout<Int16>.size
        let fadeFrames = 64
        var primed = false
        var fadeIn = true
        var consecutiveStarvedCallbacks = 0
        var lastSamples = [Int16](repeating: 0, count: channelCount)

        let sourceNode = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let self, self.generation == generation,
                  let destination = buffers.first?.mData else { return noErr }
            let requestedBytes = Int(frameCount) * bytesPerFrame

            func renderSilence() {
                let samples = destination.assumingMemoryBound(to: Int16.self)
                memset(destination, 0, requestedBytes)
                let count = min(Int(frameCount), fadeFrames)
                for frame in 0..<count {
                    let gain = Double(count - frame - 1) / Double(count)
                    for channel in 0..<channelCount {
                        samples[frame * channelCount + channel] = Int16(Double(lastSamples[channel]) * gain)
                    }
                }
                lastSamples = [Int16](repeating: 0, count: channelCount)
                fadeIn = true
            }

            if !primed {
                // A small native PCM cushion absorbs one expensive 3D frame
                // without adding the old 120 ms of audio latency.
                guard ringBuffer.availableBytesForReading >= requestedBytes * 3 else {
                    renderSilence()
                    buffers[0].mDataByteSize = UInt32(requestedBytes)
                    return noErr
                }
                primed = true
            }

            let availableBytes = ringBuffer.availableBytesForReading
            let readableBytes = min(requestedBytes, availableBytes) / bytesPerFrame * bytesPerFrame
            let readBytes = readableBytes > 0
                ? ringBuffer.read(into: destination, preferredSize: readableBytes)
                : 0
            let readFrames = readBytes / bytesPerFrame
            let samples = destination.assumingMemoryBound(to: Int16.self)
            if fadeIn {
                let count = min(readFrames, fadeFrames)
                for frame in 0..<count {
                    let gain = Double(frame + 1) / Double(count)
                    for channel in 0..<channelCount {
                        let index = frame * channelCount + channel
                        samples[index] = Int16(Double(samples[index]) * gain)
                    }
                }
                fadeIn = false
            }
            if readFrames > 0 {
                let lastFrame = (readFrames - 1) * channelCount
                for channel in 0..<channelCount { lastSamples[channel] = samples[lastFrame + channel] }
            }

            if readBytes < requestedBytes {
                #if DEBUG
                self.underrunFrames.wrappingAdd(UInt64(Int(frameCount) - readFrames), ordering: .relaxed)
                #endif
                consecutiveStarvedCallbacks += 1
                let missingFrames = Int(frameCount) - readFrames
                for frame in 0..<missingFrames {
                    let gain = max(0, 1 - Double(frame + 1) / Double(max(missingFrames, 1)))
                    for channel in 0..<channelCount {
                        samples[(readFrames + frame) * channelCount + channel] =
                            Int16(Double(lastSamples[channel]) * gain)
                    }
                }
                lastSamples = [Int16](repeating: 0, count: channelCount)
                fadeIn = true
                // Only a sustained producer stall requires re-priming. A
                // single heavy effects frame must not create 120 ms of silence.
                if consecutiveStarvedCallbacks >= 3 { primed = false }
            } else {
                consecutiveStarvedCallbacks = 0
            }
            buffers[0].mDataByteSize = UInt32(requestedBytes)
            #if DEBUG
            self.renderedFrames.wrappingAdd(UInt64(frameCount), ordering: .relaxed)
            #endif
            return noErr
        }

        self.ringBuffer = ringBuffer
        self.sourceNode = sourceNode
        engine.attach(sourceNode)
        engine.connect(sourceNode, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = volume
        engine.prepare()
        do {
            try engine.start()
            isRunning = engine.isRunning
        } catch {
            stop()
        }
    }

    func enqueue(_ data: Data) {
        guard isRunning, let ringBuffer else { return }
        data.withUnsafeBytes { source in
            guard let address = source.baseAddress else { return }
            ringBuffer.write(address, size: source.count)
        }
    }

    func setVolume(_ value: Float) {
        volume = min(max(value, 0), 1)
        engine.mainMixerNode.outputVolume = volume
    }

    func stop() {
        generation += 1
        engine.stop()
        if let sourceNode, sourceNode.engine != nil { engine.detach(sourceNode) }
        sourceNode = nil
        ringBuffer = nil
        isRunning = false
    }
}
