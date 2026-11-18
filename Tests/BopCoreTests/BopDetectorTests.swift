import BopCore
import Foundation
import XCTest

final class BopDetectorTests: XCTestCase {
    func testRecognizesTwoContinuousNodsWithDifferentPeaksAndCadence() throws {
        let direction = SIMD3(0.6, -0.8, 0.0)
        let starts = [0.3, 0.92, 1.74]
        let peaks = [0.85, 0.26]
        let samples = (0...120).map { index in
            let timestamp = Double(index) / 50
            let rate = peaks.indices.first { (starts[$0]..<starts[$0 + 1]).contains(timestamp) }.map { index in
                let phase = (timestamp - starts[index]) / (starts[index + 1] - starts[index])
                return peaks[index] * sin(2 * .pi * phase)
            } ?? 0
            let rotation = direction * rate + SIMD3(0.02 * sin(23 * timestamp), 0, 0.03)
            return MotionSample(timestamp: timestamp, rotationRate: rotation, source: .left)
        }

        let updates = detect(samples, using: BopDetector())
        XCTAssertEqual(updates.filter(\.didNod).count, 2)
        let events = updates.compactMap(\.bop)
        XCTAssertEqual(events.count, 1)
        let bop = try XCTUnwrap(events.first)
        XCTAssertEqual(bop.startedAt, starts[0], accuracy: 0.12)
        XCTAssertLessThan(bop.detectedAt, 1.9)
    }

    func testRecognizesTwoSlowNods() {
        let samples = trace(nodsAt: [0.3, 1.58], amplitude: 0.35, cycleDuration: 1.18)
        XCTAssertEqual(detect(samples).compactMap(\.bop).count, 1)
    }

    func testAutomaticDetectionRecognizesSubtleBops() {
        let samples = trace(nodsAt: [0.3, 0.86, 1.43], amplitude: 0.44, cycleDuration: 0.42)
        let updates = detect(samples, using: BopDetector())

        XCTAssertEqual(updates.filter(\.didNod).count, 3)
        XCTAssertEqual(updates.compactMap(\.bop).count, 1)
    }

    func testAutomaticDetectionRecognizesBopsOnEitherNonDefaultAxis() {
        for axis in [RotationAxis.y, .z] {
            let samples = trace(nodsAt: [0.3, 0.85, 1.4], axis: axis)
            let updates = detect(samples, using: BopDetector())

            XCTAssertEqual(updates.compactMap(\.bop).count, 1, "Missed a bop on \(axis)")
        }
    }

    func testAutomaticDetectionCombinesSubtleMotionAcrossAxes() {
        let diagonal = SIMD3(0.26, -0.26, 0.26)
        let samples = trace(cycles: [(0.3, diagonal), (0.86, diagonal), (1.43, diagonal)], cycleDuration: 0.42)
        let updates = detect(samples, using: BopDetector())

        XCTAssertEqual(updates.filter(\.didNod).count, 3)
        XCTAssertEqual(updates.compactMap(\.bop).count, 1)
    }

    func testAutomaticDetectionReportsOneBopWhenItsDirectionChanges() {
        let samples = trace(cycles: [
            (0.3, SIMD3(1.5, 0, 0)),
            (0.85, SIMD3(0, -1.5, 0)),
            (1.4, SIMD3(0, 0, 1.5)),
            (1.95, SIMD3(1, 1, 1)),
            (2.5, SIMD3(-1, 1, -1)),
        ])
        let updates = detect(samples, using: BopDetector())

        XCTAssertEqual(updates.filter(\.didNod).map { $0.bop != nil }, [false, false, true, false, false])
    }

    func testAutomaticDetectionIgnoresSmallIrregularMotion() {
        let samples = (0...400).map { index in
            let phase = Double(index)
            let rotation = SIMD3(sin(phase * 1.83), sin(phase * 3.11), sin(phase * 2.29)) * 0.24
            return MotionSample(timestamp: phase / 50, rotationRate: rotation, source: .demo)
        }
        let updates = detect(samples, using: BopDetector())

        XCTAssertTrue(updates.allSatisfy { !$0.didNod && $0.bop == nil })
    }

    func testAutomaticDetectionDoesNotPairPerpendicularStrokes() {
        let samples = trace(nodsAt: [0.3, 0.85, 1.4, 1.95]).map { sample in
            let rate = sample.rotationRate.x
            let rotation = rate >= 0 ? SIMD3(rate, 0, 0) : SIMD3(0, rate, 0)
            return MotionSample(timestamp: sample.timestamp, rotationRate: rotation, source: sample.source)
        }
        let updates = detect(samples, using: BopDetector())

        XCTAssertTrue(updates.allSatisfy { !$0.didNod })
    }

    func testReportsOncePerBopSequenceAndRearmsAfterAPause() throws {
        let samples = trace(nodsAt: [0.3, 0.86, 1.43, 1.99, 2.55, 4.4, 4.94, 5.49])
        let updates = detect(samples)
        let nods = updates.filter(\.didNod)
        let events = updates.compactMap(\.bop)

        XCTAssertEqual(nods.map(\.isRhythmicNod), [false, true, true, true, true, false, true, true])
        XCTAssertEqual(events.count, 2)
        let first = try XCTUnwrap(events.first)
        let last = try XCTUnwrap(events.last)
        XCTAssertEqual(first.startedAt, 0.3, accuracy: 0.12)
        XCTAssertEqual(first.detectedAt, 1.34, accuracy: 0.12)
        XCTAssertEqual(last.startedAt, 4.4, accuracy: 0.12)
        XCTAssertEqual(last.detectedAt, 5.42, accuracy: 0.12)
    }

    func testRhythmicFeedbackContinuesWhenIntervalsVaryWithoutCountingAnotherBop() {
        let updates = detect(trace(nodsAt: [0.3, 0.86, 1.42, 2.33, 2.9, 3.47, 4.04]))

        XCTAssertEqual(updates.filter(\.didNod).map(\.isRhythmicNod), [false, true, true, true, true, true, true])
        XCTAssertEqual(updates.compactMap(\.bop).count, 1)
    }

    func testRecognizesEitherPolarityOnTheSelectedAxis() {
        let invertedNodsOnZ = trace(nodsAt: [0.3, 0.85, 1.4], axis: .z, amplitude: -2)

        XCTAssertTrue(detect(invertedNodsOnZ).allSatisfy { !$0.didNod })
        let selectedAxis = detect(invertedNodsOnZ, using: BopDetector(axis: .z))
        XCTAssertEqual(selectedAxis.filter(\.didNod).count, 3)
        XCTAssertEqual(selectedAxis.compactMap(\.bop).count, 1)
    }

    func testRejectsLowMotionAndIsolatedOrIrregularNods() {
        let quiet = detect(trace(nodsAt: [0.3, 0.85, 1.4], amplitude: 0.3))
        XCTAssertTrue(quiet.allSatisfy { !$0.didNod })

        let isolated = detect(trace(nodsAt: [0.3]))
        XCTAssertEqual(isolated.filter(\.didNod).count, 1)
        XCTAssertTrue(isolated.compactMap(\.bop).isEmpty)

        let spacedApart = detect(trace(nodsAt: [0.3, 1.85, 3.5]))
        XCTAssertEqual(spacedApart.filter(\.didNod).count, 3)
        XCTAssertTrue(spacedApart.compactMap(\.bop).isEmpty)
    }

    func testDoesNotPairStrokesFromAProlongedTiltOrOneSampleSpikes() {
        let samples = (0...150).map { index in
            let timestamp = Double(index) / 50
            let rate: Double
            switch index {
            case 15...27: rate = 1.7
            case 65...77: rate = -1.7
            case 90: rate = 4
            case 105: rate = -4
            default: rate = 0
            }
            return MotionSample(timestamp: timestamp, rotationRate: SIMD3(rate, 0, 0), source: .demo)
        }

        XCTAssertTrue(detect(samples).allSatisfy { !$0.didNod })
    }

    func testTwoPostureAdjustmentsWithBriefReturnsDoNotCountAsABop() {
        let samples = trace(nodsAt: [0.3, 0.94], amplitude: 3, cycleDuration: 0.55).map { sample in
            let rate = sample.rotationRate.x
            let rotation = SIMD3(rate < 0 ? rate / 6 : rate, 0, 0)
            return MotionSample(timestamp: sample.timestamp, rotationRate: rotation, source: sample.source)
        }

        let updates = detect(samples)
        XCTAssertEqual(updates.filter(\.didNod).count, 2)
        XCTAssertTrue(updates.compactMap(\.bop).isEmpty)
    }

    func testDoesNotCombineNodsAcrossAnAirPodSwitch() throws {
        let samples = trace(nodsAt: [1.4, 2, 2.55, 3.1], rightAirPodAfter: 1.95)
        let updates = detect(samples)
        let switchUpdate = try XCTUnwrap(updates.first { $0.sample.source == .right })

        XCTAssertEqual(updates.first?.segmentID, 0)
        XCTAssertEqual(switchUpdate.segmentID, 1)
        XCTAssertEqual(switchUpdate.smoothedNodRate, 0)
        XCTAssertEqual(updates.filter(\.didNod).map(\.isRhythmicNod), [false, false, true, true])
        let events = updates.compactMap(\.bop)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(try XCTUnwrap(events.last).startedAt, 2, accuracy: 0.12)
    }

    func testDoesNotCombineNodsAcrossMissingSamples() throws {
        let samples = trace(nodsAt: [0.85, 1.8, 2.35, 2.9])
            .filter { !(1.36...1.68).contains($0.timestamp) }
        let updates = detect(samples)
        let events = updates.compactMap(\.bop)

        XCTAssertEqual(updates.last?.segmentID, 1)
        XCTAssertEqual(updates.filter(\.didNod).map(\.isRhythmicNod), [false, false, true, true])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(try XCTUnwrap(events.first).startedAt, 1.8, accuracy: 0.12)
    }

    func testResetStartsANewSegmentAndIgnoresInvalidOrStaleSamples() throws {
        var detector = BopDetector(axis: .z)
        let sample = MotionSample(timestamp: 1, rotationRate: .zero, source: .demo)
        XCTAssertEqual(detector.ingest(sample)?.segmentID, 0)
        XCTAssertNil(detector.ingest(sample))
        XCTAssertNil(detector.ingest(MotionSample(timestamp: 0, rotationRate: .zero, source: .demo)))
        XCTAssertNil(detector.ingest(MotionSample(timestamp: 1.02, rotationRate: SIMD3(0, 0, .nan), source: .demo)))

        detector.reset()
        XCTAssertEqual(detector.axis, .z)
        XCTAssertEqual(detector.ingest(sample)?.segmentID, 1)
    }

    private func detect(
        _ samples: [MotionSample],
        using detector: BopDetector = BopDetector(axis: .x)
    ) -> [DetectionUpdate] {
        var detector = detector
        return samples.compactMap { detector.ingest($0) }
    }

    private func trace(
        nodsAt starts: [Double],
        axis: RotationAxis = .x,
        amplitude: Double = 2,
        cycleDuration: Double = 0.38,
        rightAirPodAfter switchTime: Double? = nil
    ) -> [MotionSample] {
        let peakRate: SIMD3<Double>
        switch axis {
        case .x: peakRate = SIMD3(amplitude, 0, 0)
        case .y: peakRate = SIMD3(0, amplitude, 0)
        case .z: peakRate = SIMD3(0, 0, amplitude)
        }
        return trace(
            cycles: starts.map { ($0, peakRate) },
            cycleDuration: cycleDuration,
            rightAirPodAfter: switchTime
        )
    }

    private func trace(
        cycles: [(start: Double, peakRate: SIMD3<Double>)],
        cycleDuration: Double = 0.38,
        rightAirPodAfter switchTime: Double? = nil
    ) -> [MotionSample] {
        let sampleCount = Int(((cycles.last?.start ?? 0) + max(0.7, cycleDuration + 0.2)) / 0.02)
        return (0...sampleCount).map { index in
            let jitter = index.isMultiple(of: 2) ? 0 : 0.005
            let timestamp = Double(index) * 0.02 + jitter
            let cycle = cycles.first { (0..<cycleDuration).contains(timestamp - $0.start) }
            let rotation = cycle.map { cycle in
                let phase = (timestamp - cycle.start) / cycleDuration
                return cycle.peakRate * sin(2 * .pi * phase)
            } ?? .zero
            let source = switchTime.map { timestamp >= $0 ? MotionSource.right : .left } ?? .demo
            return MotionSample(timestamp: timestamp, rotationRate: rotation, source: source)
        }
    }
}
