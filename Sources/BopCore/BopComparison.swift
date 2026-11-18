import Foundation
import simd

public enum ComparisonSignal: String, CaseIterable, Sendable {
    case rotation, orientation, verticalAcceleration
}

public enum RotationDetectionMethod: String, CaseIterable, Sendable {
    case nodRhythm, autocorrelation
}

public struct BopSignalPoint: Sendable {
    public let value: Double
    public let segmentID: Int
    public let didCycle: Bool
    public var didBop: Bool { bop != nil }

    fileprivate let bop: BopEvent?
}

public struct BopRotationTrace: Sendable {
    /// Identifies uninterrupted rotation samples across all three axes.
    public let segmentID: Int
    fileprivate let rate: SIMD3<Double>

    /// Smoothed signed rotation rate about the selected axis, in radians per second.
    public subscript(_ axis: RotationAxis) -> Double {
        switch axis {
        case .x: rate.x
        case .y: rate.y
        case .z: rate.z
        }
    }
}

public struct BopRhythmicVerticalBounce: Sendable {
    /// Peak gravity-free vertical acceleration in either direction, in g.
    public let peakAcceleration: Double
    /// Seconds between the start of this cycle and the start of the preceding cycle.
    public let period: Double
}

public struct BopSignalFrame: Sendable {
    public let timestamp: Double
    public let rotationTrace: BopRotationTrace?
    public let rhythmicRotation: BopRhythmicRotation?
    /// An apparent rhythmic rotation cycle at its turnaround, before its return is confirmed.
    public let rotationRebound: BopRhythmicRotation?
    public let rhythmicVerticalBounce: BopRhythmicVerticalBounce?
    /// Gravity-free acceleration along gravity for the current sample, in g.
    public let instantaneousVerticalAcceleration: Double?
    /// Mean angular excursion of the two rotation strokes, in radians, on a rhythmic nod.
    public var rhythmicNodAngle: Double? { rhythmicRotation?.angle }
    /// A completed rotation nod that fits the current rhythm.
    public var isRhythmicNod: Bool { rhythmicNodAngle != nil }
    fileprivate let rotation: BopSignalPoint?
    fileprivate let orientation: BopSignalPoint?
    fileprivate let acceleration: BopSignalPoint?
    fileprivate let nodRhythmBop: BopEvent?
    fileprivate let autocorrelationBop: BopEvent?

    public subscript(_ signal: ComparisonSignal) -> BopSignalPoint? {
        switch signal {
        case .rotation: rotation
        case .orientation: orientation
        case .verticalAcceleration: acceleration
        }
    }
}

public struct BopSignalDetector: Sendable {
    public static let sensitivityRange = 0.5...5.0
    public static let defaultSensitivity = BopDetector.defaultSensitivity
    private static let accelerationScale = 4.0

    private var rotation: RateSignal
    private var rotationAutocorrelation: RotationAutocorrelation
    private var nodRhythm: NodRhythmDetector
    private var orientation: OrientationPattern
    private var acceleration: RateSignal
    private var previousTimestamp: Double?
    private let rotationMethod: RotationDetectionMethod

    public init(
        rotationAxis: RotationAxis? = nil,
        sensitivities: [ComparisonSignal: Double] = [:],
        calibratesBobbleheadOnStartup: Bool = false,
        rotationMethod: RotationDetectionMethod = .autocorrelation
    ) {
        self.init(
            rotationAxis: rotationAxis, sensitivities: sensitivities, evidenceMultiplier: 1,
            calibratesBobbleheadOnStartup: calibratesBobbleheadOnStartup, rotationMethod: rotationMethod
        )
    }

    /// Rotation sequence progress from 0 (idle) to 1 (candidate) to 2 (detected).
    public var rotationSequenceProgress: Int {
        if rotationMethod == .nodRhythm { return nodRhythm.sequenceProgress }
        if rotationAutocorrelation.hasDetectedBop { return 2 }
        return min(rotation.detector.sequenceProgress, 1)
    }

    /// Signed rotation vector in radians, relative to the stream's initial orientation.
    public var relativeHeadAttitude: SIMD3<Double> { orientation.relativeAttitude }

    /// Signed rotation in radians from the bobblehead's neutral pose, if orientation is available.
    public var bobbleheadAttitude: SIMD3<Double>? { orientation.bobbleheadAttitude }

    /// Uses the latest orientation as the bobblehead's neutral pose.
    public mutating func recenterBobblehead() {
        orientation.recenterBobblehead()
    }

    fileprivate init(
        rotationAxis: RotationAxis?,
        sensitivities: [ComparisonSignal: Double],
        evidenceMultiplier: Double,
        calibratesBobbleheadOnStartup: Bool = false,
        rotationMethod: RotationDetectionMethod
    ) {
        func effectiveSensitivity(_ signal: ComparisonSignal) -> Double {
            Self.clampedSensitivity(sensitivities[signal]) * evidenceMultiplier
        }
        self.rotationMethod = rotationMethod
        let rotationSensitivity = effectiveSensitivity(.rotation)
        rotation = RateSignal(axis: rotationAxis, sensitivity: rotationSensitivity)
        rotationAutocorrelation = RotationAutocorrelation(axis: rotationAxis, sensitivity: rotationSensitivity)
        nodRhythm = NodRhythmDetector(axis: rotationAxis, sensitivity: rotationSensitivity)
        orientation = OrientationPattern(
            sensitivity: effectiveSensitivity(.orientation),
            calibratesBobbleheadOnStartup: calibratesBobbleheadOnStartup
        )
        acceleration = RateSignal(axis: .x, sensitivity: effectiveSensitivity(.verticalAcceleration), signal: .acceleration)
    }

    /// Start and release magnitudes, in g, for either direction of the smoothed vertical signal.
    public static func verticalAccelerationThresholds(sensitivity: Double) -> (start: Double, end: Double) {
        let thresholds = BopDetector.strokeRateThresholds(sensitivity: clampedSensitivity(sensitivity))
        return (thresholds.start / accelerationScale, thresholds.end / accelerationScale)
    }

    public mutating func ingest(_ sample: MotionSample) -> BopSignalFrame? {
        let timestamp = sample.timestamp
        guard timestamp.isFinite, previousTimestamp.map({ timestamp > $0 }) ?? true else { return nil }
        previousTimestamp = timestamp

        let rotationUpdate = rotation.ingest(sample)
        let autocorrelationBop = rotationUpdate.flatMap { rotationAutocorrelation.ingest($0) }
        let repeatingRotation = rotationAutocorrelation.hasRecentMatch(at: timestamp)
        let nodResult = rotationUpdate.map { nodRhythm.ingest($0, repeatingRotation: repeatingRotation) }
        let usesNodRhythm = rotationMethod == .nodRhythm
        let rotationPoint = rotationUpdate.map { update in
            BopSignalPoint(
                value: update.smoothedNodRate,
                segmentID: update.segmentID,
                didCycle: usesNodRhythm ? nodResult?.didNod == true : update.didNod,
                bop: usesNodRhythm ? nodResult?.bop : autocorrelationBop
            )
        }
        let orientationPoint = orientation.ingest(
            sample.attitude.flatMap(Self.unitQuaternion),
            sample: sample
        )
        // Scale g to the pattern detector's input range, then restore the chart's units.
        let vertical = Self.verticalAcceleration(sample)
        let projectedSample = vertical.map { vertical in
            MotionSample(timestamp: timestamp, rotationRate: SIMD3(Self.accelerationScale * vertical, 0, 0), source: sample.source)
        }
        let accelerationUpdate = acceleration.ingest(projectedSample)
        let accelerationPoint = accelerationUpdate.map {
            Self.point(from: $0, valueDivisor: Self.accelerationScale)
        }
        let rotationTrace = rotationUpdate.map {
            BopRotationTrace(segmentID: $0.streamSegmentID, rate: $0.smoothedRotation)
        }

        guard rotationPoint != nil || orientationPoint != nil || accelerationPoint != nil else { return nil }
        return BopSignalFrame(
            timestamp: timestamp,
            rotationTrace: rotationTrace,
            rhythmicRotation: usesNodRhythm ? nodResult?.rhythmicRotation : rotationUpdate?.rhythmicRotation,
            rotationRebound: usesNodRhythm ? nodResult?.turnaround : rotationUpdate?.rotationRebound,
            rhythmicVerticalBounce: accelerationUpdate?.rhythmicRotation.map {
                BopRhythmicVerticalBounce(peakAcceleration: $0.peakRate / Self.accelerationScale, period: $0.period)
            },
            instantaneousVerticalAcceleration: vertical,
            rotation: rotationPoint,
            orientation: orientationPoint,
            acceleration: accelerationPoint,
            nodRhythmBop: nodResult?.bop,
            autocorrelationBop: autocorrelationBop
        )
    }

    public mutating func reset() {
        resetRotation()
        orientation.reset()
        acceleration.reset()
        previousTimestamp = nil
    }

    /// Starts a new rotation sequence while keeping the other signals continuous.
    public mutating func resetRotation() {
        rotation.reset()
        rotationAutocorrelation.reset()
        nodRhythm.reset()
    }

    /// Changes one signal's motion thresholds and clears its in-progress detection.
    public mutating func setSensitivity(_ sensitivity: Double, for signal: ComparisonSignal) {
        let sensitivity = Self.clampedSensitivity(sensitivity)
        switch signal {
        case .rotation:
            rotation.detector.setSensitivity(sensitivity)
            rotationAutocorrelation.setSensitivity(sensitivity)
            nodRhythm.setSensitivity(sensitivity)
        case .orientation: orientation.setSensitivity(sensitivity)
        case .verticalAcceleration: acceleration.detector.setSensitivity(sensitivity)
        }
    }

    fileprivate static func clampedSensitivity(_ sensitivity: Double?) -> Double {
        guard let sensitivity, sensitivity.isFinite else { return defaultSensitivity }
        return min(max(sensitivity, sensitivityRange.lowerBound), sensitivityRange.upperBound)
    }

    private static func point(from update: DetectionUpdate, valueDivisor: Double = 1) -> BopSignalPoint {
        BopSignalPoint(
            value: update.smoothedNodRate / valueDivisor,
            segmentID: update.segmentID,
            didCycle: update.didNod,
            bop: update.bop
        )
    }

    private static func unitQuaternion(_ vector: SIMD4<Double>) -> simd_quatd? {
        let length = simd_length(vector)
        guard length.isFinite, length > 1e-6 else { return nil }
        return simd_quatd(vector: vector / length)
    }

    private static func verticalAcceleration(_ sample: MotionSample) -> Double? {
        guard let acceleration = sample.userAcceleration, let gravity = sample.gravity else { return nil }
        let gravityMagnitude = simd_length(gravity)
        guard gravityMagnitude.isFinite, gravityMagnitude > 1e-6 else { return nil }
        let projected = simd_dot(acceleration, gravity / gravityMagnitude)
        guard projected.isFinite else { return nil }
        return projected
    }

    private struct RateSignal: Sendable {
        var detector: BopDetector
        var wasAvailable = false

        init(axis: RotationAxis?, sensitivity: Double, signal: BopDetector.Signal = .rotation) {
            detector = BopDetector(axis: axis, sensitivity: sensitivity, signal: signal)
        }

        mutating func ingest(_ sample: MotionSample?) -> DetectionUpdate? {
            guard let sample, let update = detector.ingest(sample) else {
                if wasAvailable { reset() }
                return nil
            }
            wasAvailable = true
            return update
        }

        mutating func reset() {
            detector.reset()
            wasAvailable = false
        }
    }
}

public struct BopComparisonResult: Sendable {
    public struct SignalResult: Sendable {
        public let signal: ComparisonSignal
        public let detectionTimes: [Double]
        public let hasData: Bool
        public let sensitivity: Double
    }

    public struct CombinedResult: Sendable {
        public let detectionTimes: [Double]
        public let hasData: Bool
    }

    public let duration: Double
    public let signals: [SignalResult]
    public let combined: CombinedResult
    public let rotationDetectionTimes: [RotationDetectionMethod: [Double]]
}

public enum BopComparison {
    private static let evidenceMultiplier = 1.5

    public static func analyze(
        _ samples: [MotionSample],
        rotationAxis: RotationAxis? = nil,
        sensitivities: [ComparisonSignal: Double] = [:],
        rotationMethod: RotationDetectionMethod = .autocorrelation
    ) -> BopComparisonResult {
        var detector = BopSignalDetector(
            rotationAxis: rotationAxis, sensitivities: sensitivities, rotationMethod: rotationMethod
        )
        var supportingDetector = BopSignalDetector(
            rotationAxis: rotationAxis,
            sensitivities: sensitivities,
            evidenceMultiplier: evidenceMultiplier,
            rotationMethod: rotationMethod
        )
        let signals = ComparisonSignal.allCases
        var results: [ComparisonSignal: Detections] = [:]
        var supportingEvents: [ComparisonSignal: [BopEvent]] = [:]
        var nodRhythmTimes: [Double] = []
        var autocorrelationTimes: [Double] = []
        var firstTimestamp: Double?
        var lastTimestamp: Double?

        for sample in samples {
            let supportingFrame = supportingDetector.ingest(sample)
            guard let frame = detector.ingest(sample) else { continue }
            firstTimestamp = firstTimestamp ?? frame.timestamp
            lastTimestamp = frame.timestamp
            if let event = frame.nodRhythmBop { nodRhythmTimes.append(event.detectedAt) }
            if let event = frame.autocorrelationBop { autocorrelationTimes.append(event.detectedAt) }
            for signal in signals {
                guard let point = frame[signal] else { continue }
                results[signal, default: Detections()].observe(point.bop)
                if let event = supportingFrame?[signal]?.bop {
                    supportingEvents[signal, default: []].append(event)
                }
            }
        }

        let start = firstTimestamp ?? 0
        let end = lastTimestamp ?? start
        let signalResults = signals.map { signal in
            (results[signal] ?? Detections()).result(
                for: signal,
                startingAt: start,
                sensitivity: BopSignalDetector.clampedSensitivity(sensitivities[signal])
            )
        }
        return BopComparisonResult(
            duration: end - start,
            signals: signalResults,
            combined: BopComparisonResult.CombinedResult(
                detectionTimes: combinedBouts(confirmed: results, supporting: supportingEvents).map { $0.detectedAt - start },
                hasData: signalResults.contains(where: \.hasData)
            ),
            rotationDetectionTimes: [
                .nodRhythm: nodRhythmTimes.map { $0 - start },
                .autocorrelation: autocorrelationTimes.map { $0 - start }
            ]
        )
    }

    private struct Detections {
        var hasData = false
        var events: [BopEvent] = []

        mutating func observe(_ event: BopEvent?) {
            hasData = true
            if let event { events.append(event) }
        }

        func result(
            for signal: ComparisonSignal,
            startingAt start: Double,
            sensitivity: Double
        ) -> BopComparisonResult.SignalResult {
            .init(signal: signal, detectionTimes: events.map { $0.detectedAt - start }, hasData: hasData, sensitivity: sensitivity)
        }
    }

    private static func combinedBouts(
        confirmed: [ComparisonSignal: Detections],
        supporting: [ComparisonSignal: [BopEvent]]
    ) -> [Bout] {
        var candidates = ComparisonSignal.allCases.flatMap { signal in
            (confirmed[signal]?.events ?? []).map { event in
                Bout(startedAt: event.startedAt, detectedAt: event.detectedAt)
            }
        }
        let angular = (supporting[.rotation] ?? []) + (supporting[.orientation] ?? [])
        for vertical in supporting[.verticalAcceleration] ?? [] {
            for angularEvent in angular {
                let offsets = zip(vertical.cycleStarts, angularEvent.cycleStarts).map { verticalStart, angularStart in
                    verticalStart - angularStart
                }
                let intervalCount = offsets.count - 1
                let verticalDuration = vertical.cycleStarts[intervalCount] - vertical.startedAt
                let angularDuration = angularEvent.cycleStarts[intervalCount] - angularEvent.startedAt
                let period = min(verticalDuration, angularDuration) / Double(intervalCount)
                // The signals can be out of phase, but the lag should stay similar across matching cycles.
                let earliest = offsets.min() ?? 0
                let latest = offsets.max() ?? 0
                guard max(abs(earliest), abs(latest)) <= 0.5 * period,
                      latest - earliest <= 0.25 * period
                else { continue }

                candidates.append(Bout(
                    startedAt: min(vertical.startedAt, angularEvent.startedAt),
                    detectedAt: max(vertical.detectedAt, angularEvent.detectedAt)
                ))
            }
        }

        candidates.sort {
            if $0.detectedAt == $1.detectedAt { return $0.startedAt < $1.startedAt }
            return $0.detectedAt < $1.detectedAt
        }
        var selected: [Bout] = []
        for candidate in candidates where !selected.contains(where: { $0.overlaps(candidate) }) {
            selected.append(candidate)
        }
        return selected
    }

    private struct Bout {
        let startedAt: Double
        let detectedAt: Double

        func overlaps(_ other: Bout) -> Bool {
            let sharedTime = min(detectedAt, other.detectedAt) - max(startedAt, other.startedAt)
            let shorterDuration = min(detectedAt - startedAt, other.detectedAt - other.startedAt)
            return sharedTime >= 0.5 * shorterDuration
        }
    }
}

private struct OrientationPattern: Sendable {
    private static let minimumAngularExcursion = 0.012
    private static let minimumMovingRate = 0.028
    private static let smoothingTimeConstant = 0.035
    private static let settlingTime = 0.065
    private static let maximumSampleGap = 0.25
    private static let maximumReversalInterval = 0.5
    private static let minimumOpposingAlignment = 0.75
    private static let cycleIntervals = 0.3...1.1
    private static let maximumIntervalRatio = 1.3
    private static let rearmDelay = 1.3

    private let calibratesBobbleheadOnStartup: Bool
    private var sensitivity: Double
    private var segmentID = 0
    private var reference: simd_quatd?
    private var bobbleheadReference: simd_quatd?
    private var calibration: StartupCalibration?
    private var previous: Observation?
    private var activeStroke: Stroke?
    private var pendingStroke: Stroke?
    private var cycleStarts: [Double] = []
    private var lastCycleCompletedAt: Double?
    private var reportedBop = false
    private(set) var relativeAttitude: SIMD3<Double> = .zero

    var bobbleheadAttitude: SIMD3<Double>? {
        guard let previous, let neutral = bobbleheadReference ?? reference else { return nil }
        if calibration != nil { return .zero }
        return Self.displacement(from: neutral, to: previous.raw)
    }

    init(sensitivity: Double, calibratesBobbleheadOnStartup: Bool) {
        self.sensitivity = sensitivity
        self.calibratesBobbleheadOnStartup = calibratesBobbleheadOnStartup
    }

    mutating func recenterBobblehead() {
        bobbleheadReference = previous?.raw
        if previous != nil { calibration = nil }
    }

    mutating func ingest(_ rawPose: simd_quatd?, sample: MotionSample) -> BopSignalPoint? {
        guard let rawPose else {
            if previous != nil { reset() }
            return nil
        }

        let timestamp = sample.timestamp
        if let previous, timestamp - previous.timestamp > Self.maximumSampleGap || previous.source != sample.source {
            reset()
        }
        guard let previous, let reference else {
            self.reference = rawPose
            self.previous = Observation(raw: rawPose, smoothed: rawPose, timestamp: timestamp, source: sample.source)
            if calibratesBobbleheadOnStartup {
                calibration = StartupCalibration(startedAt: timestamp)
                updateCalibration(with: rawPose, sample: sample)
            }
            return BopSignalPoint(value: 0, segmentID: segmentID, didCycle: false, bop: nil)
        }

        let elapsed = timestamp - previous.timestamp
        let weight = -expm1(-elapsed / Self.smoothingTimeConstant)
        let earlier = previous.smoothed.vector
        // q and -q encode the same orientation. Interpolate along the short arc.
        let aligned = simd_dot(earlier, rawPose.vector) < 0 ? -rawPose.vector : rawPose.vector
        let smoothed = simd_quatd(vector: simd_normalize(earlier + weight * (aligned - earlier)))
        self.previous = Observation(raw: rawPose, smoothed: smoothed, timestamp: timestamp, source: sample.source)
        updateCalibration(with: rawPose, sample: sample)

        if let lastCycleCompletedAt, timestamp - lastCycleCompletedAt >= Self.rearmDelay {
            cycleStarts.removeAll(keepingCapacity: true)
            self.lastCycleCompletedAt = nil
            reportedBop = false
        }

        let result = observeStroke(from: previous, to: smoothed, rawPose: rawPose, at: timestamp)
        relativeAttitude = Self.displacement(from: reference, to: smoothed)
        let angle = simd_length(relativeAttitude)
        return BopSignalPoint(
            value: angle * (180 / .pi),
            segmentID: segmentID,
            didCycle: result.didCycle,
            bop: result.bop
        )
    }

    mutating func reset() {
        let nextSegmentID = segmentID + 1
        self = OrientationPattern(
            sensitivity: sensitivity,
            calibratesBobbleheadOnStartup: calibratesBobbleheadOnStartup
        )
        segmentID = nextSegmentID
    }

    private mutating func updateCalibration(with pose: simd_quatd, sample: MotionSample) {
        guard var calibration else { return }
        if sample.timestamp - calibration.startedAt >= 0.85 {
            // Let tracking start even if the wearer keeps moving through startup.
            self.calibration = nil
            return
        }

        if simd_length(sample.rotationRate) <= 0.15 {
            if let still = calibration.still,
               simd_length(Self.displacement(from: still.pose, to: pose)) <= 0.035 {
                if sample.timestamp - still.timestamp >= 0.18 {
                    recenterBobblehead()
                    return
                }
            } else {
                calibration.still = (pose, sample.timestamp)
            }
        } else {
            calibration.still = nil
        }
        self.calibration = calibration
    }

    mutating func setSensitivity(_ sensitivity: Double) {
        guard self.sensitivity != sensitivity else { return }
        self.sensitivity = sensitivity
        activeStroke = nil
        pendingStroke = nil
        cycleStarts.removeAll(keepingCapacity: true)
        lastCycleCompletedAt = nil
        reportedBop = false
    }

    private mutating func observeStroke(
        from previous: Observation,
        to smoothed: simd_quatd,
        rawPose: simd_quatd,
        at timestamp: Double
    ) -> CycleResult {
        let step = Self.displacement(from: previous.smoothed, to: smoothed)
        let rawStep = Self.displacement(from: previous.raw, to: rawPose)
        let movingThreshold = Self.minimumMovingRate / sensitivity * (timestamp - previous.timestamp)
        let stepLength = simd_length(step)
        var result = CycleResult.none

        if var stroke = activeStroke {
            if simd_dot(stroke.direction, step) >= movingThreshold {
                stroke.lastMovingAt = timestamp
                let displacement = Self.displacement(from: stroke.startPose, to: smoothed)
                stroke.excursion = max(stroke.excursion, simd_dot(stroke.direction, displacement))
                if simd_dot(stroke.direction, rawStep) >= movingThreshold {
                    stroke.supportingSamples += 1
                }
                activeStroke = stroke
                return .none
            }

            if stepLength < movingThreshold, timestamp - stroke.lastMovingAt < Self.settlingTime {
                return .none
            }

            activeStroke = nil
            if stroke.excursion >= Self.minimumAngularExcursion / sensitivity, stroke.supportingSamples >= 2 {
                result = finishStroke(stroke, at: timestamp)
            }
        }

        if stepLength >= movingThreshold {
            let direction = step / stepLength
            activeStroke = Stroke(
                direction: direction,
                startPose: previous.smoothed,
                startedAt: previous.timestamp,
                lastMovingAt: timestamp,
                excursion: stepLength,
                supportingSamples: simd_dot(direction, rawStep) >= movingThreshold ? 1 : 0
            )
        }
        return result
    }

    private mutating func finishStroke(_ stroke: Stroke, at timestamp: Double) -> CycleResult {
        guard let pending = pendingStroke,
              simd_dot(pending.direction, stroke.direction) <= -Self.minimumOpposingAlignment,
              stroke.startedAt - pending.startedAt <= Self.maximumReversalInterval
        else {
            pendingStroke = stroke
            return .none
        }

        pendingStroke = nil
        lastCycleCompletedAt = timestamp
        guard !reportedBop else { return .cycle }
        cycleStarts.append(pending.startedAt)
        guard cycleStarts.count == 3 else { return .cycle }

        let firstInterval = cycleStarts[1] - cycleStarts[0]
        let secondInterval = cycleStarts[2] - cycleStarts[1]
        if Self.cycleIntervals.contains(firstInterval), Self.cycleIntervals.contains(secondInterval),
           max(firstInterval, secondInterval) <= Self.maximumIntervalRatio * min(firstInterval, secondInterval)
        {
            reportedBop = true
            return .bop(BopEvent(cycleStarts: cycleStarts, detectedAt: timestamp))
        }
        cycleStarts.removeFirst()
        return .cycle
    }

    private enum CycleResult {
        case none, cycle, bop(BopEvent)

        var didCycle: Bool {
            if case .none = self { return false }
            return true
        }

        var bop: BopEvent? {
            if case let .bop(event) = self { return event }
            return nil
        }
    }

    // Return a signed rotation vector in reference coordinates, measured in radians.
    private static func displacement(from earlier: simd_quatd, to later: simd_quatd) -> SIMD3<Double> {
        let difference = later * earlier.inverse
        let vector = difference.real < 0 ? -difference.imag : difference.imag
        let magnitude = simd_length(vector)
        guard magnitude > 1e-9 else { return .zero }
        return (2 * atan2(magnitude, abs(difference.real)) / magnitude) * vector
    }

    private struct Observation {
        let raw: simd_quatd
        let smoothed: simd_quatd
        let timestamp: Double
        let source: MotionSource
    }

    private struct StartupCalibration {
        let startedAt: Double
        var still: (pose: simd_quatd, timestamp: Double)?
    }

    private struct Stroke {
        let direction: SIMD3<Double>
        let startPose: simd_quatd
        let startedAt: Double
        var lastMovingAt: Double
        var excursion: Double
        var supportingSamples: Int
    }
}
