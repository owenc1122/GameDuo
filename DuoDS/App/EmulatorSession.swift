import Foundation
import SwiftUI
import os
import Accelerate
import Metal
import MetalPerformanceShaders
import CoreImage
#if !targetEnvironment(simulator)
import MetalFX
#endif

extension AzaharCoreBridge: @unchecked Sendable {}

/// Runs Nintendo DS frames through Apple's real-time, edge-aware GPU upscaler.
/// This is deliberately separate from view interpolation: the resulting frame
/// already contains a full high-resolution pixel grid before SwiftUI displays it.
#if !targetEnvironment(simulator)
private final class DSMetalFXUpscaler: @unchecked Sendable {
    private final class Pipeline {
        let scaler: any MTLFXSpatialScaler
        let input: any MTLTexture
        let output: any MTLTexture
        let smoothed: any MTLTexture
        let smoothing: MPSImageGaussianBlur
        let readback: any MTLBuffer
        let readbackRowBytes: Int

        init(scaler: any MTLFXSpatialScaler, input: any MTLTexture, output: any MTLTexture,
             smoothed: any MTLTexture, smoothing: MPSImageGaussianBlur,
             readback: any MTLBuffer, readbackRowBytes: Int) {
            self.scaler = scaler
            self.input = input
            self.output = output
            self.smoothed = smoothed
            self.smoothing = smoothing
            self.readback = readback
            self.readbackRowBytes = readbackRowBytes
        }
    }

    static let shared = DSMetalFXUpscaler()
    private let device: (any MTLDevice)? = MTLCreateSystemDefaultDevice()
    private let commandQueue: (any MTLCommandQueue)?
    private var pipelines: [String: Pipeline] = [:]

    private init() {
        commandQueue = device?.makeCommandQueue()
    }

    func upscale(_ pixels: Data, width: Int, height: Int, scale: Double) -> (Data, Int, Int)? {
        guard let device, let commandQueue, MTLFXSpatialScalerDescriptor.supportsDevice(device) else { return nil }
        let outputWidth = max(1, Int((Double(width) * scale).rounded()))
        let outputHeight = max(1, Int((Double(height) * scale).rounded()))
        let key = "\(width)x\(height)-\(outputWidth)x\(outputHeight)"
        let pipeline: Pipeline
        if let cached = pipelines[key] {
            pipeline = cached
        } else {
            let descriptor = MTLFXSpatialScalerDescriptor()
            descriptor.inputWidth = width
            descriptor.inputHeight = height
            descriptor.outputWidth = outputWidth
            descriptor.outputHeight = outputHeight
            descriptor.colorTextureFormat = .bgra8Unorm_srgb
            descriptor.outputTextureFormat = .bgra8Unorm_srgb
            descriptor.colorProcessingMode = .perceptual
            guard let scaler = descriptor.makeSpatialScaler(device: device) else { return nil }

            let inputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm_srgb, width: width, height: height, mipmapped: false
            )
            inputDescriptor.storageMode = .shared
            inputDescriptor.usage = scaler.colorTextureUsage

            let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm_srgb, width: outputWidth, height: outputHeight, mipmapped: false
            )
            outputDescriptor.storageMode = .private
            outputDescriptor.usage = scaler.outputTextureUsage.union([.shaderRead, .shaderWrite])

            let rowAlignment = max(256, device.minimumLinearTextureAlignment(for: .bgra8Unorm_srgb))
            let readbackRowBytes = ((outputWidth * 4 + rowAlignment - 1) / rowAlignment) * rowAlignment
            guard let input = device.makeTexture(descriptor: inputDescriptor),
                  let output = device.makeTexture(descriptor: outputDescriptor),
                  let smoothed = device.makeTexture(descriptor: outputDescriptor),
                  let readback = device.makeBuffer(length: readbackRowBytes * outputHeight, options: .storageModeShared) else {
                return nil
            }
            let smoothing = MPSImageGaussianBlur(device: device, sigma: 1.15)
            smoothing.edgeMode = .clamp
            pipeline = Pipeline(scaler: scaler, input: input, output: output, smoothed: smoothed,
                                smoothing: smoothing,
                                readback: readback, readbackRowBytes: readbackRowBytes)
            pipelines[key] = pipeline
        }

        pixels.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            pipeline.input.replace(
                region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                withBytes: base, bytesPerRow: width * 4
            )
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return nil }
        pipeline.scaler.colorTexture = pipeline.input
        pipeline.scaler.outputTexture = pipeline.output
        pipeline.scaler.inputContentWidth = width
        pipeline.scaler.inputContentHeight = height
        pipeline.scaler.encode(commandBuffer: commandBuffer)
        pipeline.smoothing.encode(commandBuffer: commandBuffer,
                                  sourceTexture: pipeline.output,
                                  destinationTexture: pipeline.smoothed)
        guard let blit = commandBuffer.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: pipeline.smoothed, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: outputWidth, height: outputHeight, depth: 1),
                  to: pipeline.readback, destinationOffset: 0,
                  destinationBytesPerRow: pipeline.readbackRowBytes,
                  destinationBytesPerImage: pipeline.readbackRowBytes * outputHeight)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else { return nil }

        let packedRowBytes = outputWidth * 4
        var outputPixels = Data(count: packedRowBytes * outputHeight)
        outputPixels.withUnsafeMutableBytes { destination in
            guard let destinationBase = destination.baseAddress else { return }
            let sourceBase = pipeline.readback.contents()
            for row in 0..<outputHeight {
                memcpy(destinationBase.advanced(by: row * packedRowBytes),
                       sourceBase.advanced(by: row * pipeline.readbackRowBytes), packedRowBytes)
            }
        }
        return (outputPixels, outputWidth, outputHeight)
    }
}
#else
private final class DSMetalFXUpscaler: @unchecked Sendable {
    private final class Pipeline {
        let input: any MTLTexture
        let scaled: any MTLTexture
        let smoothed: any MTLTexture
        let resampler: MPSImageLanczosScale
        let smoothing: MPSImageGaussianBlur
        let readback: any MTLBuffer
        let readbackRowBytes: Int

        init(input: any MTLTexture, scaled: any MTLTexture, smoothed: any MTLTexture,
             resampler: MPSImageLanczosScale, smoothing: MPSImageGaussianBlur,
             readback: any MTLBuffer, readbackRowBytes: Int) {
            self.input = input
            self.scaled = scaled
            self.smoothed = smoothed
            self.resampler = resampler
            self.smoothing = smoothing
            self.readback = readback
            self.readbackRowBytes = readbackRowBytes
        }
    }

    static let shared = DSMetalFXUpscaler()
    private let device: (any MTLDevice)? = MTLCreateSystemDefaultDevice()
    private let commandQueue: (any MTLCommandQueue)?
    private var pipelines: [String: Pipeline] = [:]

    private init() {
        commandQueue = device?.makeCommandQueue()
    }

    func upscale(_ pixels: Data, width: Int, height: Int, scale: Double) -> (Data, Int, Int)? {
        guard let device, let commandQueue else { return nil }
        let outputWidth = max(1, Int((Double(width) * scale).rounded()))
        let outputHeight = max(1, Int((Double(height) * scale).rounded()))
        let key = "\(width)x\(height)-\(outputWidth)x\(outputHeight)"
        let pipeline: Pipeline
        if let cached = pipelines[key] {
            pipeline = cached
        } else {
            let inputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
            )
            inputDescriptor.storageMode = .shared
            inputDescriptor.usage = [.shaderRead]
            let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: outputWidth, height: outputHeight, mipmapped: false
            )
            outputDescriptor.storageMode = .private
            outputDescriptor.usage = [.shaderRead, .shaderWrite]
            let rowAlignment = max(256, device.minimumLinearTextureAlignment(for: .bgra8Unorm))
            let readbackRowBytes = ((outputWidth * 4 + rowAlignment - 1) / rowAlignment) * rowAlignment
            guard let input = device.makeTexture(descriptor: inputDescriptor),
                  let scaled = device.makeTexture(descriptor: outputDescriptor),
                  let smoothed = device.makeTexture(descriptor: outputDescriptor),
                  let readback = device.makeBuffer(length: readbackRowBytes * outputHeight,
                                                   options: .storageModeShared) else { return nil }
            let resampler = MPSImageLanczosScale(device: device)
            let smoothing = MPSImageGaussianBlur(device: device, sigma: 1.15)
            smoothing.edgeMode = .clamp
            pipeline = Pipeline(input: input, scaled: scaled, smoothed: smoothed,
                                resampler: resampler, smoothing: smoothing,
                                readback: readback, readbackRowBytes: readbackRowBytes)
            pipelines[key] = pipeline
        }

        pixels.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            pipeline.input.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                                   withBytes: base, bytesPerRow: width * 4)
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return nil }
        pipeline.resampler.encode(
            commandBuffer: commandBuffer,
            sourceTexture: pipeline.input,
            destinationTexture: pipeline.scaled
        )
        pipeline.smoothing.encode(commandBuffer: commandBuffer,
                                  sourceTexture: pipeline.scaled,
                                  destinationTexture: pipeline.smoothed)
        guard let blit = commandBuffer.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: pipeline.smoothed, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: outputWidth, height: outputHeight, depth: 1),
                  to: pipeline.readback, destinationOffset: 0,
                  destinationBytesPerRow: pipeline.readbackRowBytes,
                  destinationBytesPerImage: pipeline.readbackRowBytes * outputHeight)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else { return nil }

        let packedRowBytes = outputWidth * 4
        var outputPixels = Data(count: packedRowBytes * outputHeight)
        outputPixels.withUnsafeMutableBytes { destination in
            guard let destinationBase = destination.baseAddress else { return }
            let sourceBase = pipeline.readback.contents()
            for row in 0..<outputHeight {
                memcpy(destinationBase.advanced(by: row * packedRowBytes),
                       sourceBase.advanced(by: row * pipeline.readbackRowBytes), packedRowBytes)
            }
        }
        return (outputPixels, outputWidth, outputHeight)
    }
}
#endif

@MainActor
final class EmulatorSession: NSObject, ObservableObject {
    @Published private var publishedTopImage: CGImage?
    private var pspLatestImage: CGImage?
    private var pspLatestBuffer: CVPixelBuffer?
    private var pspBufferFlipped = false
    private lazy var pspCaptureContext = CIContext(options: [.cacheIntermediates: false])
    var pspUsesSharedBuffer: Bool { pspLatestBuffer != nil }
    private(set) var topImage: CGImage? {
        get {
            guard backend == .psp else { return publishedTopImage }
            guard let buffer = pspLatestBuffer else { return pspLatestImage }
            // Read back only for an explicit screenshot/save-state preview.
            var image = CIImage(cvPixelBuffer: buffer)
            if pspBufferFlipped { image = image.oriented(.downMirrored) }
            return pspCaptureContext.createCGImage(image, from: image.extent)
        }
        set { publishedTopImage = newValue }
    }
    // PSP's planar display can update its CALayer without invalidating the
    // library, console layout and control hierarchy at the game's frame rate.
    var pspFramePresenter: ((CGImage) -> Void)?
    var pspBufferPresenter: ((CVPixelBuffer, Bool) -> Void)?
    @Published private(set) var bottomImage: CGImage?
    @Published private(set) var loadedROMName: String?
    @Published private(set) var isRunning = false
    @Published private(set) var isPaused = false
    @Published private(set) var isAudioRunning = false
    @Published private(set) var gameRequestedExit = false
    @Published private(set) var isN64 = false
    @Published private(set) var isPSP = false
    @Published private(set) var currentFPS = 0.0
    @Published private(set) var gameVolume: Float = 1
    @Published private(set) var storageActivityToken = 0
    @Published private(set) var currentROMURL: URL?
    @Published var runtimeConfiguration = DuoRuntimeConfiguration()
    @Published var proMessage: String?
    @Published var launchError: String?

    private let azaharBridge = AzaharCoreBridge()
    private let azaharAudio = AzaharAudioOutput()
    private let emulationQueue = DispatchQueue(label: "com.duods.emulation", qos: .userInitiated)
    private let videoProcessingQueue = DispatchQueue(label: "com.duods.video-reconstruction", qos: .userInitiated)
    private let videoProcessingSlot = DispatchSemaphore(value: 1)
    private var frameTimer: DispatchSourceTimer?
    private enum Backend { case nds, threeDS, n64, psp }
    private var backend: Backend?
    private var measuredFrameCount = 0
    private var measurementStart = DispatchTime.now().uptimeNanoseconds
    private var sustainedFPS: [Double] = []
    private let performanceLog = Logger(subsystem: "com.duods.app", category: "performance")
    private var turboTasks: [String: Task<Void, Never>] = [:]
    private var momentaryPressTimes: [Int: TimeInterval] = [:]
    private var momentaryReleaseTasks: [Int: Task<Void, Never>] = [:]
    private var lastTopNativeFrame: Data?
    private var lastBottomNativeFrame: Data?
    private var cachedTopUpscaled: CGImage?
    private var cachedBottomUpscaled: CGImage?
    private var cachedUpscaleScale = 0.0
    private let pspPresentationLock = NSLock()
    private var pspPendingImage: CGImage?
    private var pspPendingBuffer: CVPixelBuffer?
    private var pspPendingFlipped = false
    private var pspPresentationScheduled = false
    #if DEBUG
    private var pspValidationImageCount = 0
    private let capturePSPAA = ProcessInfo.processInfo.arguments.contains("-psp-aa-capture")
    #endif

    @MainActor private func consumePSPPresentation() {
        let (image, buffer, flipped) = pspPresentationLock.withLock {
            let pending = (pspPendingImage, pspPendingBuffer, pspPendingFlipped)
            pspPendingImage = nil
            pspPendingBuffer = nil
            pspPresentationScheduled = false
            return pending
        }
        guard isRunning, backend == .psp else { return }
        if let buffer {
            pspLatestBuffer = buffer
            pspBufferFlipped = flipped
            pspBufferPresenter?(buffer, flipped)
            return
        }
        guard let image else { return }
        pspLatestBuffer = nil
        pspLatestImage = image
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-psp-thermal-baseline") {
            publishedTopImage = image
            return
        }
        #endif
        pspFramePresenter?(image)
    }

    override init() {
        super.init()
        #if DEBUG
        let sharedPSPFrames = !ProcessInfo.processInfo.arguments.contains("-psp-thermal-baseline")
        #else
        let sharedPSPFrames = true
        #endif
        if sharedPSPFrames {
            azaharBridge.pixelBufferHandler = { [weak self] buffer, flipped in
                guard let self else { return }
                let schedule = self.pspPresentationLock.withLock {
                    self.pspPendingBuffer = buffer
                    self.pspPendingFlipped = flipped
                    if self.pspPresentationScheduled { return false }
                    self.pspPresentationScheduled = true
                    return true
                }
                if schedule { Task { @MainActor [weak self] in self?.consumePSPPresentation() } }
            }
        }
        azaharBridge.videoHandler = { [weak self] (frame: Data, width: UInt, height: UInt, pitch: UInt, rgba: Bool) in
            guard let self else { return }
            if self.backend == .psp {
                // One latest-frame mailbox: no second pixel copy and no queue
                // of stale UI updates when a menu or rotation occupies main.
                guard let image = self.makeXRGBImage(data: frame, width: Int(width), height: Int(height), bytesPerRow: Int(pitch), rgba: rgba) else { return }
                #if DEBUG
                if self.capturePSPAA {
                    self.pspValidationImageCount += 1
                    if self.pspValidationImageCount == 300 {
                        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                            .appendingPathComponent("psp-aa-frame300.png")
                        DispatchQueue.global(qos: .utility).async {
                            try? UIImage(cgImage: image).pngData()?.write(to: url, options: .atomic)
                            print("DUO_PSP_AA_CAPTURE: frame300")
                        }
                    }
                }
                #endif
                let schedule = self.pspPresentationLock.withLock {
                    self.pspPendingImage = image
                    if self.pspPresentationScheduled { return false }
                    self.pspPresentationScheduled = true
                    return true
                }
                guard schedule else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.consumePSPPresentation()
                }
                return
            }
            guard self.videoProcessingSlot.wait(timeout: .now()) == .success else { return }
            let slot = self.videoProcessingSlot
            self.videoProcessingQueue.async { [weak self] in
                defer { slot.signal() }
                self?.processAzaharFrame(frame, width: Int(width), height: Int(height), pitch: Int(pitch))
            }
        }
        azaharBridge.audioHandler = { [weak self] (samples: Data, _: Double) in
            self?.azaharAudio.enqueue(samples)
        }
        azaharBridge.messageHandler = { [weak self] (message: String) in
            Task { @MainActor [weak self] in
                if message.localizedCaseInsensitiveContains("error") ||
                    message.localizedCaseInsensitiveContains("unable") ||
                    message.localizedCaseInsensitiveContains("failed") {
                    self?.loadedROMName = message
                }
            }
        }
    }

    deinit {
        frameTimer?.cancel()
    }

    func start(romURL: URL) {
        stop()
        videoProcessingQueue.sync { resetUpscaleCache() }
        #if DEBUG
        pspValidationImageCount = 0
        #endif
        measuredFrameCount = 0
        sustainedFPS.removeAll(keepingCapacity: true)
        measurementStart = DispatchTime.now().uptimeNanoseconds
        gameRequestedExit = false
        launchError = nil
        topImage = nil
        pspLatestImage = nil
        pspLatestBuffer = nil
        bottomImage = nil
        currentROMURL = romURL
        let ext: String
        do { ext = try ROMFiles.canonicalExtension(romURL) }
        catch { launchError = error.localizedDescription; return }
        // PS2 discs share .iso/.cso with PSP; there is no PS2 core yet, so never hand them to PPSSPP.
        if ROMFiles.discImages.contains(ext), ROMFiles.isPS2Disc(romURL) {
            launchError = String(localized: "PS2 模拟内核尚未接入"); return
        }
        isN64 = ROMFiles.n64.contains(ext)
        isPSP = ROMFiles.psp.contains(ext)
        guard isN64 || isPSP || Self.threeDSExtensions.contains(ext) || ext == "nds" else {
            launchError = String(localized: "请先从游戏库导入并安装这个文件"); return
        }
        backend = isN64 ? .n64 : isPSP ? .psp : ext == "nds" ? .nds : .threeDS
        startCore(romURL: romURL)
        storageActivityToken &+= 1
    }

    func stop() {
        releaseAllInputs()
        frameTimer?.cancel()
        frameTimer = nil
        if isRunning {
            emulationQueue.sync { azaharBridge.stop() }
            azaharAudio.stop()
        }
        isRunning = false
        isPaused = false
        isAudioRunning = false
        backend = nil
        isN64 = false
        isPSP = false
        pspPresentationLock.withLock { pspPendingImage = nil; pspPendingBuffer = nil }
        pspLatestBuffer = nil
        currentROMURL = nil
        turboTasks.values.forEach { $0.cancel() }
        turboTasks.removeAll()
        momentaryReleaseTasks.values.forEach { $0.cancel() }
        momentaryReleaseTasks.removeAll()
        momentaryPressTimes.removeAll()
    }

    func togglePause() {
        guard isRunning else { return }
        if isPaused {
            azaharAudio.start(sampleRate: azaharBridge.sampleRate)
            frameTimer = makeFrameTimer()
            isPaused = false
        } else {
            releaseAllInputs()
            frameTimer?.cancel()
            frameTimer = nil
            emulationQueue.sync {} // Drain the current frame before pausing audio.
            azaharAudio.stop()
            isPaused = true
        }
        isAudioRunning = azaharAudio.isRunning
    }

    func adjustVolume(by delta: Float) {
        gameVolume = min(max(gameVolume + delta, 0), 1)
        azaharAudio.setVolume(gameVolume)
    }

    func saveGame() {
        guard isRunning else { return }
        emulationQueue.sync { azaharBridge.savePersistentData() }
        storageActivityToken &+= 1
    }

    private func makeFrameTimer() -> DispatchSourceTimer {
        // Paused/background time is not a slow emulated frame.
        emulationQueue.sync {
            measuredFrameCount = 0
            measurementStart = DispatchTime.now().uptimeNanoseconds
        }
        let timer = DispatchSource.makeTimerSource(queue: emulationQueue)
        let duration = azaharBridge.frameDuration
        let interval = DispatchTimeInterval.nanoseconds(max(1, Int(duration * 1_000_000_000)))
        let azaharBridge = self.azaharBridge
        timer.schedule(deadline: .now(), repeating: interval, leeway: .microseconds(250))
        timer.setEventHandler { [weak self] in
            let frames = max(1, min(4, Int((self?.runtimeConfiguration.preferences.speed ?? 1).rounded())))
            for _ in 0..<frames { azaharBridge.runFrame() }
            self?.recordFrame()
        }
        timer.resume()
        return timer
    }

    private func recordFrame() {
        measuredFrameCount += 1
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = now - measurementStart
        guard elapsed >= 1_000_000_000 else { return }
        let fps = Double(measuredFrameCount) / (Double(elapsed) / 1_000_000_000)
        sustainedFPS.append(fps)
        if sustainedFPS.count > 120 { sustainedFPS.removeFirst(sustainedFPS.count - 120) }
        Task { @MainActor [weak self] in self?.currentFPS = fps }
        let backendName = self.backend == .n64 ? "n64" : self.backend == .psp ? "psp" : self.backend == .threeDS ? "3ds" : "nds"
        let thermal: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = "nominal"
        case .fair: thermal = "fair"
        case .serious: thermal = "serious"
        case .critical: thermal = "critical"
        @unknown default: thermal = "unknown"
        }
        let average = sustainedFPS.reduce(0, +) / Double(sustainedFPS.count)
        let minimum = sustainedFPS.min() ?? fps
        print("DUO_FPS backend=\(backendName) value=\(String(format: "%.1f", fps)) avg=\(String(format: "%.1f", average)) min=\(String(format: "%.1f", minimum)) thermal=\(thermal)")
        #if DEBUG
        if self.backend == .psp {
            let audio = azaharAudio.diagnosticCounts
            print("DUO_PSP_AUDIO missing_frames=\(audio.underrun) rendered_frames=\(audio.rendered) queued_bytes=\(audio.queuedBytes)")
        }
        #endif
        performanceLog.info("backend=\(backendName, privacy: .public) fps=\(fps, privacy: .public)")
        measuredFrameCount = 0
        measurementStart = now
    }

    func press(_ input: DuoInput) {
        let input = mapped(input)
        guard isRunning, !isPaused, let button = azaharButton(for: input) else { return }
        if runtimeConfiguration.isPro, runtimeConfiguration.preferences.turboButtons.contains(String(input.rawValue)) {
            startTurbo(input); return
        }
        // The bridge protects input state with its own mutex. Write it now
        // instead of queueing behind an expensive emulated frame.
        azaharBridge.setButton(button, pressed: true)
    }

    func release(_ input: DuoInput) {
        let input = mapped(input)
        turboTasks[String(input.rawValue)]?.cancel(); turboTasks[String(input.rawValue)] = nil
        guard backend != nil, let button = azaharButton(for: input) else { return }
        azaharBridge.setButton(button, pressed: false)
    }

    /// Small menu buttons are often tapped down and up between two core input
    /// polls. Keep them asserted for three 60 Hz frames so the game always
    /// observes the press without adding repeat or gameplay latency.
    func pressMomentary(_ input: DuoInput) {
        let key = input.rawValue
        momentaryReleaseTasks[key]?.cancel()
        momentaryReleaseTasks[key] = nil
        momentaryPressTimes[key] = CACurrentMediaTime()
        press(input)
    }

    func releaseMomentary(_ input: DuoInput) {
        let key = input.rawValue
        let elapsed = CACurrentMediaTime() - (momentaryPressTimes[key] ?? 0)
        let delay = max(0, 0.050 - elapsed)
        momentaryReleaseTasks[key]?.cancel()
        momentaryReleaseTasks[key] = Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            self?.release(input)
            self?.momentaryPressTimes[key] = nil
            self?.momentaryReleaseTasks[key] = nil
        }
    }

    func touch(at point: CGPoint, in size: CGSize) {
        guard isRunning, !isPaused, size.width > 0, size.height > 0 else { return }
        let x = min(max(point.x / size.width, 0), 1)
        let y = min(max(point.y / size.height, 0), 1)
        azaharBridge.setTouchX(x, y: y, pressed: true)
    }

    func releaseTouch() {
        guard backend != nil else { return }
        azaharBridge.setTouchX(0.5, y: 0.5, pressed: false)
    }

    func releaseAllInputs() {
        let inputs: [DuoInput] = [.a, .b, .x, .y, .l, .r, .start, .select, .up, .down, .left, .right, .lid]
        inputs.forEach { release($0) }
        releaseTouch()
        setCirclePad(x: 0, y: 0)
        if backend == .n64 || backend == .psp {
            for code in 0..<16 {
                if let button = AzaharButton(rawValue: code) { azaharBridge.setButton(button, pressed: false) }
            }
        }
    }

    func setCirclePad(x: Double, y: Double) {
        guard backend == .threeDS || backend == .n64 || backend == .psp else { return }
        azaharBridge.setCirclePadX(x, y: y)
    }

    private static let threeDSExtensions = GamePlatform.threeDSROMExtensions

    private func startCore(romURL: URL) {
        azaharBridge.exitHandler = { [weak self] in
            Task { @MainActor [weak self] in self?.gameRequestedExit = true }
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let systemDirectory = backend == .psp
            ? (Bundle.main.resourceURL ?? support)
            : support.appendingPathComponent(backend == .nds ? "DS/System" : "Azahar/System", isDirectory: true)
        let saveDirectory = backend == .nds ? support.appendingPathComponent("Saves", isDirectory: true)
            : isN64 ? support.appendingPathComponent("N64/Saves", isDirectory: true)
            : backend == .psp ? support.appendingPathComponent("PSP/MemoryStick", isDirectory: true)
            : ROMFiles.azaharSaves(support)
        do {
            try FileManager.default.createDirectory(at: systemDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: saveDirectory, withIntermediateDirectories: true)
            if backend == .nds {
                let oldSD = support.appendingPathComponent("DLDI.sd.img")
                let newSD = saveDirectory.appendingPathComponent("melonDS DS/dldi_sd_card.bin")
                if FileManager.default.fileExists(atPath: oldSD.path), !FileManager.default.fileExists(atPath: newSD.path) {
                    try FileManager.default.createDirectory(at: newSD.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: oldSD, to: newSD)
                }
            }
            if backend == .psp {
                azaharBridge.setCoreOptionValue(runtimeConfiguration.pspFrameRateMode.rawValue, forKey: "duo_psp_frame_rate")
                var antialias = "enabled"
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-psp-aa-off") { antialias = "disabled" }
                print("DUO_PSP_AA: \(antialias)")
                #endif
                azaharBridge.setCoreOptionValue(antialias, forKey: "duo_psp_antialias")
                azaharBridge.setCoreOptionValue("opengl", forKey: "ppsspp_backend")
                azaharBridge.setCoreOptionValue("disabled", forKey: "ppsspp_software_rendering")
                azaharBridge.setCoreOptionValue(runtimeConfiguration.pspRenderMode == .hd ? "960x544" : "480x272",
                                               forKey: "ppsspp_internal_resolution")
                // Smooth magnified 3D textures in the hardware sampler. The
                // core retains its alpha/color-test compatibility checks;
                // no CPU texture upscaling or extra image pass is needed.
                var textureFiltering = runtimeConfiguration.pspRenderMode == .hd ? "Linear" : "Auto"
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-psp-original-texture-filter") { textureFiltering = "Auto" }
                #endif
                azaharBridge.setCoreOptionValue(textureFiltering, forKey: "ppsspp_texture_filtering")
                azaharBridge.setCoreOptionValue("disabled", forKey: "ppsspp_texture_scaling_level")
                // IR interpreter is the optimized no-executable-memory CPU core
                // supported on ordinary iOS installs and the simulator alike.
                azaharBridge.setCoreOptionValue("IR JIT", forKey: "ppsspp_cpu_core")
            }
            let azaharBridge = self.azaharBridge
            if backend == .nds {
                // Keep the two DS screens on the same emulation frame. The
                // threaded renderer can present one-frame-old 3D content over
                // the current 2D layer, which is especially visible as a
                // wavy/jelly effect in first-person games.
                azaharBridge.setCoreOptionValue("disabled", forKey: "melonds_threaded_renderer")
                let hdEnabled = runtimeConfiguration.renderMode == .hd
                // melonDS's iOS software renderer is fixed at the DS's native
                // 256x192 resolution. Use DeSmuME's supersampled rasterizer for
                // real HD geometry, while Original mode keeps melonDS accuracy.
                azaharBridge.setCoreOptionValue(hdEnabled ? "desmume" : "melonds", forKey: "duo_nds_core")
                // Two raster workers are enough for 2x on current iPhones and
                // avoid the heat and scheduler contention of four extra cores.
                azaharBridge.setCoreOptionValue("2", forKey: "desmume_num_cores")
                // 2x is already above the DS pixel grid while cutting 56% of
                // the raster and transfer work compared with 3x on iPhone.
                azaharBridge.setCoreOptionValue(hdEnabled ? "512x384" : "256x192", forKey: "desmume_internal_resolution")
                azaharBridge.setCoreOptionValue("enabled", forKey: "desmume_gfx_highres_interpolate_color")
                azaharBridge.setCoreOptionValue("1", forKey: "desmume_gfx_texture_scaling")
                azaharBridge.setCoreOptionValue("enabled", forKey: "desmume_gfx_texture_deposterize")
                azaharBridge.setCoreOptionValue("top/bottom", forKey: "desmume_screens_layout")
                azaharBridge.setCoreOptionValue("enabled", forKey: "desmume_pointer_mouse")
                azaharBridge.setCoreOptionValue("touch", forKey: "desmume_pointer_type")
                azaharBridge.setCoreOptionValue("16bit", forKey: "melonds_audio_bitdepth")
                azaharBridge.setCoreOptionValue("gaussian", forKey: "melonds_audio_interpolation")
                azaharBridge.setCoreOptionValue("disabled", forKey: "melonds_threaded_renderer")
            }
            if runtimeConfiguration.isPro {
                let preferences = runtimeConfiguration.preferences
                let integerScale = Int(max(1, min(3, preferences.resolutionScale)).rounded())
                azaharBridge.setCoreOptionValue(String(integerScale), forKey: "citra_resolution_factor")
                azaharBridge.setCoreOptionValue(preferences.performancePreset == .performance ? "hardware" : "software", forKey: "melonds_render_mode")
                #if targetEnvironment(simulator)
                // The simulator N64 binary has no executable-memory JIT. Selecting
                // a dynarec value leaves the core in an invalid hybrid mode.
                azaharBridge.setCoreOptionValue("cached_interpreter", forKey: "parallel-n64-cpucore")
                #else
                azaharBridge.setCoreOptionValue(preferences.performancePreset == .compatible ? "cached_interpreter" : "dynamic_recompiler", forKey: "parallel-n64-cpucore")
                #endif
            }
            try emulationQueue.sync {
                try azaharBridge.start(withROMURL: romURL,
                                       systemDirectory: systemDirectory,
                                       saveDirectory: saveDirectory)
            }
            azaharAudio.start(sampleRate: azaharBridge.sampleRate)
            loadedROMName = romURL.deletingPathExtension().lastPathComponent
            isRunning = true
            isPaused = false
            isAudioRunning = azaharAudio.isRunning
            performanceLog.info("3ds started audio=\(self.isAudioRunning, privacy: .public) saveDirectory=\(saveDirectory.path, privacy: .public)")
            frameTimer = makeFrameTimer()
            applyCheats()
        } catch {
            launchError = String(localized: "载入失败：\(error.localizedDescription)")
            loadedROMName = launchError
            backend = nil
        }
    }

    func saveSnapshot(name: String, automatic: Bool = false) {
        guard runtimeConfiguration.isPro, let gameURL = currentROMURL, isRunning else { return }
        let wasPaused = isPaused
        if !wasPaused { togglePause() }
        defer { if !wasPaused { togglePause() } }
        let bridge = azaharBridge
        let preview = topImage
        do {
            let data = try emulationQueue.sync { try bridge.serializeState() }
            _ = try DuoProStore.shared.saveSnapshot(data: data, preview: preview, gameURL: gameURL, name: name, automatic: automatic)
            proMessage = automatic ? nil : String(localized: "即时存档已创建")
        } catch { proMessage = error.localizedDescription }
    }

    func loadSnapshot(_ snapshot: DuoSnapshot) {
        guard runtimeConfiguration.isPro, let gameURL = currentROMURL, isRunning else { return }
        let wasPaused = isPaused
        if !wasPaused { togglePause() }
        defer { if !wasPaused { togglePause() } }
        do {
            let data = try DuoProStore.shared.stateData(for: snapshot, gameURL: gameURL)
            try emulationQueue.sync { try azaharBridge.loadStateData(data) }
            proMessage = String(localized: "已载入 \(snapshot.name)")
        } catch { proMessage = error.localizedDescription }
    }

    func applyCheats() {
        guard runtimeConfiguration.isPro, isRunning else { return }
        let cheats = runtimeConfiguration.preferences.cheats
        emulationQueue.async { [azaharBridge] in
            azaharBridge.resetCheats()
            for (index, cheat) in cheats.enumerated() where !cheat.code.isEmpty {
                azaharBridge.setCheatAt(UInt(index), enabled: cheat.enabled, code: cheat.code)
            }
        }
    }

    func playMacro(_ inputs: [String]) {
        guard runtimeConfiguration.isPro else { return }
        Task { @MainActor in
            for value in inputs {
                guard let raw = Int(value), let input = DuoInput(rawValue: raw) else { continue }
                press(input); try? await Task.sleep(for: .milliseconds(80)); release(input)
            }
        }
    }

    private func mapped(_ input: DuoInput) -> DuoInput {
        guard runtimeConfiguration.isPro,
              let value = runtimeConfiguration.preferences.buttonMapping[String(input.rawValue)],
              let raw = Int(value), let mapped = DuoInput(rawValue: raw) else { return input }
        return mapped
    }

    private func startTurbo(_ input: DuoInput) {
        let key = String(input.rawValue)
        guard turboTasks[key] == nil, let button = azaharButton(for: input) else { return }
        let core = azaharBridge
        turboTasks[key] = Task {
            var pressed = true
            while !Task.isCancelled {
                core.setButton(button, pressed: pressed)
                pressed.toggle()
                try? await Task.sleep(for: .milliseconds(55))
            }
            core.setButton(button, pressed: false)
        }
    }

    private func azaharButton(for input: DuoInput) -> AzaharButton? {
        switch input {
        case .b: return AzaharButton(rawValue: 0)
        case .y: return AzaharButton(rawValue: 1)
        case .select: return AzaharButton(rawValue: 2)
        case .start: return AzaharButton(rawValue: 3)
        case .up: return AzaharButton(rawValue: 4)
        case .down: return AzaharButton(rawValue: 5)
        case .left: return AzaharButton(rawValue: 6)
        case .right: return AzaharButton(rawValue: 7)
        case .a: return AzaharButton(rawValue: 8)
        case .x: return AzaharButton(rawValue: 9)
        case .l: return AzaharButton(rawValue: 10)
        case .r: return AzaharButton(rawValue: 11)
        default: return nil
        }
    }

    func setN64Button(_ code: Int, pressed: Bool) {
        guard backend == .n64, isRunning, !isPaused, let button = AzaharButton(rawValue: code) else { return }
        azaharBridge.setButton(button, pressed: pressed)
    }

    #if DEBUG
    func verifyPSPStateRoundTrip() {
        precondition(backend == .psp && isPaused)
        do {
            try emulationQueue.sync {
                let state = try azaharBridge.serializeState()
                precondition(!state.isEmpty)
                try azaharBridge.loadStateData(state)
            }
            print("DUO_PSP_GPU_STATE_PASS")
        } catch { preconditionFailure("PSP GPU state round trip: \(error)") }
    }
    #endif

    enum PS2Stick { case left, right }

    /// PS2 (DualShock 2) input by libretro joypad id: B=0 ×, Y=1 □, SELECT=2, START=3, UP…RIGHT=4…7,
    /// A=8 ○, X=9 △, L=10 L1, R=11 R1, L2=12, R2=13, L3=14, R3=15. No-op until a core is running.
    func setPS2Button(_ id: Int, pressed: Bool) {
        guard isRunning, (0..<16).contains(id), !(pressed && isPaused) else { return }
        azaharBridge.setJoypadID(UInt(id), pressed: pressed)
    }

    /// Analog values −1…1; +y is down (libretro convention).
    func setPS2Analog(stick: PS2Stick, x: Double, y: Double) {
        guard isRunning else { return }
        switch stick {
        case .left: azaharBridge.setCirclePadX(x, y: y)
        case .right: azaharBridge.setRightAnalogX(x, y: y)
        }
    }

    func setPSPButton(_ code: Int, pressed: Bool) {
        guard backend == .psp, isRunning, !isPaused, let button = AzaharButton(rawValue: code) else { return }
        azaharBridge.setButton(button, pressed: pressed)
    }

    private func processAzaharFrame(_ frame: Data, width: Int, height: Int, pitch: Int) {
        if backend == .n64 || backend == .psp {
            guard let pixels = tightlyPackedPixels(from: frame, sourcePitch: pitch,
                                                   x: 0, y: 0, width: width, height: height),
                  let image = makeXRGBImage(data: pixels, width: width, height: height) else { return }
            Task { @MainActor [weak self] in self?.topImage = image }
            return
        }
        if backend == .nds, width > 320 {
            guard width > 0, height >= 2, pitch >= width * 4,
                  let completeFrame = makeXRGBImage(data: frame, width: width, height: height, bytesPerRow: pitch) else { return }
            let halfHeight = height / 2
            guard let top = completeFrame.cropping(to: CGRect(x: 0, y: 0, width: width, height: halfHeight)),
                  let bottom = completeFrame.cropping(to: CGRect(x: 0, y: halfHeight, width: width, height: halfHeight)) else { return }
            Task { @MainActor [weak self] in
                self?.topImage = top
                self?.bottomImage = bottom
            }
            return
        }
        guard width > 0, height >= 2, pitch >= width * 4 else { return }
        let halfHeight = height / 2
        let bottomNativeWidth = backend == .nds ? width : min(320, width)
        let leftInset = max(0, (width - bottomNativeWidth) / 2)
        guard let topPixels = tightlyPackedPixels(from: frame, sourcePitch: pitch,
                                                  x: 0, y: 0, width: width, height: halfHeight),
              let bottomPixels = tightlyPackedPixels(from: frame, sourcePitch: pitch,
                                                     x: leftInset, y: halfHeight,
                                                     width: bottomNativeWidth, height: halfHeight) else { return }
        let dsScale = backend == .nds
            ? (runtimeConfiguration.renderMode == .hd ? 3.0 : 1.0)
            : 1.0
        if abs(cachedUpscaleScale - dsScale) > 0.001 { resetUpscaleCache() }
        cachedUpscaleScale = dsScale

        let topChanged = topPixels != lastTopNativeFrame || cachedTopUpscaled == nil
        let bottomChanged = bottomPixels != lastBottomNativeFrame || cachedBottomUpscaled == nil
        let top: CGImage?
        let bottom: CGImage?
        if topChanged {
            top = makeUpscaledXRGBImage(data: topPixels, width: width, height: halfHeight, scale: dsScale)
            lastTopNativeFrame = topPixels
            cachedTopUpscaled = top
        } else {
            top = cachedTopUpscaled
        }
        if bottomChanged {
            bottom = makeUpscaledXRGBImage(data: bottomPixels, width: bottomNativeWidth,
                                          height: halfHeight, scale: dsScale)
            lastBottomNativeFrame = bottomPixels
            cachedBottomUpscaled = bottom
        } else {
            bottom = cachedBottomUpscaled
        }
        guard let top, let bottom else { return }
        Task { @MainActor [weak self] in
            if topChanged { self?.topImage = top }
            if bottomChanged { self?.bottomImage = bottom }
        }
    }

    private func resetUpscaleCache() {
        lastTopNativeFrame = nil
        lastBottomNativeFrame = nil
        cachedTopUpscaled = nil
        cachedBottomUpscaled = nil
        cachedUpscaleScale = 0
    }

    private func tightlyPackedPixels(
        from frame: Data, sourcePitch: Int, x: Int, y: Int, width: Int, height: Int
    ) -> Data? {
        guard x >= 0, y >= 0, width > 0, height > 0,
              width <= Int.max / 4, sourcePitch >= width * 4 else { return nil }
        let rowBytes = width * 4
        guard x <= (sourcePitch - rowBytes) / 4,
              y <= Int.max / sourcePitch,
              height - 1 <= (Int.max - y * sourcePitch - x * 4 - rowBytes) / sourcePitch,
              (y + height - 1) * sourcePitch + x * 4 + rowBytes <= frame.count else { return nil }
        var pixels = Data(count: rowBytes * height)
        pixels.withUnsafeMutableBytes { destination in
            frame.withUnsafeBytes { source in
                guard let destinationBase = destination.baseAddress,
                      let sourceBase = source.baseAddress else { return }
                for row in 0..<height {
                    memcpy(destinationBase.advanced(by: row * rowBytes),
                           sourceBase.advanced(by: (y + row) * sourcePitch + x * 4),
                           rowBytes)
                }
            }
        }
        return pixels
    }

    private func makeXRGBImage(data: Data, width: Int, height: Int, bytesPerRow: Int? = nil, rgba: Bool = false) -> CGImage? {
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let bitmapInfo = rgba
            ? CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            : CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(width: width,
                       height: height,
                       bitsPerComponent: 8,
                       bitsPerPixel: 32,
                       bytesPerRow: bytesPerRow ?? width * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: bitmapInfo,
                       provider: provider,
                       decode: nil,
                       shouldInterpolate: false,
                       intent: .defaultIntent)
    }

    /// MetalFX spatially reconstructs edges into a real high-resolution frame.
    /// vImage remains a compatibility fallback for devices without MetalFX.
    private func makeUpscaledXRGBImage(data: Data, width: Int, height: Int, scale: Double) -> CGImage? {
        guard scale > 1.001 else { return makeXRGBImage(data: data, width: width, height: height) }
        if let (metalPixels, metalWidth, metalHeight) = DSMetalFXUpscaler.shared.upscale(
            data, width: width, height: height, scale: scale
        ) {
            return makeXRGBImage(data: metalPixels, width: metalWidth, height: metalHeight)
        }
        let outputWidth = max(1, Int((Double(width) * scale).rounded()))
        let outputHeight = max(1, Int((Double(height) * scale).rounded()))
        var output = Data(count: outputWidth * outputHeight * 4)
        let status: vImage_Error = data.withUnsafeBytes { sourceBytes in
            output.withUnsafeMutableBytes { destinationBytes in
                guard let source = sourceBytes.baseAddress,
                      let destination = destinationBytes.baseAddress else { return kvImageNullPointerArgument }
                var sourceBuffer = vImage_Buffer(
                    data: UnsafeMutableRawPointer(mutating: source),
                    height: vImagePixelCount(height),
                    width: vImagePixelCount(width),
                    rowBytes: width * 4
                )
                var destinationBuffer = vImage_Buffer(
                    data: destination,
                    height: vImagePixelCount(outputHeight),
                    width: vImagePixelCount(outputWidth),
                    rowBytes: outputWidth * 4
                )
                return vImageScale_ARGB8888(
                    &sourceBuffer,
                    &destinationBuffer,
                    nil,
                    vImage_Flags(kvImageHighQualityResampling | kvImageDoNotTile)
                )
            }
        }
        guard status == kvImageNoError else { return nil }

        return makeXRGBImage(data: output, width: outputWidth, height: outputHeight)
    }
}
