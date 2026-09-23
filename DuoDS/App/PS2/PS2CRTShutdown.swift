import SwiftUI

/// Drives the old-CRT power-off effect on the PS2 game screen (top screen only):
/// the picture squashes into a bright horizontal line, the line shrinks to a dot, the dot fades.
@MainActor
final class PS2CRTShutdownController: ObservableObject {
    nonisolated static let squashDuration = 0.18
    nonisolated static let shrinkDuration = 0.12
    nonisolated static let fadeDuration = 0.15
    nonisolated static var totalDuration: Double { squashDuration + shrinkDuration + fadeDuration }

    @Published fileprivate(set) var startDate: Date?
    /// True once the effect has finished; the screen stays black until `reset()`.
    @Published private(set) var isOff = false
    var isPlaying: Bool { startDate != nil }
    #if DEBUG
    /// Freezes the effect at a fixed elapsed time (screenshots / previews).
    @Published var debugElapsed: Double?
    #endif
    private var task: Task<Void, Never>?

    func play(completion: (() -> Void)? = nil) {
        task?.cancel()
        isOff = false
        startDate = Date()
        task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.totalDuration))
            guard let self, !Task.isCancelled else { return }
            self.isOff = true
            self.startDate = nil
            completion?()
        }
    }

    func reset() {
        task?.cancel()
        task = nil
        startDate = nil
        isOff = false
    }
}

/// Pure timing curve of the effect, so every frame is a function of elapsed time.
struct PS2CRTShutdownState {
    var imageScaleY: CGFloat = 1
    var imageBrightness: Double = 0
    var whiteness: Double = 0
    var imageOpacity: Double = 1
    var beamWidthFraction: CGFloat = 1
    var beamHeight: CGFloat = 0
    var beamOpacity: Double = 0
    var glow: Double = 0

    init(elapsed t: Double) {
        let a = PS2CRTShutdownController.squashDuration
        let b = a + PS2CRTShutdownController.shrinkDuration
        let c = b + PS2CRTShutdownController.fadeDuration
        guard t >= 0 else { return }
        if t < a {
            let p = t / a
            let eased = p * p * p
            imageScaleY = max(0.006, 1 - CGFloat(eased))
            imageBrightness = 0.45 * p
            whiteness = pow(p, 1.4)
            // The line itself starts glowing in the last third of the squash.
            let late = max(0, (p - 0.66) / 0.34)
            beamOpacity = late
            beamHeight = 2.5
            glow = 0.6 * late
            return
        }
        imageOpacity = 0
        imageScaleY = 0.006
        if t < b {
            let q = (t - a) / (b - a)
            beamWidthFraction = max(0, 1 - CGFloat(q * q))
            beamHeight = 2.5 + 1.5 * CGFloat(q)
            beamOpacity = 1
            glow = 0.6 + 0.4 * q
            return
        }
        beamWidthFraction = 0
        if t < c {
            let r = (t - b) / (c - b)
            beamHeight = 4 * CGFloat(1 - 0.4 * r)
            beamOpacity = 1 - r
            glow = 1 - r
            return
        }
        beamHeight = 0
        beamOpacity = 0
        glow = 0
    }
}

struct PS2CRTShutdownModifier: ViewModifier {
    @ObservedObject var controller: PS2CRTShutdownController

    func body(content: Content) -> some View {
        TimelineView(.animation(paused: !controller.isPlaying)) { timeline in
            let state = PS2CRTShutdownState(elapsed: elapsed(at: timeline.date))
            GeometryReader { proxy in
                ZStack {
                    Color.black
                    content
                        .overlay(Color.white.opacity(state.whiteness))
                        .brightness(state.imageBrightness)
                        .scaleEffect(x: 1, y: state.imageScaleY, anchor: .center)
                        .opacity(state.imageOpacity)
                    beam(state, width: proxy.size.width)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
            .clipped()
        }
    }

    private func elapsed(at date: Date) -> Double {
        #if DEBUG
        if let frozen = controller.debugElapsed { return frozen }
        #endif
        if let start = controller.startDate { return date.timeIntervalSince(start) }
        return controller.isOff ? .infinity : -1
    }

    @ViewBuilder
    private func beam(_ state: PS2CRTShutdownState, width: CGFloat) -> some View {
        if state.beamOpacity > 0 {
            // A dot is never narrower than the beam is tall.
            let length = max(state.beamHeight, width * state.beamWidthFraction)
            ZStack {
                Capsule()
                    .fill(Color(red: 0.75, green: 0.85, blue: 1))
                    .frame(width: length * 1.04 + 18, height: state.beamHeight * 9)
                    .blur(radius: 14)
                    .opacity(0.35 * state.glow)
                Capsule()
                    .fill(Color.white)
                    .frame(width: length + 6, height: state.beamHeight * 3.5)
                    .blur(radius: 5)
                    .opacity(0.75 * state.glow)
                Capsule()
                    .fill(Color.white)
                    .frame(width: length, height: state.beamHeight)
            }
            .opacity(state.beamOpacity)
            .blendMode(.plusLighter)
            .allowsHitTesting(false)
        }
    }
}

extension View {
    /// Applies the CRT power-off effect; call `controller.play(completion:)` to run it.
    func ps2CRTShutdown(_ controller: PS2CRTShutdownController) -> some View {
        modifier(PS2CRTShutdownModifier(controller: controller))
    }
}
