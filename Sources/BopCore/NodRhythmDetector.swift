import Foundation
import simd

struct NodRhythmDetector: Sendable {
    struct Result: Sendable {
        var didNod = false
        var bop: BopEvent?
        var rhythmicRotation: BopRhythmicRotation?
        var turnaround: BopRhythmicRotation?
    }

    private static let minimumStrokeTime = 0.05
    private static let maximumStrokeTime = 0.78
    private static let maximumTurnaroundPause = 0.26
    private static let minimumOpposingAlignment = 0.68
    private static let quietTimeToRearm = 1.15

    private let axis: RotationAxis?
    private var sensitivity: Double
    private var previousTimestamp: Double?
    private var previousRawRate: SIMD3<Double>?
    private var streamSegmentID: Int?
    private var quietSpeed = 0.0
    private var activeStroke: Stroke?
    private var outwardStroke: Stroke?
    private var previousNod: Nod?
    private var reportedBop = false
    private var turnaroundStartedAt: Double?

    var sequenceProgress: Int {
        if reportedBop { return 2 }
        return previousNod == nil ? 0 : 1
    }

    init(axis: RotationAxis?, sensitivity: Double) {
        self.axis = axis
        self.sensitivity = sensitivity
    }

    mutating func reset() {
        self = Self(axis: axis, sensitivity: sensitivity)
    }

    mutating func setSensitivity(_ sensitivity: Double) {
        guard self.sensitivity != sensitivity else { return }
        self = Self(axis: axis, sensitivity: sensitivity)
    }

    mutating func ingest(_ update: DetectionUpdate, repeatingRotation: Bool) -> Result {
        if streamSegmentID != update.streamSegmentID {
            reset()
            streamSegmentID = update.streamSegmentID
        }
        let sample = update.sample
        let elapsed = previousTimestamp.map { sample.timestamp - $0 } ?? 0
        previousTimestamp = sample.timestamp
        guard elapsed > 0 else { return Result() }

        if let outwardStroke, sample.timestamp - outwardStroke.endedAt > Self.maximumTurnaroundPause,
           activeStroke == nil {
            self.outwardStroke = nil
        }
        if let previousNod, activeStroke == nil, outwardStroke == nil,
           sample.timestamp - previousNod.completedAt >= Self.quietTimeToRearm {
            self.previousNod = nil
            reportedBop = false
        }

        let observation = Observation(
            sample: sample, smoothedRate: update.smoothedRotation, axis: axis, elapsed: elapsed
        )
        let earlierRawRate = previousRawRate
        previousRawRate = observation.rawRate
        let speed = simd_length(observation.rate)
        guard speed.isFinite else { return Result() }
        let minimumStartRate = 0.075 / sensitivity
        if activeStroke == nil, outwardStroke == nil,
           speed <= minimumStartRate, simd_length(observation.rawRate) <= 0.12 / sensitivity {
            let weight = -expm1(-elapsed / 1.4)
            quietSpeed += weight * (speed - quietSpeed)
        }
        let startRate = max(minimumStartRate, 2.8 * quietSpeed)
        let endRate = 0.48 * startRate
        let rawSupportRate = 0.60 * startRate
        let earlyTurnaround = observeTurnaround(
            observation, previousRawRate: earlierRawRate, supportRate: rawSupportRate, repeatingRotation: repeatingRotation
        )
        var result = Result()

        if var stroke = activeStroke {
            if simd_dot(observation.rate, stroke.direction) >= endRate {
                stroke.observe(observation, rawSupportRate: rawSupportRate)
                activeStroke = stroke
                return Result(turnaround: earlyTurnaround)
            }

            activeStroke = nil
            if isCredible(stroke) {
                result = finishStroke(stroke, at: sample.timestamp, repeatingRotation: repeatingRotation)
            }
        }

        if speed >= startRate {
            let direction = observation.rate / speed
            var stroke = Stroke(
                direction: direction, startedAt: sample.timestamp,
                endedAt: sample.timestamp, startingPose: observation.pose
            )
            stroke.observe(observation, rawSupportRate: rawSupportRate)
            activeStroke = stroke
        }
        result.turnaround = earlyTurnaround
        return result
    }

    private func isCredible(_ stroke: Stroke) -> Bool {
        let duration = stroke.endedAt - stroke.startedAt
        guard (Self.minimumStrokeTime...Self.maximumStrokeTime).contains(duration),
              stroke.hasRawSupport, stroke.angle >= 0.016 / sensitivity,
              stroke.turnAngle <= 1.2 * stroke.angle else { return false }
        if let poseExcursion = stroke.poseExcursion {
            return poseExcursion >= max(0.006 / sensitivity, 0.25 * stroke.angle)
        }
        return true
    }

    private func formsNod(outward: Stroke, returning: Stroke) -> Bool {
        returning.startedAt - outward.endedAt <= Self.maximumTurnaroundPause
            && simd_dot(outward.direction, returning.direction) <= -Self.minimumOpposingAlignment
    }

    private mutating func observeTurnaround(
        _ observation: Observation, previousRawRate: SIMD3<Double>?, supportRate: Double, repeatingRotation: Bool
    ) -> BopRhythmicRotation? {
        // A raw reversal can cue the next beat before the filtered return stroke is complete.
        guard let previous = previousNod, let outward = outwardStroke ?? activeStroke,
              outward.startedAt >= previous.completedAt, let previousRawRate,
              turnaroundStartedAt != outward.startedAt, isCredible(outward),
              observation.timestamp - outward.endedAt <= Self.maximumTurnaroundPause,
              let period = rhythmicPeriod(
                after: previous, turnedAt: observation.timestamp, direction: outward.direction,
                repeatingRotation: repeatingRotation
              ),
              simd_dot(previousRawRate, outward.direction) <= -0.5 * supportRate
        else { return nil }

        let returnRate = -simd_dot(observation.rawRate, outward.direction)
        guard returnRate >= max(supportRate, Self.minimumOpposingAlignment * simd_length(observation.rawRate))
        else { return nil }

        turnaroundStartedAt = outward.startedAt
        return BopRhythmicRotation(
            startedAt: outward.startedAt,
            excursion: outward.direction * outward.angle,
            angle: outward.angle,
            period: period,
            peakRate: outward.peakRate
        )
    }

    private func rhythmicPeriod(
        after previous: Nod, turnedAt: Double, direction: SIMD3<Double>, repeatingRotation: Bool
    ) -> Double? {
        let period = turnedAt - previous.turnedAt
        let periods = repeatingRotation ? 0.25...1.55 : 0.30...1.40
        guard periods.contains(period), abs(simd_dot(direction, previous.direction)) >= 0.55 else { return nil }
        return period
    }

    private mutating func finishStroke(_ stroke: Stroke, at timestamp: Double, repeatingRotation: Bool) -> Result {
        guard let outward = outwardStroke, formsNod(outward: outward, returning: stroke) else {
            outwardStroke = stroke
            return Result()
        }

        let balance = min(outward.angle, stroke.angle) / max(outward.angle, stroke.angle)
        guard balance >= 0.32, returnedTowardStart(outward: outward, returning: stroke) else {
            outwardStroke = stroke
            return Result()
        }

        outwardStroke = nil
        let nod = Nod(
            startedAt: outward.startedAt, turnedAt: stroke.startedAt, completedAt: timestamp,
            direction: outward.direction,
            excursion: (outward.direction * outward.angle - stroke.direction * stroke.angle) / 2,
            angle: (outward.angle + stroke.angle) / 2,
            peakRate: max(outward.peakRate, stroke.peakRate)
        )
        let previous = previousNod
        previousNod = nod
        var result = Result(didNod: true)
        guard let previous else { return result }

        // Compare where the turnaround falls within each nod so size and duration can vary.
        let similarShape = abs(nod.turnaroundFraction - previous.turnaroundFraction) <= 0.23
        guard similarShape || repeatingRotation,
              let period = rhythmicPeriod(
                after: previous, turnedAt: nod.turnedAt, direction: nod.direction, repeatingRotation: repeatingRotation
              ) else {
            return result
        }
        result.rhythmicRotation = BopRhythmicRotation(
            startedAt: nod.startedAt, excursion: nod.excursion,
            angle: nod.angle, period: period, peakRate: nod.peakRate
        )
        if !reportedBop {
            result.bop = BopEvent(cycleStarts: [previous.startedAt, nod.startedAt], detectedAt: timestamp)
            reportedBop = true
        }
        return result
    }

    private func returnedTowardStart(outward: Stroke, returning: Stroke) -> Bool {
        guard let start = outward.startingPose, let excursion = outward.poseExcursion,
              let returned = returning.latestPose else { return true }
        let remaining = Self.poseDistance(from: start, to: returned)
        return remaining <= max(0.012 / sensitivity, 0.70 * excursion)
    }

    private static func poseDistance(from start: simd_quatd, to end: simd_quatd) -> Double {
        let difference = start.inverse * end
        return 2 * atan2(simd_length(difference.imag), abs(difference.real))
    }

    private struct Observation {
        let timestamp: Double
        let elapsed: Double
        let rate: SIMD3<Double>
        let rawRate: SIMD3<Double>
        let turnRate: Double
        let pose: simd_quatd?

        init(sample: MotionSample, smoothedRate: SIMD3<Double>, axis: RotationAxis?, elapsed: Double) {
            timestamp = sample.timestamp
            self.elapsed = elapsed
            pose = sample.attitude.flatMap { vector in
                let length = simd_length(vector)
                guard length.isFinite, length > 1e-6 else { return nil }
                return simd_quatd(vector: vector / length)
            }
            let gravity = sample.gravity.flatMap { gravity -> SIMD3<Double>? in
                let length = simd_length(gravity)
                guard length.isFinite, length > 1e-6 else { return nil }
                return gravity / length
            }
            if let axis {
                rate = smoothedRate
                rawRate = axis.unitVector * sample.rotationRate
                turnRate = 0
            } else if let gravity {
                let turn = simd_dot(gravity, smoothedRate)
                rate = smoothedRate - gravity * turn
                rawRate = sample.rotationRate - gravity * simd_dot(gravity, sample.rotationRate)
                turnRate = abs(turn)
            } else {
                rate = smoothedRate
                rawRate = sample.rotationRate
                turnRate = 0
            }
        }
    }

    private struct Stroke {
        let direction: SIMD3<Double>
        let startedAt: Double
        var endedAt: Double
        let startingPose: simd_quatd?
        var latestPose: simd_quatd?
        var poseExcursion: Double?
        var firstRawSupportAt: Double?
        var lastRawSupportAt: Double?
        var angle = 0.0
        var turnAngle = 0.0
        var peakRate = 0.0

        var hasRawSupport: Bool {
            guard let firstRawSupportAt, let lastRawSupportAt else { return false }
            return lastRawSupportAt - firstRawSupportAt >= 0.025
        }

        mutating func observe(_ observation: Observation, rawSupportRate: Double) {
            endedAt = observation.timestamp
            angle += simd_dot(observation.rate, direction) * observation.elapsed
            turnAngle += observation.turnRate * observation.elapsed
            let raw = simd_dot(observation.rawRate, direction)
            peakRate = max(peakRate, raw)
            if raw >= rawSupportRate {
                firstRawSupportAt = firstRawSupportAt ?? observation.timestamp
                lastRawSupportAt = observation.timestamp
            }
            latestPose = observation.pose
            if observation.timestamp > startedAt, let startingPose, let pose = observation.pose {
                poseExcursion = max(poseExcursion ?? 0, NodRhythmDetector.poseDistance(from: startingPose, to: pose))
            }
        }
    }

    private struct Nod {
        let startedAt: Double
        let turnedAt: Double
        let completedAt: Double
        let direction: SIMD3<Double>
        let excursion: SIMD3<Double>
        let angle: Double
        let peakRate: Double

        var turnaroundFraction: Double { (turnedAt - startedAt) / (completedAt - startedAt) }
    }
}
