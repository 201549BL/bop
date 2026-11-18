import BopCore
import Foundation
import simd

enum DemoMotion {
    private static let sampleRate = 50

    static func samples(on axis: RotationAxis) -> [MotionSample] {
        let nods: [(start: Double, duration: Double, strength: Double)] = [
            (0.55, 0.49, 1.45),
            (2.65, 0.41, 1.80), (3.28, 0.44, 1.55), (3.94, 0.46, 1.72),
            (6.71, 0.40, 1.51), (7.30, 0.43, 1.82), (7.92, 0.45, 1.65)
        ]
        let tilts: [(start: Double, strength: Double)] = [
            (10.30, 0.014), (10.89, 0.014), (11.51, 0.014),
            (20.30, 0.0058), (20.90, 0.0058), (21.50, 0.0058)
        ]
        let tiltDuration = 0.43
        let bounces: [(start: Double, duration: Double, strength: Double)] = [
            (13.85, 0.50, 0.17), (14.45, 0.50, 0.17), (15.04, 0.50, 0.17),
            (17.10, 0.42, 0.047), (17.70, 0.42, 0.047), (18.30, 0.42, 0.047),
            (20.36, 0.43, 0.11), (20.96, 0.43, 0.11), (21.56, 0.43, 0.11)
        ]
        let down = SIMD3<Double>(0, 0, -1)
        let nodAxis = unitVector(on: axis)
        let tiltAxis = axis == .z ? SIMD3<Double>(1, 0, 0) : nodAxis

        return (0...1120).compactMap { index in
            let time = Double(index) / Double(sampleRate)
            if (5.95..<6.37).contains(time) { return nil }

            var nodRate = 0.030 * sin(time * 15) + 0.019 * sin(time * 26)
            var nodAngle = 0.0
            for nod in nods {
                let motion = nodPulse(
                    phase: (time - nod.start) / nod.duration,
                    duration: nod.duration,
                    strength: nod.strength
                )
                nodRate += motion.rate
                nodAngle += motion.angle
            }

            // Subtle tilts stay below the rotation detector's minimum speed.
            var tiltRate = 0.0
            var tiltAngle = 0.0
            for tilt in tilts {
                let phase = (time - tilt.start) / tiltDuration
                if phase > 0 && phase < 1 {
                    tiltAngle = tilt.strength * (1 - cos(2 * .pi * phase))
                    tiltRate = tilt.strength * (2 * .pi / tiltDuration) * sin(2 * .pi * phase)
                }
            }

            // The first two bounce sequences keep the head level. The last also has a small tilt.
            var bounce = 0.0
            for pulse in bounces {
                let phase = (time - pulse.start) / pulse.duration
                if phase > 0 && phase < 1 {
                    bounce = pulse.strength * sin(2 * .pi * phase) * sin(.pi * phase)
                }
            }

            let attitude = simd_quatd(angle: nodAngle, axis: nodAxis)
                * simd_quatd(angle: tiltAngle, axis: tiltAxis)
            let gravity = attitude.inverse.act(down)
            return MotionSample(
                timestamp: time,
                rotationRate: nodAxis * nodRate + tiltAxis * tiltRate,
                source: .demo,
                attitude: attitude.vector,
                userAcceleration: -gravity * bounce,
                gravity: gravity
            )
        }
    }

    private static func unitVector(on axis: RotationAxis) -> SIMD3<Double> {
        switch axis {
        case .x: SIMD3(1, 0, 0)
        case .y: SIMD3(0, 1, 0)
        case .z: SIMD3(0, 0, 1)
        }
    }

    private static func nodPulse(phase: Double, duration: Double, strength: Double) -> (rate: Double, angle: Double) {
        guard phase > 0 && phase < 1 else { return (0, 0) }
        let envelope = sin(.pi * phase)
        // Integrating the rotation pulse gives a tilt that returns to neutral.
        return (
            rate: strength * sin(2 * .pi * phase) * envelope,
            angle: strength * duration * 2 / (3 * .pi) * envelope * envelope * envelope
        )
    }
}
