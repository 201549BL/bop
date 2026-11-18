import Foundation

public struct BopEvent: Sendable {
    public let startedAt: Double
    public let detectedAt: Double
    let cycleStarts: [Double]

    init(cycleStarts: [Double], detectedAt: Double) {
        self.cycleStarts = cycleStarts
        startedAt = cycleStarts[0]
        self.detectedAt = detectedAt
    }
}

public struct BopRhythmicRotation: Sendable {
    /// Timestamp of the first stroke, shared by its rebound and completed cycle.
    public let startedAt: Double
    /// Excursion vector in radians, signed toward the first stroke of the cycle.
    public let excursion: SIMD3<Double>
    /// Angular excursion in radians. A rebound reports the first stroke, and a completed cycle averages both.
    public let angle: Double
    /// Estimated seconds per cycle.
    public let period: Double
    /// Peak angular speed in radians per second over the strokes measured so far.
    public let peakRate: Double
}

public struct DetectionUpdate: Sendable {
    public let sample: MotionSample
    public let smoothedNodRate: Double
    public let segmentID: Int
    public let didNod: Bool
    /// Mean angular excursion of the two strokes, in radians, on a rhythmic nod.
    public var rhythmicNodAngle: Double? { rhythmicRotation?.angle }
    /// A completed nod that fits the current rhythm.
    public var isRhythmicNod: Bool { rhythmicNodAngle != nil }
    public let bop: BopEvent?
    let rhythmicRotation: BopRhythmicRotation?
    let rotationRebound: BopRhythmicRotation?
    let smoothedRotation: SIMD3<Double>
    let streamSegmentID: Int
}

public struct BopDetector: Sendable {
    static let defaultSensitivity = 1.0
    private static let smoothingTimeConstant = 0.05
    private static let maximumSampleGap = 0.25
    private static let strokeStartRate = 0.28
    private static let strokeEndRate = 0.16
    private static let minimumStrokeAngle = 0.022
    private static let minimumOpposingAlignment = 0.75
    private static let maximumReversalInterval = 0.5
    private static let nodIntervals = 0.3...1.1
    private static let maximumIntervalRatio = 1.3
    private static let rearmDelay = 1.3
    private static let rotationPeriods = 0.3...1.4
    private static let maximumRotationStrokeDuration = 0.78
    private static let maximumTurnaroundPause = 0.24

    enum Signal: Sendable {
        case rotation, acceleration
    }

    public let axis: RotationAxis?

    private let signal: Signal
    private var sensitivity: Double
    private var lastSample: MotionSample?
    private var segmentID = 0
    private var streamSegmentID = 0
    private var smoothedRotation: SIMD3<Double> = .zero
    private var chartDirection: SIMD3<Double> = RotationAxis.x.unitVector
    private var activeStroke: Stroke?
    private var pendingStroke: Stroke?
    private var recentNods: [Nod] = []
    private var lastNodCompletedAt: Double?
    private var reportedBop = false
    private var reboundStartedAt: Double?

    var sequenceProgress: Int {
        if reportedBop { return 2 }
        return recentNods.isEmpty ? 0 : 1
    }

    public init(axis: RotationAxis? = nil) {
        self.init(axis: axis, sensitivity: Self.defaultSensitivity)
    }

    init(axis: RotationAxis?, sensitivity: Double, signal: Signal = .rotation) {
        self.axis = axis
        self.sensitivity = sensitivity
        self.signal = signal
        if let axis { chartDirection = axis.unitVector }
    }

    public mutating func ingest(_ sample: MotionSample) -> DetectionUpdate? {
        guard sample.timestamp.isFinite, sample.rotationRate.x.isFinite,
              sample.rotationRate.y.isFinite, sample.rotationRate.z.isFinite
        else { return nil }

        if let lastSample {
            let elapsed = sample.timestamp - lastSample.timestamp
            guard elapsed > 0 else { return nil }
            if elapsed > Self.maximumSampleGap || sample.source != lastSample.source {
                reset()
            }
        }

        let elapsed = lastSample.map { sample.timestamp - $0.timestamp } ?? 0
        lastSample = sample
        let weight = -expm1(-elapsed / Self.smoothingTimeConstant)
        let rotation = axis.map { $0.unitVector * sample.rotationRate } ?? sample.rotationRate
        smoothedRotation += weight * (rotation - smoothedRotation)

        let rearmDelay = signal == .rotation ? 1.55 : Self.rearmDelay
        if let lastNodCompletedAt, sample.timestamp - lastNodCompletedAt >= rearmDelay {
            recentNods.removeAll(keepingCapacity: true)
            self.lastNodCompletedAt = nil
            reportedBop = false
        }

        let impact = observeImpact(at: sample.timestamp, elapsed: elapsed, rotation: rotation)
        let nod = observeStroke(at: sample.timestamp, elapsed: elapsed, rotation: rotation)
        let recognition = nod.map { registerNod($0, completedAt: sample.timestamp) }
        let rebound = impact ?? observeRebound()
        return DetectionUpdate(
            sample: sample,
            smoothedNodRate: (chartDirection * smoothedRotation).sum(),
            segmentID: segmentID,
            didNod: nod != nil,
            bop: recognition?.bop,
            rhythmicRotation: recognition?.motion,
            rotationRebound: rebound,
            smoothedRotation: smoothedRotation,
            streamSegmentID: streamSegmentID
        )
    }

    public mutating func reset() {
        let nextSegmentID = segmentID + 1
        let nextStreamSegmentID = streamSegmentID + 1
        self = BopDetector(axis: axis, sensitivity: sensitivity, signal: signal)
        segmentID = nextSegmentID
        streamSegmentID = nextStreamSegmentID
    }

    mutating func setSensitivity(_ sensitivity: Double) {
        guard self.sensitivity != sensitivity else { return }
        self.sensitivity = sensitivity
        activeStroke = nil
        pendingStroke = nil
        recentNods.removeAll(keepingCapacity: true)
        lastNodCompletedAt = nil
        reportedBop = false
        reboundStartedAt = nil
    }

    static func strokeRateThresholds(sensitivity: Double) -> (start: Double, end: Double) {
        (strokeStartRate / sensitivity, strokeEndRate / sensitivity)
    }

    private var rateThresholds: (start: Double, end: Double) {
        if signal == .rotation { return (0.18 / sensitivity, 0.10 / sensitivity) }
        return Self.strokeRateThresholds(sensitivity: sensitivity)
    }

    private var minimumStrokeAngle: Double {
        (signal == .rotation ? 0.029 : Self.minimumStrokeAngle) / sensitivity
    }

    private var maximumReversalInterval: Double {
        signal == .rotation ? Self.maximumRotationStrokeDuration : Self.maximumReversalInterval
    }

    private mutating func observeStroke(
        at timestamp: Double,
        elapsed: Double,
        rotation: SIMD3<Double>
    ) -> Nod? {
        let (startRate, endRate) = rateThresholds
        var nod: Nod?

        if var stroke = activeStroke {
            let alignedRate = (stroke.direction * smoothedRotation).sum()
            if alignedRate >= endRate {
                stroke.angle += alignedRate * elapsed
                stroke.lastMovingAt = timestamp
                let rawAlignedRate = (stroke.direction * rotation).sum()
                stroke.isSlowing = rawAlignedRate < stroke.lastRawRate
                stroke.lastRawRate = rawAlignedRate
                if rawAlignedRate > stroke.peakRate {
                    stroke.peakRate = rawAlignedRate
                    stroke.peakAt = timestamp
                }
                if rawAlignedRate >= startRate {
                    stroke.supportingSamples += 1
                }
                activeStroke = stroke
                return nil
            }

            activeStroke = nil
            // Smoothing can spread a single raw spike across several samples.
            if stroke.angle >= minimumStrokeAngle, stroke.supportingSamples >= 2,
               signal == .acceleration || stroke.lastMovingAt - stroke.startedAt <= Self.maximumRotationStrokeDuration {
                nod = finishStroke(stroke)
            }
        }

        let speed = sqrt((smoothedRotation * smoothedRotation).sum())
        if speed >= startRate {
            let direction = smoothedRotation / speed
            let rawAlignedRate = (direction * rotation).sum()
            activeStroke = Stroke(
                direction: direction,
                startedAt: timestamp,
                lastMovingAt: timestamp,
                peakAt: timestamp,
                supportingSamples: rawAlignedRate >= startRate ? 1 : 0,
                peakRate: max(0, rawAlignedRate),
                lastRawRate: rawAlignedRate
            )
            updateChartDirection(direction)
        }

        return nod
    }

    private mutating func finishStroke(_ stroke: Stroke) -> Nod? {
        // Starting with either direction lets the detector use either AirPod and
        // begin partway through a sequence without depending on the axis sign.
        if let pendingStroke, formsCycle(outward: pendingStroke, returning: stroke) {
            self.pendingStroke = nil
            return Nod(outward: pendingStroke, returning: stroke)
        }

        pendingStroke = stroke
        return nil
    }

    private mutating func observeRebound() -> BopRhythmicRotation? {
        guard let outward = pendingStroke, let returning = activeStroke,
              returning.supportingSamples >= 2, reboundStartedAt != outward.startedAt,
              formsCycle(outward: outward, returning: returning),
              let period = rhythmicPeriod(to: outward.startedAt)
        else { return nil }

        return rebound(for: outward, angle: outward.angle, period: period)
    }

    private mutating func observeImpact(
        at timestamp: Double,
        elapsed: Double,
        rotation: SIMD3<Double>
    ) -> BopRhythmicRotation? {
        guard let outward = activeStroke, outward.isSlowing,
              reboundStartedAt != outward.startedAt, outward.supportingSamples >= 2,
              outward.angle >= minimumStrokeAngle,
              timestamp - outward.startedAt <= maximumReversalInterval,
              let period = rhythmicPeriod(to: outward.startedAt)
        else { return nil }

        let returnRate = -(outward.direction * rotation).sum()
        let speed = sqrt((rotation * rotation).sum())
        // Require a slowdown followed by aligned motion in the opposite direction.
        guard (0...(0.55 * outward.peakRate)).contains(outward.lastRawRate),
              returnRate >= max(0.035, 0.06 * outward.peakRate),
              returnRate <= outward.peakRate,
              returnRate >= Self.minimumOpposingAlignment * speed
        else { return nil }

        // Include this sample's remaining outward motion if the filtered stroke is still active.
        let alignedRate = (outward.direction * smoothedRotation).sum()
        let endRate = rateThresholds.end
        let angle = alignedRate >= endRate ? outward.angle + elapsed * alignedRate : outward.angle
        return rebound(for: outward, angle: angle, period: period)
    }

    private mutating func rebound(for outward: Stroke, angle: Double, period: Double) -> BopRhythmicRotation {
        reboundStartedAt = outward.startedAt
        return BopRhythmicRotation(
            startedAt: outward.startedAt,
            excursion: outward.direction * angle,
            angle: angle,
            period: period,
            peakRate: outward.peakRate
        )
    }

    private func formsCycle(outward: Stroke, returning: Stroke) -> Bool {
        (outward.direction * returning.direction).sum() <= -Self.minimumOpposingAlignment
            && returning.startedAt - outward.startedAt <= maximumReversalInterval
            && (signal == .acceleration || returning.startedAt - outward.lastMovingAt <= Self.maximumTurnaroundPause)
    }

    private mutating func updateChartDirection(_ direction: SIMD3<Double>) {
        let alignment = (chartDirection * direction).sum()
        if abs(alignment) < Self.minimumOpposingAlignment {
            // Split the trace when its projection changes so the line cannot jump.
            chartDirection = alignment < 0 ? -direction : direction
            segmentID += 1
        }
    }

    private mutating func registerNod(_ nod: Nod, completedAt: Double) -> (bop: BopEvent?, motion: BopRhythmicRotation?) {
        lastNodCompletedAt = completedAt
        defer {
            if recentNods.count == 2 { recentNods.removeFirst() }
            recentNods.append(nod)
        }

        let period: Double
        let cycleStarts: [Double]
        if signal == .rotation, let previous = recentNods.last,
           let repeatedPeriod = nod.repeatedPeriod(after: previous) {
            period = repeatedPeriod
            cycleStarts = [previous.startedAt, nod.startedAt]
        } else if let establishedPeriod = rhythmicPeriod(to: nod.startedAt) {
            period = establishedPeriod
            cycleStarts = recentNods.map(\.startedAt) + [nod.startedAt]
        } else {
            return (nil, nil)
        }

        let motion = BopRhythmicRotation(
            startedAt: nod.startedAt,
            excursion: nod.excursion,
            angle: nod.angle,
            period: period,
            peakRate: nod.peakRate
        )
        guard !reportedBop else { return (nil, motion) }
        reportedBop = true
        return (BopEvent(cycleStarts: cycleStarts, detectedAt: completedAt), motion)
    }

    private func rhythmicPeriod(to startedAt: Double) -> Double? {
        guard recentNods.count == 2 else { return nil }
        let firstInterval = recentNods[1].startedAt - recentNods[0].startedAt
        let secondInterval = startedAt - recentNods[1].startedAt
        let intervals = signal == .rotation ? Self.rotationPeriods : Self.nodIntervals
        guard intervals.contains(firstInterval), intervals.contains(secondInterval),
              max(firstInterval, secondInterval) <= Self.maximumIntervalRatio * min(firstInterval, secondInterval)
        else { return nil }
        return secondInterval
    }

    private struct Nod {
        let outward: Stroke
        let returning: Stroke

        var startedAt: Double { outward.startedAt }
        var excursion: SIMD3<Double> { (outward.direction * outward.angle - returning.direction * returning.angle) / 2 }
        var angle: Double { (outward.angle + returning.angle) / 2 }
        var peakRate: Double { max(outward.peakRate, returning.peakRate) }

        private var returnsTowardStart: Bool {
            min(outward.angle, returning.angle) >= 0.25 * max(outward.angle, returning.angle)
        }

        func repeatedPeriod(after previous: Nod) -> Double? {
            let outwardPeriod = outward.peakAt - previous.outward.peakAt
            let returnPeriod = returning.peakAt - previous.returning.peakAt
            let period = (outwardPeriod + returnPeriod) / 2
            // Require a substantial return within each nod. Compare timing and direction across nods.
            guard returnsTowardStart, previous.returnsTowardStart, BopDetector.rotationPeriods.contains(period),
                  abs(outwardPeriod - returnPeriod) <= 0.25 * period,
                  (outward.direction * previous.outward.direction).sum() >= BopDetector.minimumOpposingAlignment,
                  (returning.direction * previous.returning.direction).sum() >= BopDetector.minimumOpposingAlignment
            else { return nil }
            return period
        }
    }

    private struct Stroke {
        let direction: SIMD3<Double>
        let startedAt: Double
        var lastMovingAt: Double
        var peakAt: Double
        var supportingSamples: Int
        var peakRate: Double
        var lastRawRate: Double
        var isSlowing = false
        var angle = 0.0
    }
}
