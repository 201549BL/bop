import BopCore
import Foundation
import Observation

struct BopRhythmPulse: Equatable {
    enum Motion: Equatable {
        case rotation(angle: Double, peakRate: Double)
        case verticalBounce(peakAcceleration: Double)
    }

    let timestamp: Double
    let period: Double
    let motion: Motion

    var isVerticalBounce: Bool {
        if case .verticalBounce = motion { return true }
        return false
    }
}

private struct MotionRecording: Codable {
    struct SensitivityChange: Codable {
        let sampleIndex: Int
        let signal: String
        let value: Double
    }

    var version = 1
    let rotationAxis: String
    let rotationMethod: String?
    let sensitivities: [String: Double]
    var sensitivityChanges: [SensitivityChange] = []
    var samples: [MotionSample] = []
}

@MainActor
@Observable
final class BopSession {
    static let practiceBeatCount = 2
    private static let bopSensitivityKey = "bopSensitivity"

    private(set) var history: [BopSignalFrame] = []
    private(set) var bopCounts: [ComparisonSignal: Int] = [:]
    private(set) var showingBops: Set<ComparisonSignal> = []
    private(set) var menuBopEvent: Int?
    private(set) var rotationMethod: RotationDetectionMethod = .nodRhythm
    private(set) var status = "Ready"
    private(set) var motionStatus: AirPodsMotionSource.Status?
    private(set) var isLive = false
    private(set) var isReplaying = false
    private(set) var isRecording = false
    private(set) var comparison: BopComparisonResult?
    private(set) var rotationProgress = 0
    private(set) var rhythmPulse: BopRhythmPulse?
    private(set) var verticalBounce = 0.0

    var headPitch: Double { headAttitude?.x ?? 0 }
    var headRoll: Double { headAttitude?.y ?? 0 }
    var headYaw: Double { headAttitude?.z ?? 0 }

    var axis: RotationAxis? = nil {
        didSet {
            if axis != oldValue { beginSession() }
        }
    }

    var canReplayRecording: Bool { recording != nil }

    private var recording: MotionRecording?
    private var sensitivities: [ComparisonSignal: Double]
    private var headAttitude: SIMD3<Double>?
    @ObservationIgnored private var pendingRecording: MotionRecording?
    @ObservationIgnored private var detector: BopSignalDetector
    @ObservationIgnored private var lastShownRotationStart: Double?
    @ObservationIgnored private var menuBopSequence = 0
    @ObservationIgnored private let motionSource = AirPodsMotionSource()
    @ObservationIgnored private var replayTask: Task<Void, Never>?
    @ObservationIgnored private var feedbackTasks: [ComparisonSignal: Task<Void, Never>] = [:]
    @ObservationIgnored private var recordingTask: Task<Void, Never>?
    @ObservationIgnored private var rotationProgressTask: Task<Void, Never>?
    @ObservationIgnored var onLiveBop: ((Date) -> Void)?
    @ObservationIgnored var onLiveListeningEnded: (() -> Void)?

    init() {
        let savedSensitivity = UserDefaults.standard.double(forKey: Self.bopSensitivityKey)
        let sensitivities: [ComparisonSignal: Double] = BopSignalDetector.sensitivityRange.contains(savedSensitivity)
            ? [.rotation: savedSensitivity]
            : [:]
        self.sensitivities = sensitivities
        detector = BopSignalDetector(sensitivities: sensitivities, rotationMethod: .nodRhythm)
    }

    func sensitivity(for signal: ComparisonSignal) -> Double {
        sensitivities[signal, default: BopSignalDetector.defaultSensitivity]
    }

    func setRotationMethod(_ method: RotationDetectionMethod) {
        guard method != rotationMethod, !isRecording, !isReplaying else { return }
        rotationMethod = method
        beginSession()
    }

    func setSensitivity(_ value: Double, for signal: ComparisonSignal) {
        guard !isReplaying, value.isFinite else { return }
        let range = BopSignalDetector.sensitivityRange
        let value = min(range.upperBound, max(range.lowerBound, value))
        guard sensitivity(for: signal) != value else { return }

        sensitivities[signal] = value
        detector.setSensitivity(value, for: signal)
        if signal == .rotation {
            UserDefaults.standard.set(value, forKey: Self.bopSensitivityKey)
            clearRotationProgress()
        }
        if let sampleIndex = pendingRecording?.samples.count {
            pendingRecording?.sensitivityChanges.append(
                .init(sampleIndex: sampleIndex, signal: signal.rawValue, value: value)
            )
        }
    }

    func startListening(onPermissionGranted: @escaping @MainActor () -> Void) {
        stop()
        isLive = true
        beginSession()
        status = "Looking for AirPods…"
        motionSource.start(
            onSample: { [weak self] sample in
                guard let self, self.isLive else { return }
                self.receive(sample)
            },
            onStatus: { [weak self] status in
                self?.handleMotionStatus(status)
            },
            onPermissionGranted: onPermissionGranted
        )
    }

    func stop() {
        if isLive { onLiveListeningEnded?() }
        isLive = false
        motionSource.stop()
        motionStatus = nil
        replayTask?.cancel()
        replayTask = nil
        isReplaying = false
        finishRecording()
        clearFeedback()
        resetBobblehead()
        status = "Stopped"
    }

    func playDemo() {
        replay(DemoMotion.samples(on: axis ?? .x), status: "Playing demo")
    }

    func resetBopDetection() {
        detector.reset()
        clearFeedback()
        resetBobblehead()
    }

    func toggleRecording() {
        if isRecording {
            finishRecording()
            return
        }
        guard isLive else { return }

        pendingRecording = MotionRecording(
            rotationAxis: axis?.rawValue ?? "auto",
            rotationMethod: rotationMethod.rawValue,
            sensitivities: Dictionary(uniqueKeysWithValues: ComparisonSignal.allCases.map {
                ($0.rawValue, sensitivity(for: $0))
            })
        )
        isRecording = true
        recordingTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(20))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.finishRecording()
        }
    }

    func replayRecording() {
        guard let recording else { return }
        replay(recording.samples, status: "Replaying recording")
    }

    func recordedMotionData() throws -> Data? {
        guard let recording, !isRecording else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN"
        )
        return try encoder.encode(recording)
    }

    private func beginSession() {
        detector = BopSignalDetector(
            rotationAxis: axis,
            sensitivities: sensitivities,
            calibratesBobbleheadOnStartup: isLive,
            rotationMethod: rotationMethod
        )
        history.removeAll()
        bopCounts.removeAll()
        comparison = nil
        clearFeedback()
        resetBobblehead()
    }

    private func receive(_ sample: MotionSample) {
        guard let frame = detector.ingest(sample) else { return }

        if let previous = history.last, frame.timestamp <= previous.timestamp {
            history.removeAll()
        }
        history.append(frame)
        history.removeAll { $0.timestamp < frame.timestamp - 4 }
        headAttitude = detector.bobbleheadAttitude
        verticalBounce = -(frame.instantaneousVerticalAcceleration ?? 0)
        updateRotationProgress(didBop: frame[.rotation]?.didBop == true)
        updateRhythmPulse(from: frame)

        if isRecording {
            if let previous = pendingRecording?.samples.last, sample.timestamp <= previous.timestamp {
                finishRecording()
            } else {
                pendingRecording?.samples.append(sample)
            }
        }

        var hasMenuBop = false
        for signal in ComparisonSignal.allCases where frame[signal]?.didBop == true {
            bopCounts[signal, default: 0] += 1
            showFeedback(for: signal)
            if signal == .rotation || rotationMethod == .autocorrelation {
                hasMenuBop = true
            }
        }

        if hasMenuBop {
            menuBopSequence += 1
            menuBopEvent = menuBopSequence
            if isLive, motionStatus == .streaming {
                onLiveBop?(Date())
            }
        }
    }

    private func updateRhythmPulse(from frame: BopSignalFrame) {
        let pulse: BopRhythmPulse
        let rotation = frame.rotationRebound ?? frame.rhythmicRotation
        let showsRotation = rotation.map { $0.startedAt != lastShownRotationStart } ?? false
        if let rotation, showsRotation {
            pulse = BopRhythmPulse(
                timestamp: frame.timestamp,
                period: rotation.period,
                motion: .rotation(angle: rotation.angle, peakRate: rotation.peakRate)
            )
        } else if let bounce = frame.rhythmicVerticalBounce {
            pulse = BopRhythmPulse(
                timestamp: frame.timestamp,
                period: bounce.period,
                motion: .verticalBounce(peakAcceleration: bounce.peakAcceleration)
            )
        } else {
            return
        }

        // Rotation and acceleration often describe the same beat a few samples apart.
        if let previous = rhythmPulse,
           previous.isVerticalBounce != pulse.isVerticalBounce,
           pulse.timestamp - previous.timestamp < 0.24 {
            return
        }
        rhythmPulse = pulse
        if showsRotation { lastShownRotationStart = rotation?.startedAt }
    }

    private func handleMotionStatus(_ motionStatus: AirPodsMotionSource.Status) {
        guard isLive else { return }
        switch motionStatus {
        case .waiting:
            status = "Connect and wear compatible AirPods"
        case .requestingPermission:
            status = "Waiting for motion access"
        case .connecting:
            status = "Connecting to AirPods…"
        case .streaming:
            status = "Listening"
        case .disconnected:
            onLiveListeningEnded?()
            detector.reset()
            menuBopEvent = nil
            finishRecording()
            resetBobblehead()
            status = "AirPods disconnected · Waiting to reconnect"
        case .denied:
            stop()
            status = "Allow motion access in System Settings"
        case .restricted:
            stop()
            status = "Motion access is restricted on this Mac"
        case .failed(let message):
            onLiveListeningEnded?()
            detector.reset()
            menuBopEvent = nil
            finishRecording()
            resetBobblehead()
            status = "\(message) Retrying…"
        }
        self.motionStatus = motionStatus
    }

    private func finishRecording() {
        recordingTask?.cancel()
        recordingTask = nil
        guard isRecording else { return }

        isRecording = false
        if let pendingRecording, !pendingRecording.samples.isEmpty {
            recording = pendingRecording
        }
        pendingRecording = nil
    }

    private func replay(_ samples: [MotionSample], status: String) {
        guard let first = samples.first else { return }
        stop()
        beginSession()
        isReplaying = true
        self.status = status
        comparison = BopComparison.analyze(
            samples, rotationAxis: axis, sensitivities: sensitivities, rotationMethod: rotationMethod
        )

        replayTask = Task { [weak self] in
            let clock = ContinuousClock()
            let start = clock.now
            for sample in samples {
                do {
                    try await clock.sleep(until: start + .seconds(sample.timestamp - first.timestamp))
                } catch {
                    return
                }
                guard !Task.isCancelled, let self else { return }
                self.receive(sample)
            }
            guard let self else { return }
            self.isReplaying = false
            self.headAttitude = nil
            self.verticalBounce = 0
            if self.rotationProgressTask == nil { self.rotationProgress = 0 }
            self.status = "Replay complete"
            self.replayTask = nil
        }
    }

    private func updateRotationProgress(didBop: Bool) {
        if didBop {
            rotationProgressTask?.cancel()
            rotationProgress = Self.practiceBeatCount
            rotationProgressTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: .milliseconds(850))
                } catch {
                    return
                }
                guard !Task.isCancelled, let self else { return }
                self.rotationProgress = 0
                self.rotationProgressTask = nil
            }
        } else if rotationProgressTask == nil {
            let progress = detector.rotationSequenceProgress
            // The detector remains latched after recognition until the wearer pauses.
            rotationProgress = progress < Self.practiceBeatCount ? progress : 0
        }
    }

    private func resetBobblehead() {
        headAttitude = nil
        verticalBounce = 0
        rhythmPulse = nil
        lastShownRotationStart = nil
        clearRotationProgress()
    }

    private func clearRotationProgress() {
        rotationProgressTask?.cancel()
        rotationProgressTask = nil
        rotationProgress = 0
    }

    private func showFeedback(for signal: ComparisonSignal) {
        feedbackTasks[signal]?.cancel()
        showingBops.insert(signal)
        feedbackTasks[signal] = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.showingBops.remove(signal)
            self.feedbackTasks.removeValue(forKey: signal)
        }
    }

    private func clearFeedback() {
        for task in feedbackTasks.values { task.cancel() }
        feedbackTasks.removeAll()
        showingBops.removeAll()
        menuBopEvent = nil
    }
}
