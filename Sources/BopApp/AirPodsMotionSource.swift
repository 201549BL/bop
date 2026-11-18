import BopCore
import CoreMotion
import Foundation

@MainActor
final class AirPodsMotionSource {
    enum Status: Equatable {
        case waiting
        case requestingPermission
        case connecting
        case streaming
        case disconnected
        case denied
        case restricted
        case failed(String)
    }

    private var manager: CMHeadphoneMotionManager?
    private var monitor: Task<Void, Never>?
    private var streamTask: Task<Void, Never>?
    private var streamID: UUID?
    private var lastActivity: ContinuousClock.Instant?
    private var hasStreamed = false
    private var isRequestingPermission = false
    private var status: Status?
    private var onSample: (@MainActor (MotionSample) -> Void)?
    private var onStatus: (@MainActor (Status) -> Void)?
    private var onPermissionGranted: (@MainActor () -> Void)?

    private let callbackQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInteractive
        return queue
    }()

    private enum StreamUpdate: Sendable {
        case sample(MotionSample, receivedAt: ContinuousClock.Instant)
        case failure(String)
    }

    func start(
        onSample: @escaping @MainActor (MotionSample) -> Void,
        onStatus: @escaping @MainActor (Status) -> Void,
        onPermissionGranted: @escaping @MainActor () -> Void
    ) {
        stop()
        manager = CMHeadphoneMotionManager()
        self.onSample = onSample
        self.onStatus = onStatus
        self.onPermissionGranted = onPermissionGranted
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, let self else { return }
                self.refreshConnection()
            }
        }
        refreshConnection()
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
        stopStream()
        manager = nil
        hasStreamed = false
        isRequestingPermission = false
        status = nil
        onSample = nil
        onStatus = nil
        onPermissionGranted = nil
    }

    private func refreshConnection() {
        guard let manager else { return }
        let authorization = CMHeadphoneMotionManager.authorizationStatus()
        if authorization == .authorized { handlePermissionGrant() }
        if authorization == .denied || authorization == .restricted {
            stopStream()
            publish(authorization == .denied ? .denied : .restricted)
            return
        }

        guard manager.isDeviceMotionAvailable else {
            stopStream()
            publish(hasStreamed ? .disconnected : .waiting)
            return
        }

        if let lastActivity {
            // Leave the stream running while the system can still be asking for permission.
            if authorization == .authorized, lastActivity.duration(to: .now) > .seconds(3) {
                stopStream()
                publish(hasStreamed ? .disconnected : .failed("No motion data received."))
            } else if authorization == .authorized, status == .requestingPermission {
                publish(.connecting)
            }
            return
        }

        if authorization == .notDetermined {
            isRequestingPermission = true
            publish(.requestingPermission)
        } else if status == nil || status == .waiting || status == .requestingPermission {
            publish(.connecting)
        }
        beginStream(using: manager)
    }

    private func beginStream(using manager: CMHeadphoneMotionManager) {
        let id = UUID()
        streamID = id
        lastActivity = .now
        // Keep a short buffer for detection, without letting a busy UI queue up old poses.
        let (updates, continuation) = AsyncStream.makeStream(
            of: StreamUpdate.self, bufferingPolicy: .bufferingNewest(16)
        )
        streamTask = Task { [weak self] in
            for await update in updates {
                guard let self, self.streamID == id, !Task.isCancelled else { return }
                switch update {
                case let .sample(sample, receivedAt):
                    guard receivedAt.duration(to: .now) <= .milliseconds(100) else { continue }
                    self.receive(sample, streamID: id)
                case let .failure(message):
                    self.handleStreamError(message)
                }
            }
        }
        manager.startDeviceMotionUpdates(to: callbackQueue) { @Sendable motion, error in
            if let motion {
                continuation.yield(.sample(Self.sample(from: motion), receivedAt: .now))
            } else if let error {
                continuation.yield(.failure(error.localizedDescription))
            }
        }
    }

    nonisolated private static func sample(from motion: CMDeviceMotion) -> MotionSample {
        let source: MotionSource = switch motion.sensorLocation {
        case .headphoneLeft: .left
        case .headphoneRight: .right
        default: .unknown
        }
        let rate = motion.rotationRate
        let attitude = motion.attitude.quaternion
        let acceleration = motion.userAcceleration
        let gravity = motion.gravity
        return MotionSample(
            timestamp: motion.timestamp,
            rotationRate: SIMD3(rate.x, rate.y, rate.z),
            source: source,
            attitude: SIMD4(attitude.x, attitude.y, attitude.z, attitude.w),
            userAcceleration: SIMD3(acceleration.x, acceleration.y, acceleration.z),
            gravity: SIMD3(gravity.x, gravity.y, gravity.z)
        )
    }

    private func receive(_ sample: MotionSample, streamID: UUID) {
        hasStreamed = true
        lastActivity = .now
        handlePermissionGrant()
        publish(.streaming)
        if self.streamID == streamID {
            onSample?(sample)
        }
    }

    private func handlePermissionGrant() {
        guard isRequestingPermission else { return }
        isRequestingPermission = false
        // The time spent in the permission dialog doesn't count toward receiving a sample.
        if lastActivity != nil { lastActivity = .now }
        let completion = onPermissionGranted
        onPermissionGranted = nil
        completion?()
    }

    private func handleStreamError(_ message: String) {
        stopStream()
        let authorization = CMHeadphoneMotionManager.authorizationStatus()
        if authorization == .denied || authorization == .restricted {
            publish(authorization == .denied ? .denied : .restricted)
        } else if manager?.isDeviceMotionAvailable == false {
            publish(hasStreamed ? .disconnected : .waiting)
        } else {
            publish(.failed(message))
        }
    }

    private func stopStream() {
        guard streamID != nil else { return }
        streamID = nil
        streamTask?.cancel()
        streamTask = nil
        lastActivity = nil
        manager?.stopDeviceMotionUpdates()
    }

    private func publish(_ status: Status) {
        guard self.status != status else { return }
        self.status = status
        onStatus?(status)
    }
}
