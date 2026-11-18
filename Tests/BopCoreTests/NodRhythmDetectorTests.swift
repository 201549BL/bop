import BopCore
import Foundation
import simd
import XCTest

final class NodRhythmDetectorTests: XCTestCase {
    private let timestampOrigin = 20.0

    func testGentleNodsCanVaryInSizeAndDuration() {
        let samples = trace([
            Nod(start: 0.40, duration: 0.80, peakRate: 0.26),
            Nod(start: 1.25, duration: 0.68, peakRate: 0.20)
        ])
        let frames = detect(samples, method: .nodRhythm)
        let nods = frames.filter { $0[.rotation]?.didCycle == true }
        let bops = frames.filter { $0[.rotation]?.didBop == true }

        XCTAssertEqual(nods.count, 2)
        XCTAssertEqual(bops.count, 1)
        XCTAssertGreaterThan(bops.first?.timestamp ?? 0, timestampOrigin + 1.25)
    }

    func testAnIsolatedNodDoesNotConfirmRhythm() {
        let frames = detect(trace([Nod(start: 0.4, duration: 0.8, peakRate: 0.34)]), method: .nodRhythm)

        XCTAssertEqual(frames.filter { $0[.rotation]?.didCycle == true }.count, 1)
        XCTAssertFalse(frames.contains { $0[.rotation]?.didBop == true })
        XCTAssertFalse(frames.contains { $0.rotationRebound != nil }, "An isolated nod should not flash the wordmark")
    }

    func testFeedbackStartsOnTheSecondTurnaroundAndFiresOncePerNod() throws {
        let starts = [0.4, 1.2, 2.0, 2.8]
        let samples = trace(starts.map { Nod(start: $0, duration: 0.80, peakRate: 0.34) })
        let frames = detect(samples, method: .nodRhythm)
        let rebounds = frames.filter { $0.rotationRebound != nil }
        let confirmed = frames.filter(\.isRhythmicNod)

        XCTAssertEqual(rebounds.count, 3)
        XCTAssertEqual(rebounds.compactMap { $0.rotationRebound?.startedAt },
                       confirmed.compactMap { $0.rhythmicRotation?.startedAt })
        let firstRebound = try XCTUnwrap(rebounds.first)
        let firstConfirmed = try XCTUnwrap(confirmed.first)
        XCTAssertEqual(firstRebound.timestamp - timestampOrigin, 1.60, accuracy: 0.06)
        XCTAssertGreaterThan(firstConfirmed.timestamp - firstRebound.timestamp, 0.10)
    }

    func testFeedbackSkipsAReturnOutsideTheRhythm() {
        let frames = detect(trace([
            Nod(start: 0.4, duration: 0.8, peakRate: 0.34),
            Nod(start: 2.1, duration: 0.8, peakRate: 0.34)
        ]), method: .nodRhythm)

        XCTAssertEqual(frames.filter { $0[.rotation]?.didCycle == true }.count, 2)
        XCTAssertFalse(frames.contains { $0.rotationRebound != nil })
    }

    func testAutoUsesGravityToDistinguishRepeatingTurnsFromNods() {
        let samples = trace(regularNods, axis: SIMD3(0, 0, 1))

        XCTAssertFalse(detect(samples, method: .nodRhythm).contains { $0[.rotation]?.didBop == true })
        XCTAssertEqual(detections(in: samples, method: .autocorrelation).count, 1)
    }

    func testGyroOnlyNodsAndConflictingAttitude() {
        let gyroOnly = trace(regularNods, attitude: .unavailable)
        let noPoseChange = trace(regularNods, attitude: .fixed)

        XCTAssertEqual(detections(in: gyroOnly, method: .nodRhythm).count, 1)
        XCTAssertTrue(detections(in: noPoseChange, method: .nodRhythm).isEmpty)
    }

    func testNodsCannotPairAcrossAnEarSwitchOrAStreamGap() {
        let nods = [
            Nod(start: 0.35, duration: 0.58, peakRate: 0.34),
            Nod(start: 1.35, duration: 0.58, peakRate: 0.34)
        ]
        let continuous = trace(nods)
        XCTAssertEqual(detections(in: continuous, method: .nodRhythm).count, 1)

        let switched = trace(nods, source: { $0 < 1.15 ? .left : .right })
        let interrupted = continuous.filter { !(1.00...1.30).contains($0.timestamp - timestampOrigin) }
        XCTAssertTrue(detections(in: switched, method: .nodRhythm).isEmpty)
        XCTAssertTrue(detections(in: interrupted, method: .nodRhythm).isEmpty)
    }

    func testCountsAContinuousBoutOnceAndRearmsAfterQuiet() {
        let starts = [0.4, 1.2, 2.0, 2.8, 5.0, 5.8]
        let samples = trace(starts.map { Nod(start: $0, duration: 0.78, peakRate: 0.34) })
        let times = detections(in: samples, method: .nodRhythm)

        XCTAssertEqual(times.count, 2)
        XCTAssertEqual(times.filter { $0 < 5.0 }.count, 1)
        XCTAssertEqual(times.filter { $0 > 5.8 }.count, 1)
    }

    func testTheSameReplayReportsBothDetectorsAndTheSelectedRotationResult() {
        let samples = trace(regularNods, axis: SIMD3(0, 0, 1))
        let analysis = BopComparison.analyze(samples, rotationMethod: .nodRhythm)
        let legacyAnalysis = BopComparison.analyze(samples, rotationMethod: .autocorrelation)
        let nodTimes = detections(in: samples, method: .nodRhythm)
        let autocorrelationTimes = detections(in: samples, method: .autocorrelation)

        XCTAssertTrue(nodTimes.isEmpty)
        XCTAssertEqual(autocorrelationTimes.count, 1)
        XCTAssertEqual(analysis.rotationDetectionTimes[.nodRhythm], nodTimes)
        XCTAssertEqual(analysis.rotationDetectionTimes[.autocorrelation], autocorrelationTimes)
        XCTAssertEqual(legacyAnalysis.rotationDetectionTimes, analysis.rotationDetectionTimes)
        XCTAssertEqual(analysis.signals.first { $0.signal == .rotation }?.detectionTimes, nodTimes)
        XCTAssertEqual(legacyAnalysis.signals.first { $0.signal == .rotation }?.detectionTimes, autocorrelationTimes)
    }

    private var regularNods: [Nod] {
        [
            Nod(start: 0.4, duration: 0.8, peakRate: 0.31),
            Nod(start: 1.2, duration: 0.8, peakRate: 0.27)
        ]
    }

    private func detect(_ samples: [MotionSample], method: RotationDetectionMethod) -> [BopSignalFrame] {
        var detector = BopSignalDetector(rotationMethod: method)
        return samples.compactMap { detector.ingest($0) }
    }

    private func detections(in samples: [MotionSample], method: RotationDetectionMethod) -> [Double] {
        detect(samples, method: method)
            .filter { $0[.rotation]?.didBop == true }
            .map { $0.timestamp - timestampOrigin }
    }

    private func trace(
        _ nods: [Nod],
        axis: SIMD3<Double> = SIMD3(1, 0, 0),
        attitude: Attitude = .followsMotion,
        source: (Double) -> MotionSource = { _ in .left }
    ) -> [MotionSample] {
        let down = SIMD3<Double>(0, 0, -1)
        let endOfMotion = nods.map { $0.start + $0.duration }.max() ?? 0
        let lastSampleIndex = Int(ceil(max(3, endOfMotion + 0.6) * 50))
        return (0...lastSampleIndex).map { index in
            let elapsed = Double(index) / 50
            let nod = nods.first { (0..<$0.duration).contains(elapsed - $0.start) }
            let motion = nod?.motion(at: elapsed) ?? (rate: 0, angle: 0)
            let pose = simd_quatd(angle: attitude == .followsMotion ? motion.angle : 0, axis: axis)
            return MotionSample(
                timestamp: timestampOrigin + elapsed,
                rotationRate: motion.rate * axis,
                source: source(elapsed),
                attitude: attitude == .unavailable ? nil : pose.vector,
                gravity: attitude == .unavailable ? nil : pose.inverse.act(down)
            )
        }
    }

    private struct Nod {
        let start: Double
        let duration: Double
        let peakRate: Double

        func motion(at elapsed: Double) -> (rate: Double, angle: Double) {
            let phase = 2 * Double.pi * (elapsed - start) / duration
            let rate = peakRate * sin(phase)
            let angle = peakRate * duration / (2 * .pi) * (1 - cos(phase))
            return (rate, angle)
        }
    }

    private enum Attitude: Equatable {
        case followsMotion, fixed, unavailable
    }
}
