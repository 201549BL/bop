public enum MotionSource: String, Codable, Sendable {
    case left, right, unknown, demo
}

public struct MotionSample: Codable, Sendable {
    public let timestamp: Double
    public let rotationRate: SIMD3<Double>
    public let source: MotionSource
    public let attitude: SIMD4<Double>?
    public let userAcceleration: SIMD3<Double>?
    public let gravity: SIMD3<Double>?

    /// Core Motion attitude is an x, y, z, w quaternion. Acceleration and gravity are in g.
    public init(
        timestamp: Double,
        rotationRate: SIMD3<Double>,
        source: MotionSource,
        attitude: SIMD4<Double>? = nil,
        userAcceleration: SIMD3<Double>? = nil,
        gravity: SIMD3<Double>? = nil
    ) {
        self.timestamp = timestamp
        self.rotationRate = rotationRate
        self.source = source
        self.attitude = attitude
        self.userAcceleration = userAcceleration
        self.gravity = gravity
    }
}

public enum RotationAxis: String, CaseIterable, Sendable {
    case x, y, z

    var unitVector: SIMD3<Double> {
        switch self {
        case .x: SIMD3(1, 0, 0)
        case .y: SIMD3(0, 1, 0)
        case .z: SIMD3(0, 0, 1)
        }
    }
}
