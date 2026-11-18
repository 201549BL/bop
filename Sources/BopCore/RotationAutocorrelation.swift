import simd

// Experimental bop recognition from two neighboring windows of signed gyro data.
struct RotationAutocorrelation: Sendable {
    private static let sampleInterval = 0.02
    private static let lags = 15...70 // 0.30...1.40 seconds per cycle at 50 Hz.
    private static let quietTime = 1.1
    private static let rhythmTimeout = 1.55
    private static let minimumCorrelation = 0.75

    private let axis: RotationAxis?
    private let sensitivity: Double
    private var streamSegmentID: Int?
    private var streamStart = 0.0
    private var previous: (elapsed: Double, rate: SIMD3<Double>, rawRate: SIMD3<Double>)?
    private var nextSampleAt = 0.0
    private var samples: [GridSample] = []
    private var samplesSinceSearch = 0
    private var lastMotionAt: Double?
    private var lastMatchAt: Double?

    var hasDetectedBop: Bool { lastMatchAt != nil }

    func hasRecentMatch(at timestamp: Double) -> Bool {
        guard let lastMatchAt else { return false }
        return timestamp - streamStart - lastMatchAt <= 0.25
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

    mutating func ingest(_ update: DetectionUpdate) -> BopEvent? {
        let timestamp = update.sample.timestamp
        let rate = update.smoothedRotation
        if streamSegmentID != update.streamSegmentID {
            reset()
            streamSegmentID = update.streamSegmentID
            streamStart = timestamp
        }
        let elapsed = timestamp - streamStart
        let raw = update.sample.rotationRate
        let rawRate = axis.map { $0.unitVector * raw } ?? raw
        let previous = self.previous
        self.previous = (elapsed, rate, rawRate)
        guard let previous else {
            nextSampleAt = Self.sampleInterval
            return nil
        }

        // Use elapsed time rather than callback frequency to compare cycles at the same tempo.
        let motionFloor = 0.08 / sensitivity
        let isSupported = simd_dot(previous.rawRate, rawRate) >= motionFloor * motionFloor
        var bop: BopEvent?
        while nextSampleAt <= elapsed {
            let fraction = (nextSampleAt - previous.elapsed) / (elapsed - previous.elapsed)
            let interpolated = previous.rate + fraction * (rate - previous.rate)
            let gridTimestamp = nextSampleAt
            nextSampleAt += Self.sampleInterval
            let sample = GridSample(rate: interpolated, isSupported: isSupported)
            if let match = observe(sample, at: gridTimestamp, detectedAt: timestamp) { bop = match }
        }
        return bop
    }

    private mutating func observe(_ sample: GridSample, at elapsed: Double, detectedAt: Double) -> BopEvent? {
        let motionFloor = 0.08 / sensitivity
        if let lastMotionAt, elapsed - lastMotionAt >= Self.quietTime {
            samples.removeAll(keepingCapacity: true)
            lastMatchAt = nil
            self.lastMotionAt = nil
        }
        if simd_length_squared(sample.rate) >= motionFloor * motionFloor { lastMotionAt = elapsed }

        samples.append(sample)
        if samples.count > 2 * Self.lags.upperBound { samples.removeFirst() }
        guard lastMotionAt != nil else { return nil }
        samplesSinceSearch += 1
        guard samplesSinceSearch >= 2 else { return nil }
        samplesSinceSearch = 0

        guard let lag = matchingLag() else {
            if let lastMatchAt, elapsed - lastMatchAt >= Self.rhythmTimeout { self.lastMatchAt = nil }
            return nil
        }
        let alreadyDetected = hasDetectedBop
        lastMatchAt = elapsed
        guard !alreadyDetected else { return nil }

        let period = Double(lag) * Self.sampleInterval
        // A matching window can include stillness before the first stroke.
        let firstIndex = samples.count - 2 * lag
        let leadIn = samples[firstIndex..<(firstIndex + lag)].prefix { !$0.isSupported }.count
        let start = streamStart + elapsed - Double(2 * lag - 1 - leadIn) * Self.sampleInterval
        return BopEvent(cycleStarts: [start, start + period], detectedAt: detectedAt)
    }

    private func matchingLag() -> Int? {
        let longestLag = min(Self.lags.upperBound, samples.count / 2)
        guard longestLag >= Self.lags.lowerBound else { return nil }

        var bestLag: Int?
        var bestScore = Self.minimumCorrelation
        for lag in Self.lags.lowerBound...longestLag {
            let middle = samples.count - lag
            let start = middle - lag
            let count = Double(lag)
            let period = count * Self.sampleInterval
            let rmsFloor = max(0.115, 0.05 / period) / sensitivity

            var firstSum = SIMD3<Double>.zero
            var secondSum = SIMD3<Double>.zero
            var firstEnergy = 0.0
            var secondEnergy = 0.0
            var product = 0.0
            for offset in 0..<lag {
                let first = samples[start + offset].rate
                let second = samples[middle + offset].rate
                firstSum += first
                secondSum += second
                firstEnergy += simd_length_squared(first)
                secondEnergy += simd_length_squared(second)
                product += simd_dot(first, second)
            }

            // Both windows must contain motion, with little net rotation over a cycle.
            let firstDrift = simd_length_squared(firstSum) / count
            let secondDrift = simd_length_squared(secondSum) / count
            guard firstEnergy >= count * rmsFloor * rmsFloor, secondEnergy >= count * rmsFloor * rmsFloor,
                  firstDrift <= 0.16 * firstEnergy, secondDrift <= 0.16 * secondEnergy else { continue }

            let covariance = product - simd_dot(firstSum, secondSum) / count
            let score = covariance / sqrt((firstEnergy - firstDrift) * (secondEnergy - secondDrift))
            guard score > bestScore else { continue }
            // Rapid vibration can match at a long lag without traversing much angle in either window.
            guard hasSustainedExcursion(samples[start..<middle], energy: firstEnergy),
                  hasSustainedExcursion(samples[middle...], energy: secondEnergy) else { continue }
            bestLag = lag
            bestScore = score
        }
        return bestLag
    }

    private func hasSustainedExcursion(_ window: ArraySlice<GridSample>, energy: Double) -> Bool {
        var angle = SIMD3<Double>.zero
        var minimum = angle
        var maximum = angle
        var supportingSamples = 0
        for sample in window {
            if sample.isSupported { supportingSamples += 1 }
            angle += sample.rate
            minimum = simd_min(minimum, angle)
            maximum = simd_max(maximum, angle)
        }
        // Sample spacing cancels when comparing angular range to RMS speed times duration.
        return supportingSamples >= 3
            && simd_length_squared(maximum - minimum) >= 0.04 * Double(window.count) * energy
    }

    private struct GridSample: Sendable {
        let rate: SIMD3<Double>
        let isSupported: Bool
    }
}
