import BopCore
import Foundation
import simd
import XCTest

final class BopComparisonTests: XCTestCase {
    private let cycleDuration = 0.42

    func testVerticalAccelerationThresholdsUseGAndClampSensitivity() {
        let cases: [(sensitivity: Double, start: Double, end: Double)] = [
            (1, 0.070, 0.040),
            (2.5, 0.028, 0.016),
            (0.1, 0.140, 0.080),
            (8, 0.014, 0.008),
        ]
        for expected in cases {
            let actual = BopSignalDetector.verticalAccelerationThresholds(sensitivity: expected.sensitivity)
            XCTAssertEqual(actual.start, expected.start, accuracy: 1e-12)
            XCTAssertEqual(actual.end, expected.end, accuracy: 1e-12)
        }
    }

    func testFindsCandidateOnlyTiltsAndBouncesOnOneTimeline() throws {
        let samples = trace(duration: 5.3) { elapsed, timestamp in
            let tilt = phase(at: elapsed, starts: [0.3, 0.9, 1.5])
            let bounce = phase(at: elapsed, starts: [3.2, 3.8, 4.4])
            let angle = tilt.map { 0.014 * (1 - cos($0)) } ?? 0
            let pitchRate = tilt.map { 0.21 * sin($0) } ?? 0
            let vertical = bounce.map { 0.13 * sin($0) } ?? 0
            let down = SIMD3(0.0, -0.6, -0.8)
            let pose = simd_quatd(angle: angle, axis: SIMD3(0, 1, 0)).vector
            let sign = Int((elapsed * 50).rounded()).isMultiple(of: 2) ? 1.0 : -1.0
            return MotionSample(
                timestamp: timestamp,
                rotationRate: SIMD3(0, pitchRate, 0),
                source: .demo,
                attitude: sign * pose,
                userAcceleration: vertical * down,
                gravity: 1.8 * down
            )
        }

        let comparison = BopComparison.analyze(samples)
        XCTAssertEqual(comparison.duration, 5.3, accuracy: 0.001)
        XCTAssertEqual(comparison.signals.map(\.signal), ComparisonSignal.allCases)
        XCTAssertTrue(comparison.signals.allSatisfy(\.hasData))
        XCTAssertTrue(try result(for: .rotation, in: comparison).detectionTimes.isEmpty)

        let tilts = try result(for: .orientation, in: comparison).detectionTimes
        let bounces = try result(for: .verticalAcceleration, in: comparison).detectionTimes
        XCTAssertEqual(tilts.count, 1)
        XCTAssertEqual(bounces.count, 1)
        XCTAssertTrue((1.9...2.15).contains(try XCTUnwrap(tilts.first)))
        XCTAssertTrue((4.8...5.05).contains(try XCTUnwrap(bounces.first)))

        var detector = BopSignalDetector()
        let frames = samples.compactMap { detector.ingest($0) }
        let start = try XCTUnwrap(frames.first?.timestamp)
        for signal in comparison.signals {
            let cycles = frames.filter { $0[signal.signal]?.didCycle == true }
            let bops = cycles.filter { $0[signal.signal]?.didBop == true }
            XCTAssertEqual(cycles.count, signal.signal == .rotation ? 0 : 3)
            XCTAssertEqual(bops.map { $0.timestamp - start }, signal.detectionTimes)
        }
    }

    func testSignalValuesUseRadiansPerSecondDegreesAndG() throws {
        var detector = BopSignalDetector(rotationAxis: .z)
        let firstPose = simd_quatd(angle: 0.4, axis: SIMD3(1, 0, 0))
        let movedPose = simd_quatd(angle: .pi / 6, axis: SIMD3(0, 1, 0)) * firstPose
        let down = SIMD3(0.0, -0.6, -0.8)
        let samples = trace(duration: 1) { elapsed, timestamp in
            MotionSample(
                timestamp: timestamp,
                rotationRate: SIMD3(8, 0, -2),
                source: .demo,
                attitude: (elapsed == 0 ? firstPose : movedPose).vector,
                userAcceleration: 0.2 * down + SIMD3(3, 0, 0),
                gravity: 1.8 * down
            )
        }
        let frames = samples.compactMap { detector.ingest($0) }
        let last = try XCTUnwrap(frames.last)

        XCTAssertEqual(frames.first?[.orientation]?.value, 0)
        XCTAssertEqual(try XCTUnwrap(last[.rotation]?.value), -2, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(last[.orientation]?.value), 30, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(last[.verticalAcceleration]?.value), 0.2, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(frames.first?.instantaneousVerticalAcceleration), 0.2, accuracy: 0.001)

        detector.setSensitivity(3, for: .orientation)
        let stillMoved = MotionSample(timestamp: last.timestamp + 0.02, rotationRate: .zero, source: .demo, attitude: movedPose.vector)
        let next = try XCTUnwrap(detector.ingest(stillMoved)?[.orientation])
        XCTAssertEqual(next.segmentID, last[.orientation]?.segmentID)
        XCTAssertEqual(next.value, 30, accuracy: 0.001)
    }

    func testBobbleheadFollowsLatestPoseOnTheSameSample() throws {
        var detector = BopSignalDetector()
        let axis = SIMD3<Double>(0, 1, 0)
        let baseline = simd_quatd(angle: 0.4, axis: SIMD3(1, 0, 0))
        let turned = simd_quatd(angle: 0.25, axis: axis) * baseline

        _ = detector.ingest(MotionSample(timestamp: 0, rotationRate: .zero, source: .left, attitude: baseline.vector))
        let frame = try XCTUnwrap(detector.ingest(
            MotionSample(timestamp: 0.02, rotationRate: .zero, source: .left, attitude: turned.vector)
        ))
        XCTAssertEqual(try XCTUnwrap(detector.bobbleheadAttitude).y, 0.25, accuracy: 1e-6)
        XCTAssertLessThan(try XCTUnwrap(frame[.orientation]).value, 0.25 * 180 / .pi)

        detector.recenterBobblehead()
        _ = detector.ingest(MotionSample(timestamp: 0.04, rotationRate: .zero, source: .left, attitude: turned.vector))
        XCTAssertEqual(detector.bobbleheadAttitude, .zero)
        _ = detector.ingest(MotionSample(timestamp: 0.06, rotationRate: .zero, source: .left, attitude: baseline.vector))
        XCTAssertEqual(try XCTUnwrap(detector.bobbleheadAttitude).y, -0.25, accuracy: 1e-6)
    }

    func testBobbleheadCalibratesFromTheFirstSteadyPose() throws {
        var detector = BopSignalDetector(calibratesBobbleheadOnStartup: true)
        let pitch = SIMD3<Double>(1, 0, 0)
        XCTAssertNil(detector.bobbleheadAttitude)

        // The fused pose can move during startup even when the gyro reports a still head.
        for index in 0...6 {
            let angle = 0.05 * Double(6 - index)
            _ = detector.ingest(MotionSample(
                timestamp: 0.02 * Double(index), rotationRate: .zero,
                source: .left, attitude: simd_quatd(angle: angle, axis: pitch).vector
            ))
            XCTAssertEqual(detector.bobbleheadAttitude, .zero)
        }
        for index in 7...17 {
            _ = detector.ingest(MotionSample(
                timestamp: 0.02 * Double(index), rotationRate: .zero,
                source: .left, attitude: simd_quatd(angle: 0, axis: pitch).vector
            ))
        }
        XCTAssertEqual(detector.bobbleheadAttitude, .zero)
        XCTAssertEqual(detector.relativeHeadAttitude.x, -0.3, accuracy: 0.001)

        _ = detector.ingest(MotionSample(
            timestamp: 0.36, rotationRate: pitch,
            source: .left, attitude: simd_quatd(angle: 0.16, axis: pitch).vector
        ))
        XCTAssertEqual(try XCTUnwrap(detector.bobbleheadAttitude).x, 0.16, accuracy: 1e-6)
    }

    func testMovingThroughCalibrationTimeoutUsesTheStartingPose() throws {
        var detector = BopSignalDetector(calibratesBobbleheadOnStartup: true)
        let pitch = SIMD3<Double>(1, 0, 0)
        for index in 0...44 {
            _ = detector.ingest(MotionSample(
                timestamp: 0.02 * Double(index), rotationRate: 0.4 * pitch,
                source: .left, attitude: simd_quatd(angle: 0.008 * Double(index), axis: pitch).vector
            ))
        }
        XCTAssertEqual(try XCTUnwrap(detector.bobbleheadAttitude).x, 0.352, accuracy: 1e-6)
        for index in 45...60 {
            _ = detector.ingest(MotionSample(
                timestamp: 0.02 * Double(index), rotationRate: .zero,
                source: .left, attitude: simd_quatd(angle: 0.352, axis: pitch).vector
            ))
        }
        XCTAssertEqual(try XCTUnwrap(detector.bobbleheadAttitude).x, 0.352, accuracy: 1e-6)
    }

    func testManualRecenteringOverridesPendingCalibration() throws {
        var detector = BopSignalDetector(calibratesBobbleheadOnStartup: true)
        let pitch = SIMD3<Double>(1, 0, 0)
        _ = detector.ingest(MotionSample(
            timestamp: 0, rotationRate: .zero,
            source: .left, attitude: simd_quatd(angle: 0.3, axis: pitch).vector
        ))
        _ = detector.ingest(MotionSample(
            timestamp: 0.02, rotationRate: pitch,
            source: .left, attitude: simd_quatd(angle: 0.4, axis: pitch).vector
        ))
        detector.recenterBobblehead()
        XCTAssertEqual(detector.bobbleheadAttitude, .zero)
        for index in 2...16 {
            _ = detector.ingest(MotionSample(
                timestamp: 0.02 * Double(index), rotationRate: .zero,
                source: .left, attitude: simd_quatd(angle: 0.5, axis: pitch).vector
            ))
            XCTAssertEqual(try XCTUnwrap(detector.bobbleheadAttitude).x, 0.1, accuracy: 1e-6)
        }
    }

    func testRecenteringBobbleheadPreservesOrientationChartAndDetection() throws {
        var detector = BopSignalDetector()
        let centeredPose = simd_quatd(angle: 0.6, axis: SIMD3(0, 0, 1))
            * simd_quatd(angle: -0.3, axis: SIMD3(0, 1, 0))
        let samples = trace(duration: 3.0) { elapsed, timestamp in
            let pitch = phase(at: elapsed, starts: [0.7, 1.3, 1.9]).map { 0.12 * (1 - cos($0)) } ?? 0
            let pose = elapsed == 0
                ? simd_quatd(angle: 0, axis: SIMD3(1, 0, 0))
                : simd_quatd(angle: elapsed >= 2.5 ? 0.2 : pitch, axis: SIMD3(1, 0, 0)) * centeredPose
            return MotionSample(timestamp: timestamp, rotationRate: .zero, source: .left, attitude: pose.vector)
        }

        let beforeRecenter = samples.prefix { $0.timestamp <= 81.6 }
        for sample in beforeRecenter {
            _ = detector.ingest(sample)
        }
        var control = detector
        XCTAssertGreaterThan(simd_length(try XCTUnwrap(detector.bobbleheadAttitude)), 0.5)

        detector.recenterBobblehead()
        XCTAssertEqual(detector.bobbleheadAttitude, .zero)

        var orientationBops = 0
        for sample in samples.dropFirst(beforeRecenter.count) {
            let actual = try XCTUnwrap(detector.ingest(sample)?[.orientation])
            let expected = try XCTUnwrap(control.ingest(sample)?[.orientation])
            XCTAssertEqual(actual.value, expected.value)
            XCTAssertEqual(actual.segmentID, expected.segmentID)
            XCTAssertEqual(actual.didCycle, expected.didCycle)
            XCTAssertEqual(actual.didBop, expected.didBop)
            if actual.didBop { orientationBops += 1 }
        }
        XCTAssertEqual(orientationBops, 1)

        let bobblehead = try XCTUnwrap(detector.bobbleheadAttitude)
        XCTAssertEqual(bobblehead.x, 0.2, accuracy: 0.001)
        XCTAssertEqual(bobblehead.y, 0, accuracy: 0.001)
        XCTAssertEqual(bobblehead.z, 0, accuracy: 0.001)
    }

    func testBobbleheadRecenteringExpiresWhenOrientationStreamBreaks() {
        func sample(at timestamp: Double, source: MotionSource = .left, angle: Double? = 0.3) -> MotionSample {
            MotionSample(
                timestamp: timestamp,
                rotationRate: .zero,
                source: source,
                attitude: angle.map { simd_quatd(angle: $0, axis: SIMD3(0, 1, 0)).vector }
            )
        }

        var detector = BopSignalDetector()
        detector.recenterBobblehead()
        XCTAssertNil(detector.bobbleheadAttitude)

        _ = detector.ingest(sample(at: 0))
        detector.recenterBobblehead()
        _ = detector.ingest(sample(at: 0.02, source: .right, angle: 0.8))
        XCTAssertEqual(detector.bobbleheadAttitude, .zero)

        detector.recenterBobblehead()
        _ = detector.ingest(sample(at: 0.6, source: .right))
        XCTAssertEqual(detector.bobbleheadAttitude, .zero)

        detector.recenterBobblehead()
        _ = detector.ingest(sample(at: 0.62, source: .right, angle: nil))
        XCTAssertNil(detector.bobbleheadAttitude)
        _ = detector.ingest(sample(at: 0.64, source: .right, angle: 0.6))
        XCTAssertEqual(detector.bobbleheadAttitude, .zero)
    }

    func testHigherAccelerationSensitivityDetectsFaintBopsWithoutScalingTheTrace() throws {
        let samples = trace(duration: 2.5) { elapsed, timestamp in
            let vertical = phase(at: elapsed, starts: [0.3, 0.9, 1.5]).map { 0.035 * sin($0) } ?? 0
            return MotionSample(
                timestamp: timestamp,
                rotationRate: .zero,
                source: .right,
                userAcceleration: SIMD3(0, 0, -vertical),
                gravity: SIMD3(0, 0, -1)
            )
        }
        let signal = ComparisonSignal.verticalAcceleration
        let baselineComparison = BopComparison.analyze(samples)
        let boostedComparison = BopComparison.analyze(samples, sensitivities: [signal: 3])
        let baseline = try result(for: signal, in: baselineComparison)
        let boosted = try result(for: signal, in: boostedComparison)
        XCTAssertEqual(baseline.sensitivity, 1)
        XCTAssertTrue(baseline.detectionTimes.isEmpty)
        XCTAssertTrue(baselineComparison.combined.detectionTimes.isEmpty)
        XCTAssertEqual(boosted.sensitivity, 3)
        XCTAssertEqual(boosted.detectionTimes.count, 1)
        XCTAssertTrue(boostedComparison.combined.hasData)
        XCTAssertEqual(boostedComparison.combined.detectionTimes, boosted.detectionTimes)
        XCTAssertTrue(boostedComparison.signals.filter { $0.signal != signal }.allSatisfy { $0.detectionTimes.isEmpty })

        var baselineDetector = BopSignalDetector()
        var boostedDetector = BopSignalDetector()
        boostedDetector.setSensitivity(3, for: signal)
        _ = boostedDetector.ingest(MotionSample(
            timestamp: 80,
            rotationRate: .zero,
            source: .left,
            userAcceleration: .zero,
            gravity: SIMD3(0, 0, -1)
        ))
        let baselinePoints = samples.compactMap { baselineDetector.ingest($0)?[signal] }
        let boostedPoints = samples.compactMap { boostedDetector.ingest($0)?[signal] }
        XCTAssertEqual(baselinePoints.map(\.value), boostedPoints.map(\.value))
        XCTAssertEqual(boostedPoints.filter(\.didBop).count, 1)
    }

    func testCombinedRecoversSynchronizedWeakOrientationAndAcceleration() throws {
        let samples = multiSignalTrace(
            tiltStarts: [0.3, 0.9, 1.5],
            bounceStarts: [0.38, 0.98, 1.58]
        )

        let comparison = BopComparison.analyze(samples)

        XCTAssertTrue(comparison.signals.allSatisfy { $0.hasData && $0.detectionTimes.isEmpty })
        XCTAssertTrue(comparison.combined.hasData)
        XCTAssertEqual(comparison.combined.detectionTimes.count, 1)
        let detectedAt = try XCTUnwrap(comparison.combined.detectionTimes.first)
        XCTAssertTrue((1.9...2.2).contains(detectedAt))
    }

    func testCombinedMatchesTwoWeakRotationCyclesToVerticalAcceleration() {
        for (bounceStarts, expectedBops) in [([0.38, 0.98, 1.58], 1), ([0.38, 0.81, 1.24], 0)] {
            let samples = trace(duration: 2.4) { elapsed, timestamp in
                let rotation = phase(at: elapsed, starts: [0.3, 0.9]).map { 0.18 * sin($0) } ?? 0
                let vertical = phase(at: elapsed, starts: bounceStarts).map { 0.068 * sin($0) } ?? 0
                return MotionSample(
                    timestamp: timestamp,
                    rotationRate: SIMD3(rotation, 0, 0),
                    source: .left,
                    userAcceleration: SIMD3(0, 0, vertical),
                    gravity: SIMD3(0, 0, -1)
                )
            }

            let comparison = BopComparison.analyze(samples)
            XCTAssertTrue(comparison.signals.allSatisfy { $0.detectionTimes.isEmpty })
            XCTAssertEqual(comparison.combined.detectionTimes.count, expectedBops)
        }
    }

    func testCombinedRejectsWeakSignalsWithDifferentCadencesEvenWhenTheirFinalCyclesOverlap() {
        let samples = multiSignalTrace(
            tiltStarts: [0.3, 0.9, 1.5],
            bounceStarts: [0.62, 1.06, 1.5]
        )

        let ordinary = BopComparison.analyze(samples)
        let separatelyDetectable = BopComparison.analyze(
            samples,
            sensitivities: [.orientation: 1.5, .verticalAcceleration: 1.5]
        )

        XCTAssertTrue(ordinary.signals.allSatisfy { $0.hasData && $0.detectionTimes.isEmpty })
        XCTAssertEqual(separatelyDetectable.signals.map { $0.detectionTimes.count }, [0, 1, 1])
        XCTAssertTrue(ordinary.combined.hasData)
        XCTAssertTrue(ordinary.combined.detectionTimes.isEmpty)
    }

    func testCombinedDoesNotPromoteWeakEvidenceFromOnlyOneSignal() {
        let starts = [0.3, 0.9, 1.5]
        let traces = [
            multiSignalTrace(tiltStarts: starts, bounceStarts: []),
            multiSignalTrace(tiltStarts: [], bounceStarts: starts)
        ]

        for samples in traces {
            let comparison = BopComparison.analyze(samples)
            XCTAssertTrue(comparison.signals.allSatisfy { $0.detectionTimes.isEmpty })
            XCTAssertTrue(comparison.combined.hasData)
            XCTAssertTrue(comparison.combined.detectionTimes.isEmpty)
        }
    }

    func testCombinedDeduplicatesAStrongMultiSignalBoutAndKeepsALaterBounce() throws {
        let samples = multiSignalTrace(
            tiltStarts: [0.3, 0.9, 1.5],
            bounceStarts: [0.46, 1.06, 1.66, 3.56, 4.16, 4.76],
            tiltPeak: 0.09,
            verticalPeak: 0.13,
            duration: 5.4
        )

        let comparison = BopComparison.analyze(samples)

        XCTAssertEqual(comparison.signals.map { $0.detectionTimes.count }, [1, 1, 2])
        XCTAssertTrue(comparison.combined.hasData)
        XCTAssertEqual(comparison.combined.detectionTimes.count, 2)
        let rotation = try result(for: .rotation, in: comparison).detectionTimes
        XCTAssertEqual(comparison.combined.detectionTimes.first, rotation.first)
        let bounces = try result(for: .verticalAcceleration, in: comparison).detectionTimes
        XCTAssertEqual(comparison.combined.detectionTimes.last, bounces.last)
    }

    func testChangingSensitivityClearsOnlySelectedDetectionAndKeepsChartContinuity() {
        var detector = BopSignalDetector(rotationAxis: .x)
        let samples = trace(duration: 2.5) { elapsed, timestamp in
            let motion = phase(at: elapsed, starts: [0.3, 0.9, 1.5])
            let rate = motion.map { 2 * sin($0) } ?? 0
            let angle = motion.map { 0.045 * (1 - cos($0)) } ?? 0
            let vertical = motion.map { 0.13 * sin($0) } ?? 0
            return MotionSample(
                timestamp: timestamp,
                rotationRate: SIMD3(rate, 0, 0),
                source: .demo,
                attitude: simd_quatd(angle: angle, axis: SIMD3(1, 0, 0)).vector,
                userAcceleration: SIMD3(0, 0, vertical),
                gravity: SIMD3(0, 0, -1)
            )
        }
        let frames = samples.enumerated().compactMap { index, sample in
            if index == 72 { detector.setSensitivity(3, for: .verticalAcceleration) }
            return detector.ingest(sample)
        }
        for signal in ComparisonSignal.allCases {
            let points = frames.compactMap { $0[signal] }
            XCTAssertEqual(Set(points.map(\.segmentID)).count, 1)
            XCTAssertEqual(points.filter(\.didCycle).count, 3)
            XCTAssertEqual(points.filter(\.didBop).count, signal == .verticalAcceleration ? 0 : 1)
        }
    }

    func testSegmentsBreakAcrossMissingReadingsGapsSourceChangesAndReset() throws {
        var detector = BopSignalDetector()

        func sample(at timestamp: Double, source: MotionSource = .left, withCandidates: Bool = true) -> MotionSample {
            MotionSample(
                timestamp: timestamp,
                rotationRate: .zero,
                source: source,
                attitude: withCandidates ? simd_quatd(angle: timestamp, axis: SIMD3(0, 1, 0)).vector : nil,
                userAcceleration: withCandidates ? SIMD3(0, 0, 0.1) : nil,
                gravity: withCandidates ? SIMD3(0, 0, -1) : nil
            )
        }

        let first = try XCTUnwrap(detector.ingest(sample(at: 0)))
        let missing = try XCTUnwrap(detector.ingest(sample(at: 0.02, withCandidates: false)))
        let returned = try XCTUnwrap(detector.ingest(sample(at: 0.04)))
        XCTAssertNil(missing[.orientation])
        XCTAssertNil(missing[.verticalAcceleration])
        XCTAssertEqual(first[.rotation]?.segmentID, returned[.rotation]?.segmentID)
        XCTAssertNotEqual(first[.orientation]?.segmentID, returned[.orientation]?.segmentID)
        XCTAssertNotEqual(first[.verticalAcceleration]?.segmentID, returned[.verticalAcceleration]?.segmentID)
        XCTAssertEqual(returned[.orientation]?.value, 0)

        let afterGap = try XCTUnwrap(detector.ingest(sample(at: 0.5)))
        let afterSwitch = try XCTUnwrap(detector.ingest(sample(at: 0.52, source: .right)))
        detector.reset()
        let afterReset = try XCTUnwrap(detector.ingest(sample(at: 0)))
        for signal in ComparisonSignal.allCases {
            XCTAssertNotEqual(returned[signal]?.segmentID, afterGap[signal]?.segmentID)
            XCTAssertNotEqual(afterGap[signal]?.segmentID, afterSwitch[signal]?.segmentID)
            XCTAssertNotEqual(afterSwitch[signal]?.segmentID, afterReset[signal]?.segmentID)
        }
        for frame in [afterGap, afterSwitch, afterReset] {
            XCTAssertEqual(frame[.orientation]?.value, 0)
        }
    }

    func testResetRotationStartsPracticeWithFreshNods() throws {
        var detector = BopSignalDetector()
        let starts = [0.3, 0.9, 1.5, 2.1, 2.7, 3.3]
        let samples = trace(duration: 3.9) { elapsed, timestamp in
            let rate = phase(at: elapsed, starts: starts).map { 2 * sin($0) } ?? 0
            return MotionSample(
                timestamp: timestamp,
                rotationRate: SIMD3(rate, 0, 0),
                source: .left,
                attitude: SIMD4(0, 0, 0, 1)
            )
        }

        let beforePractice = samples.prefix { $0.timestamp < 82.48 }
        let before = beforePractice.compactMap { detector.ingest($0) }
        XCTAssertEqual(before.filter { $0[.rotation]?.didBop == true }.count, 1)
        XCTAssertEqual(detector.rotationSequenceProgress, 2)
        detector.resetRotation()
        XCTAssertEqual(detector.rotationSequenceProgress, 0)

        let practice = samples.dropFirst(beforePractice.count).compactMap { detector.ingest($0) }
        XCTAssertEqual(
            practice.filter { $0[.rotation]?.didCycle == true }.map(\.isRhythmicNod),
            [false, true, true, true]
        )
        let bops = practice.filter { $0[.rotation]?.didBop == true }
        XCTAssertEqual(bops.count, 1)
        XCTAssertEqual(try XCTUnwrap(bops.first).timestamp, 83.64, accuracy: 0.08)
        XCTAssertEqual(practice.first?[.orientation]?.segmentID, before.last?[.orientation]?.segmentID)
    }

    func testRhythmicNodsReportTheExcursionOfEachCompletedCycle() throws {
        let starts = [0.3, 0.9, 1.5, 2.1, 2.7]
        let peakRates = [1.5, 1.5, 0.55, 1.15, 2.0]
        let direction = SIMD3(0.6, -0.8, 0.0)
        let samples = trace(duration: 3.4) { elapsed, timestamp in
            let rate = starts.indices.first { (0..<cycleDuration).contains(elapsed - starts[$0]) }.map { index in
                let angle = 2 * Double.pi * (elapsed - starts[index]) / cycleDuration
                return peakRates[index] * sin(angle)
            } ?? 0
            return MotionSample(timestamp: timestamp, rotationRate: direction * rate, source: .demo)
        }

        var detector = BopSignalDetector()
        let frames = samples.compactMap { detector.ingest($0) }
        let nods = frames.filter { $0[.rotation]?.didCycle == true }
        let angles = frames.compactMap(\.rhythmicNodAngle)
        XCTAssertEqual(nods.map(\.isRhythmicNod), [false, true, true, true, true])
        XCTAssertEqual(frames.filter { $0[.rotation]?.didBop == true }.count, 1)
        XCTAssertEqual(angles.count, 4)
        let gentle = try XCTUnwrap(angles.min())
        let strong = try XCTUnwrap(angles.last)
        XCTAssertGreaterThan(gentle, 0)
        XCTAssertEqual(Array(angles.dropFirst()), angles.dropFirst().sorted())
        XCTAssertGreaterThan(strong - gentle, 0.1)

        let rhythmicNods = frames.compactMap(\.rhythmicRotation)
        for (motion, peakRate) in zip(rhythmicNods, peakRates.dropFirst()) {
            XCTAssertEqual(motion.excursion.x, direction.x * motion.angle, accuracy: 0.0001)
            XCTAssertEqual(motion.excursion.y, direction.y * motion.angle, accuracy: 0.0001)
            XCTAssertEqual(motion.excursion.z, 0)
            XCTAssertEqual(motion.peakRate, peakRate, accuracy: 0.025)
            XCTAssertEqual(motion.period, 0.6, accuracy: 0.06)
        }
    }

    func testRotationReboundsLandAtTurnaroundBeforeMatchingConfirmedCycles() throws {
        let starts = [0.3, 0.9, 1.5, 2.1]
        let peak = 1.7
        let samples = trace(duration: 2.7) { elapsed, timestamp in
            let rate = phase(at: elapsed, starts: starts).map { peak * sin($0) } ?? 0
            return MotionSample(timestamp: timestamp, rotationRate: SIMD3(0, -rate, 0), source: .demo)
        }
        var detector = BopSignalDetector()
        let frames = samples.compactMap { detector.ingest($0) }
        let rebounds = frames.filter { $0.rotationRebound != nil }
        let completions = frames.filter(\.isRhythmicNod)

        XCTAssertEqual(rebounds.count, 2)
        XCTAssertEqual(completions.count, 3)
        XCTAssertEqual(frames.filter { $0[.rotation]?.didBop == true }.count, 1)
        for (index, (rebound, completed)) in zip(rebounds, completions.dropFirst()).enumerated() {
            let early = try XCTUnwrap(rebound.rotationRebound)
            let confirmed = try XCTUnwrap(completed.rhythmicRotation)
            XCTAssertEqual(early.startedAt, confirmed.startedAt)
            XCTAssertEqual(early.period, 0.6, accuracy: 0.02)
            XCTAssertLessThan(early.excursion.y, 0)
            XCTAssertEqual(early.peakRate, peak, accuracy: 0.025)
            let turnaround = 81 + starts[index + 2] + cycleDuration / 2
            XCTAssertEqual(rebound.timestamp, turnaround, accuracy: 0.03)
            XCTAssertGreaterThan(completed.timestamp - rebound.timestamp, 0.10)
            XCTAssertFalse(rebound.isRhythmicNod)
            XCTAssertFalse(rebound[.rotation]?.didCycle == true)
        }
    }

    func testRotationImpactDoesNotFireForHeldTiltOrIsolatedCounterSpike() {
        let turn = 1.5 + cycleDuration / 2
        for spike in [0.0, -2.2] {
            let samples = trace(duration: 2.3) { elapsed, timestamp in
                var rate = phase(at: elapsed, starts: [0.3, 0.9, 1.5]).map { 1.7 * sin($0) } ?? 0
                if elapsed >= turn {
                    rate = elapsed - turn < 0.02 ? spike : 0
                }
                return MotionSample(timestamp: timestamp, rotationRate: SIMD3(rate, 0, 0), source: .demo)
            }
            var detector = BopSignalDetector()
            let hits = samples.compactMap { detector.ingest($0)?.rotationRebound }
            XCTAssertTrue(hits.isEmpty)
        }
    }

    func testRotationReboundRequiresTheExpectedBeatAndOpposingMotion() {
        let starts = [0.3, 0.9, 1.9, 2.5, 3.10, 4.9, 5.5]
        let samples = trace(duration: 6.3) { elapsed, timestamp in
            let rate = phase(at: elapsed, starts: starts).map { 1.7 * sin($0) } ?? 0
            let perpendicularReturn = (3.10..<(3.10 + cycleDuration)).contains(elapsed) && rate < 0
            let rotation = perpendicularReturn ? SIMD3(0, rate, 0) : SIMD3(rate, 0, 0)
            return MotionSample(timestamp: timestamp, rotationRate: rotation, source: .demo)
        }
        var detector = BopSignalDetector()
        let frames = samples.compactMap { detector.ingest($0) }

        // The third nod misses the original beat, the next predictable return is perpendicular,
        // and the last two cycles are preceded by a pause long enough to clear the previous beat.
        XCTAssertFalse(frames.contains { $0.rotationRebound != nil })
    }

    func testVerticalBouncePulsesReportPeakInGAfterRhythmIsEstablished() {
        let samples = multiSignalTrace(
            tiltStarts: [],
            bounceStarts: [0.3, 0.9, 1.5, 2.1],
            verticalPeak: 0.18
        )
        var detector = BopSignalDetector()
        let frames = samples.compactMap { detector.ingest($0) }
        let cycles = frames.filter { $0[.verticalAcceleration]?.didCycle == true }
        XCTAssertEqual(cycles.map { $0.rhythmicVerticalBounce != nil }, [false, false, true, true])
        XCTAssertEqual(cycles.filter { $0[.verticalAcceleration]?.didBop == true }.count, 1)
        XCTAssertFalse(frames.contains { $0.rhythmicRotation != nil })

        for bounce in frames.compactMap(\.rhythmicVerticalBounce) {
            XCTAssertEqual(bounce.peakAcceleration, 0.18, accuracy: 0.002)
            XCTAssertEqual(bounce.period, 0.6, accuracy: 0.001)
        }
    }

    func testRotationTraceKeepsAxisChangesContinuousAndBreaksAtStreamInterruptions() throws {
        var detector = BopSignalDetector(sensitivities: [.rotation: 5])
        let samples = trace(duration: 0.9) { elapsed, timestamp in
            let rate: SIMD3<Double>
            switch elapsed {
            case 0.08...0.22: rate = SIMD3(0.12, 0, 0)
            case 0.36...0.50: rate = SIMD3(0, -0.12, 0)
            case 0.64...0.78: rate = SIMD3(0, 0, 0.12)
            default: rate = .zero
            }
            return MotionSample(timestamp: timestamp, rotationRate: rate, source: .left)
        }
        let frames = samples.compactMap { detector.ingest($0) }
        let axisTraces = frames.compactMap(\.rotationTrace)
        XCTAssertEqual(axisTraces.count, samples.count)
        XCTAssertGreaterThan(Set(frames.compactMap { $0[.rotation]?.segmentID }).count, 1)
        XCTAssertEqual(Set(axisTraces.map(\.segmentID)).count, 1)
        XCTAssertTrue(axisTraces.contains { $0[.x] > 0.08 })
        XCTAssertTrue(axisTraces.contains { $0[.y] < -0.08 })
        XCTAssertTrue(axisTraces.contains { $0[.z] > 0.08 })

        let gap = MotionSample(timestamp: 82.4, rotationRate: .zero, source: .left)
        let switched = MotionSample(timestamp: 82.42, rotationRate: .zero, source: .right)
        let invalid = MotionSample(
            timestamp: 82.44,
            rotationRate: SIMD3(.nan, 0, 0),
            source: .right,
            attitude: SIMD4(0, 0, 0, 1)
        )
        let returned = MotionSample(timestamp: 82.46, rotationRate: .zero, source: .right)
        let afterGap = try XCTUnwrap(detector.ingest(gap)?.rotationTrace)
        let afterSwitch = try XCTUnwrap(detector.ingest(switched)?.rotationTrace)
        XCTAssertNil(try XCTUnwrap(detector.ingest(invalid)).rotationTrace)
        let afterInvalid = try XCTUnwrap(detector.ingest(returned)?.rotationTrace)
        detector.reset()
        let afterReset = try XCTUnwrap(detector.ingest(returned)?.rotationTrace)

        XCTAssertNotEqual(axisTraces.last?.segmentID, afterGap.segmentID)
        XCTAssertNotEqual(afterGap.segmentID, afterSwitch.segmentID)
        XCTAssertNotEqual(afterSwitch.segmentID, afterInvalid.segmentID)
        XCTAssertNotEqual(afterInvalid.segmentID, afterReset.segmentID)
    }

    func testComparisonMatchesStreamingRotationAndReportsUnavailableSignals() throws {
        let samples = trace(duration: 2.5) { elapsed, timestamp in
            let rate = phase(at: elapsed, starts: [0.3, 0.9, 1.5]).map { 2 * sin($0) } ?? 0
            return MotionSample(timestamp: timestamp, rotationRate: SIMD3(rate, 0, 0), source: .demo)
        }

        for axis in [RotationAxis.x, .z] {
            var detector = BopSignalDetector(rotationAxis: axis)
            let expected = samples.compactMap { sample -> Double? in
                guard let frame = detector.ingest(sample), frame[.rotation]?.didBop == true else { return nil }
                return frame.timestamp - 81
            }
            XCTAssertEqual(expected.count, axis == .x ? 1 : 0)
            let comparison = BopComparison.analyze(samples, rotationAxis: axis)

            let gyro = try result(for: .rotation, in: comparison)
            XCTAssertTrue(gyro.hasData)
            XCTAssertEqual(gyro.detectionTimes, expected)
            for signal in [ComparisonSignal.orientation, .verticalAcceleration] {
                let unavailable = try result(for: signal, in: comparison)
                XCTAssertFalse(unavailable.hasData)
                XCTAssertTrue(unavailable.detectionTimes.isEmpty)
            }
        }
    }

    func testAutocorrelationFindsGentleBoutsWithNoCompletedStrokes() {
        let starts = [0.4, 1.2, 4.8, 5.6]
        let samples = (0...340).map { index in
            let jitter = index.isMultiple(of: 2) ? 0.0 : 0.004
            let time = Double(index) * 0.02 + jitter
            let motion = starts.first { (0..<0.8).contains(time - $0) }.map { start in
                0.21 * sin(2 * .pi * (time - start) / 0.8)
            } ?? 0
            return MotionSample(
                timestamp: 81 + time,
                rotationRate: SIMD3(0.6, -0.8, 0) * motion,
                source: .left
            )
        }

        var detector = BopSignalDetector()
        let frames = samples.compactMap { detector.ingest($0) }
        XCTAssertFalse(frames.contains { $0[.rotation]?.didCycle == true })
        let bops = frames.filter { $0[.rotation]?.didBop == true }.map { $0.timestamp - 81 }
        XCTAssertEqual(bops.count, 2)
        XCTAssertTrue(bops.contains { (1.2...2.1).contains($0) })
        XCTAssertTrue(bops.contains { (5.6...6.5).contains($0) })
    }

    func testAutocorrelationRejectsRhythmicSingleSampleSpikes() {
        let samples = trace(duration: 4) { elapsed, timestamp in
            let index = Int((elapsed * 50).rounded())
            let rate = index.isMultiple(of: 15) ? (index.isMultiple(of: 30) ? 4.0 : -4.0) : 0
            return MotionSample(timestamp: timestamp, rotationRate: SIMD3(rate, 0, 0), source: .left)
        }

        var detector = BopSignalDetector()
        XCTAssertFalse(samples.contains { detector.ingest($0)?[.rotation]?.didBop == true })
    }

    func testRejectsASingleTiltHorizontalAccelerationAndVerticalSpikes() {
        let samples = trace(duration: 2.6) { elapsed, timestamp in
            let singleTilt = phase(at: elapsed, starts: [0.3]).map { 0.1 * (1 - cos($0)) } ?? 0
            let horizontal = phase(at: elapsed, starts: [0.4, 1, 1.6]).map { 0.2 * sin($0) } ?? 0
            let q = simd_quatd(angle: singleTilt, axis: SIMD3(1, 0, 0)).vector
            let index = Int((elapsed * 50).rounded())
            let sign = index.isMultiple(of: 2) ? 1.0 : -1.0
            let vertical: Double
            switch index {
            case 20, 50, 80: vertical = 0.8
            case 28, 58, 88: vertical = -0.8
            default: vertical = 0
            }
            return MotionSample(
                timestamp: timestamp,
                rotationRate: .zero,
                source: .demo,
                attitude: sign * q,
                userAcceleration: SIMD3(horizontal, 0, vertical),
                gravity: SIMD3(0, 0, -1)
            )
        }

        for sensitivity in [BopSignalDetector.defaultSensitivity, BopSignalDetector.sensitivityRange.upperBound] {
            let comparison = BopComparison.analyze(samples, sensitivities: [.verticalAcceleration: sensitivity])
            XCTAssertTrue(comparison.signals.allSatisfy { $0.hasData && $0.detectionTimes.isEmpty })
        }
    }

    func testDoesNotCombineCandidateCyclesAcrossAnAirPodSwitch() {
        let samples = trace(duration: 2.5) { elapsed, timestamp in
            let motion = phase(at: elapsed, starts: [0.3, 0.9, 1.5])
            let angle = motion.map { 0.014 * (1 - cos($0)) } ?? 0
            let bounce = motion.map { 0.13 * sin($0) } ?? 0
            return MotionSample(
                timestamp: timestamp,
                rotationRate: .zero,
                source: elapsed < 1.42 ? .left : .right,
                attitude: simd_quatd(angle: angle, axis: SIMD3(0, 1, 0)).vector,
                userAcceleration: SIMD3(0, 0, bounce),
                gravity: SIMD3(0, 0, -1)
            )
        }

        let comparison = BopComparison.analyze(samples)
        XCTAssertTrue(comparison.signals.allSatisfy { $0.hasData && $0.detectionTimes.isEmpty })
    }

    private func trace(
        duration: Double,
        sample: (Double, Double) -> MotionSample
    ) -> [MotionSample] {
        (0...Int((duration * 50).rounded())).map { index in
            let elapsed = Double(index) / 50
            return sample(elapsed, 81 + elapsed)
        }
    }

    private func multiSignalTrace(
        tiltStarts: [Double],
        bounceStarts: [Double],
        tiltPeak: Double = 0.012,
        verticalPeak: Double = 0.068,
        duration: Double = 2.7
    ) -> [MotionSample] {
        let worldDown = SIMD3(0.0, 0.0, -1.0)
        return trace(duration: duration) { elapsed, timestamp in
            let tilt = phase(at: elapsed, starts: tiltStarts) ?? 0
            let angle = 0.5 * tiltPeak * (1 - cos(tilt))
            let rate = tiltPeak * .pi / cycleDuration * sin(tilt)
            let attitude = simd_quatd(angle: angle, axis: SIMD3(1, 0, 0))
            let down = attitude.inverse.act(worldDown)
            let vertical = phase(at: elapsed, starts: bounceStarts).map { verticalPeak * sin($0) } ?? 0
            return MotionSample(
                timestamp: timestamp,
                rotationRate: SIMD3(rate, 0, 0),
                source: .right,
                attitude: tiltStarts.isEmpty ? nil : attitude.vector,
                userAcceleration: bounceStarts.isEmpty ? nil : vertical * down,
                gravity: bounceStarts.isEmpty ? nil : down
            )
        }
    }

    private func phase(at elapsed: Double, starts: [Double]) -> Double? {
        guard let start = starts.first(where: { (0..<cycleDuration).contains(elapsed - $0) }) else { return nil }
        return (elapsed - start) / cycleDuration * 2 * .pi
    }

    private func result(
        for signal: ComparisonSignal,
        in comparison: BopComparisonResult
    ) throws -> BopComparisonResult.SignalResult {
        try XCTUnwrap(comparison.signals.first { $0.signal == signal })
    }
}
