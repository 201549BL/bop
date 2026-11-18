import AppKit
import SwiftUI

struct BobbleheadPracticeView: View {
    private static let defaultModel: BobbleheadModel? = {
        guard let url = Bundle.main.url(forResource: "DeskBobblehead", withExtension: "usdz") else { return nil }
        return try? BobbleheadModel(url: url)
    }()

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragYaw = 0.0
    @State private var figureYaw = 0.0
    @State private var spinTask: Task<Void, Never>?
    @State private var tapWobble = 0.0
    @State private var wordmarkHit: BopWordmarkHit?

    let session: BopSession

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                toy.frame(width: min(geometry.size.width, 370))
                BopWordmark(hit: wordmarkHit, bounds: geometry.size, reduceMotion: reduceMotion)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .onDisappear(perform: stopSpinning)
        .onChange(of: reduceMotion) { _, enabled in
            if enabled { stopSpinning() }
        }
        // Practice responds to each matching nod in a rhythm.
        .onChange(of: session.rhythmPulse) { _, pulse in
            let facesLeft = BobbleheadCamera.facesLeft(
                yaw: figureYaw + dragYaw,
                isFullFigure: Self.defaultModel != nil
            )
            wordmarkHit = pulse.map { BopWordmarkHit(pulse: $0, appearsOnLeft: facesLeft) }
        }
    }

    private var toy: some View {
        let pitch = headAngle(-session.headPitch * 2.7, limit: 0.91)
        let roll = headAngle(-session.headRoll * 2.2 + tapWobble, limit: 0.84)
        let tiltScale = 1 / max(1, hypot(pitch / 0.91, roll / 0.84))

        return ZStack {
            // The figure mirrors the wearer around its own axes.
            BobbleheadToy(
                pitch: pitch * tiltScale,
                roll: roll * tiltScale,
                yaw: headAngle(-session.headYaw * 1.9, limit: 1.22),
                lift: bounded(session.verticalBounce * 0.65, limit: 0.15),
                model: Self.defaultModel,
                figureYaw: figureYaw + dragYaw
            )
            FigureDragSurface(
                onGrab: stopSpinning,
                onDrag: { dragYaw = spinAngle(for: $0) },
                onRelease: { width, velocity, isTap in
                    dragYaw = 0
                    if isTap {
                        wobble()
                    } else {
                        spinFigure(by: spinAngle(for: width))
                        coast(with: spinAngle(for: velocity))
                    }
                }
            )
            .help("Drag sideways to spin the figure.")
            .accessibilityElement()
            .accessibilityLabel("AirPods bobblehead")
            .accessibilityAddTraits(.isImage)
            .accessibilityAction(named: Text("Wobble"), wobble)
            .accessibilityAction(named: Text("Turn left")) { spinFigure(by: -.pi / 4) }
            .accessibilityAction(named: Text("Turn right")) { spinFigure(by: .pi / 4) }
        }
    }

    private func spinAngle(for dragWidth: CGFloat) -> Double {
        dragWidth * .pi / 180
    }

    private func spinFigure(by angle: Double) {
        stopSpinning()
        figureYaw = (figureYaw + angle).remainder(dividingBy: 2 * .pi)
    }

    private func coast(with velocity: Double) {
        guard !reduceMotion, abs(velocity) > 1 else { return }

        let speed = bounded(velocity, limit: 22)
        let friction = 3.6
        let initialYaw = figureYaw
        let duration = log(abs(speed) / 0.12) / friction
        spinTask = Task { @MainActor in
            let clock = ContinuousClock()
            let start = clock.now
            while !Task.isCancelled {
                let time = start.duration(to: clock.now).components
                let elapsed = Double(time.seconds) + Double(time.attoseconds) / 1e18
                figureYaw = initialYaw - speed * expm1(-friction * elapsed) / friction
                if elapsed >= duration { break }
                do {
                    try await clock.sleep(for: .milliseconds(16))
                } catch {
                    return
                }
            }
            spinTask = nil
        }
    }

    private func stopSpinning() {
        spinTask?.cancel()
        spinTask = nil
    }

    private var returnSpring: Animation? {
        reduceMotion ? nil : .spring(response: 0.49, dampingFraction: 0.25)
    }

    private func wobble() {
        guard !reduceMotion else { return }
        tapWobble = 0.29
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(55))
            withAnimation(returnSpring) { tapWobble = 0 }
        }
    }

    private func bounded(_ value: Double, limit: Double) -> Double {
        min(limit, max(-limit, value))
    }

    private func headAngle(_ angle: Double, limit: Double) -> Double {
        let knee = limit * 0.65
        let magnitude = abs(angle)
        guard magnitude > knee else { return angle }
        // Ease into the limit so the figure keeps following the motion near the end of its range.
        let range = limit - knee
        let softened = knee - range * expm1(-(magnitude - knee) / range)
        return angle < 0 ? -softened : softened
    }
}

private struct FigureDragSurface: NSViewRepresentable {
    let onGrab: () -> Void
    let onDrag: (CGFloat) -> Void
    let onRelease: (CGFloat, CGFloat, Bool) -> Void

    func makeNSView(context: Context) -> Surface { Surface() }

    func updateNSView(_ view: Surface, context: Context) {
        view.onGrab = onGrab
        view.onDrag = onDrag
        view.onRelease = onRelease
    }

    // Keep pointer tracking in AppKit alongside the SceneKit host view.
    final class Surface: NSView {
        var onGrab: (() -> Void)?
        var onDrag: ((CGFloat) -> Void)?
        var onRelease: ((CGFloat, CGFloat, Bool) -> Void)?
        private var start: NSPoint?
        private var recent: [(x: CGFloat, time: TimeInterval)] = []
        private var didDrag = false

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            start = event.locationInWindow
            recent = [(event.locationInWindow.x, event.timestamp)]
            didDrag = false
            onGrab?()
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start else { return }
            let point = event.locationInWindow
            let width = point.x - start.x
            recent.removeAll { event.timestamp - $0.time > 0.10 }
            recent.append((point.x, event.timestamp))
            didDrag = didDrag || abs(width) + abs(point.y - start.y) >= 3
            if didDrag { onDrag?(width) }
        }

        override func mouseUp(with event: NSEvent) {
            guard let start else { return }
            let point = event.locationInWindow
            let width = point.x - start.x
            let isTap = !didDrag && abs(width) + abs(point.y - start.y) < 3
            let velocity = releaseVelocity(at: event)
            self.start = nil
            onRelease?(width, velocity, isTap)
        }

        private func releaseVelocity(at event: NSEvent) -> CGFloat {
            guard let latest = recent.last, event.timestamp - latest.time < 0.06,
                  let earlier = recent.first(where: {
                      (0.012...0.10).contains(event.timestamp - $0.time)
                  })
            else { return 0 }
            return (event.locationInWindow.x - earlier.x) / (event.timestamp - earlier.time)
        }
    }
}

private struct BopWordmarkHit: Equatable {
    let pulse: BopRhythmPulse
    let appearsOnLeft: Bool
}

private struct BopWordmark: View {
    private struct AnimationValues {
        var phase = 0.0
        var spring = 0.0
    }

    let hit: BopWordmarkHit?
    let bounds: CGSize
    let reduceMotion: Bool

    var body: some View {
        let flight = Flight(hit: hit, bounds: bounds)
        Color.clear
            .keyframeAnimator(initialValue: AnimationValues(), trigger: hit) { _, values in
                let lettering = BopLettering(width: flight.letteringWidth)
                    .foregroundStyle(.primary)

                flight.place(lettering, at: values.phase, spring: values.spring, reduceMotion: reduceMotion)
                    .opacity(flight.opacity(at: values.phase))
            } keyframes: { _ in
                KeyframeTrack(\.phase) {
                    MoveKeyframe(0)
                    LinearKeyframe(1, duration: flight.duration)
                }
                KeyframeTrack(\.spring) {
                    MoveKeyframe(-0.55)
                    LinearKeyframe(1, duration: 0.27 * flight.duration, timingCurve: .easeOut)
                    LinearKeyframe(-0.32, duration: 0.19 * flight.duration, timingCurve: .easeInOut)
                    LinearKeyframe(0, duration: 0.18 * flight.duration, timingCurve: .easeOut)
                }
            }
            .opacity(hit == nil ? 0 : 1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private struct Flight {
        let letteringWidth: CGFloat
        let duration: Double
        let appearsOnLeft: Bool
        let start: CGPoint
        let end: CGPoint

        init(hit: BopWordmarkHit?, bounds: CGSize) {
            let strength: Double
            switch hit?.pulse.motion {
            case let .verticalBounce(peakAcceleration):
                strength = Self.unit((peakAcceleration - 0.08) / 0.28)
                duration = 0.18 + 0.44 * (hit?.pulse.period ?? 0.6)
            case let .rotation(angle, peakRate):
                strength = Self.unit((angle - 0.065) / 0.17)
                let speed = Self.unit((peakRate - 0.75) / 2.55)
                duration = 0.54 - 0.34 * speed
            case nil:
                strength = 0
                duration = 0.44
            }

            appearsOnLeft = hit?.appearsOnLeft ?? false
            let center = bounds.width / 2
            let direction = appearsOnLeft ? -1.0 : 1.0
            let offset = min(0.23 * bounds.height, 0.17 * bounds.width)
            let travel = min(34, 0.062 * bounds.width)
            start = CGPoint(
                x: center + direction * offset,
                y: 0.43 * bounds.height
            )
            end = CGPoint(
                x: start.x + direction * travel,
                y: start.y - 0.065 * bounds.height
            )
            // Leave space for the full word and its stretch at the end of the path.
            let availableWidth = max(0, center - offset - travel - 12)
            let maximumWidth = min(160, availableWidth / 1.2)
            let minimumWidth = min(70, maximumWidth)
            letteringWidth = minimumWidth + (maximumWidth - minimumWidth) * strength
        }

        func place(_ lettering: some View, at phase: Double, spring: Double, reduceMotion: Bool) -> some View {
            let glide = reduceMotion ? 0 : 1 - pow(1 - phase, 3)
            let scale = reduceMotion ? 1 : 0.86 + 0.14 * (1 - pow(1 - phase, 4))
            let deformation = reduceMotion ? 0 : spring
            return lettering
                .scaleEffect(
                    x: scale * (1 + 0.20 * deformation),
                    y: scale * (1 - 0.15 * deformation),
                    anchor: appearsOnLeft ? .trailing : .leading
                )
                .frame(width: 0, height: 0, alignment: appearsOnLeft ? .trailing : .leading)
                .position(
                    x: start.x + (end.x - start.x) * glide,
                    y: start.y + (end.y - start.y) * glide
                )
        }

        func opacity(at phase: Double) -> Double {
            let appear = UnitCurve.easeOut.value(at: min(1, phase / 0.08))
            let fade = UnitCurve.easeInOut.value(at: max(0, (phase - 0.40) / 0.60))
            return appear * (1 - fade)
        }

        private static func unit(_ value: Double) -> Double {
            min(1, max(0, value))
        }
    }
}

struct BopLettering: View {
    let width: CGFloat

    var body: some View {
        // Frame the lettering within the square icon and use its brightness as the mask.
        let iconSize = width / 0.9
        Rectangle()
            .fill(.foreground)
            .frame(width: width, height: iconSize * 0.52)
            .mask {
                Image(.bopLettering)
                    .resizable()
                    .frame(width: iconSize, height: iconSize)
                    .contrast(1.1)
                    .luminanceToAlpha()
            }
    }
}
