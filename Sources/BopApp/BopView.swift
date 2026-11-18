import AppKit
import BopCore
import Charts
import SwiftUI
import UniformTypeIdentifiers

struct BopView: View {
    private typealias AccelerationThresholds = (start: Double, end: Double)

    private static let startGuide = StrokeStyle(lineWidth: 1, dash: [6, 4])
    private static let endGuide = StrokeStyle(lineWidth: 1, dash: [1, 3])

    @Bindable var session: BopSession
    let startListening: () -> Void
    @State private var isShowingComparison = false
    @State private var recordingSaveError: String?

    var body: some View {
        let history = session.history
        let latestTimestamp = history.last?.timestamp ?? 0

        return VStack(alignment: .leading, spacing: 14) {
            header
            VStack(alignment: .leading, spacing: 12) {
                ForEach(ComparisonSignal.allCases, id: \.self) { signal in
                    signalGraph(signal, history: history, latestTimestamp: latestTimestamp)
                }
            }
            controls
        }
        .padding(20)
        .frame(minWidth: 650, minHeight: 550)
        .sheet(isPresented: $isShowingComparison) {
            if let comparison = session.comparison {
                BopComparisonView(result: comparison, rotationMethod: session.rotationMethod)
            }
        }
        .alert("Couldn’t Save Recording", isPresented: Binding(
            get: { recordingSaveError != nil },
            set: { if !$0 { recordingSaveError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(recordingSaveError ?? "")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Bop")
                    .font(.largeTitle.bold())
                Spacer()
                detectorPicker
                axisPicker
            }

            HStack(spacing: 12) {
                Label(session.status, systemImage: statusSymbol)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .layoutPriority(1)
                Spacer(minLength: 0)
                Text(BopSensitivitySlider.helpText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Label("Cycle", systemImage: "circle.fill")
                        .foregroundStyle(.secondary)
                    Label("Bop", systemImage: "diamond.fill")
                        .foregroundStyle(Color.green)
                }
                .font(.caption)
                .fixedSize()
            }
        }
    }

    private var statusSymbol: String {
        if session.isRecording { return "record.circle" }
        if session.isReplaying { return "play.circle" }
        return "headphones"
    }

    private func signalGraph(
        _ signal: ComparisonSignal,
        history: [BopSignalFrame],
        latestTimestamp: Double
    ) -> some View {
        let count = session.bopCounts[signal, default: 0]
        let axes = displayedRotationAxes
        let values = signal == .rotation
            ? history.compactMap(\.rotationTrace).flatMap { trace in axes.map { trace[$0] } }
            : history.compactMap { $0[signal]?.value }
        let minimum = values.min()
        let maximum = values.max() ?? 0
        let thresholds = signal == .verticalAcceleration
            ? BopSignalDetector.verticalAccelerationThresholds(sensitivity: session.sensitivity(for: signal))
            : nil
        let range = signal.graphRange(low: minimum ?? 0, high: max(maximum, thresholds?.start ?? maximum))

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text(signal.graphTitle)
                    .font(.headline)
                if signal == .rotation {
                    rotationLegend
                }
                if session.showingBops.contains(signal) {
                    BopLettering(width: 32)
                        .foregroundStyle(Color.green)
                        .accessibilityLabel("Bop detected")
                }
                Spacer(minLength: 0)
                Text(count == 1 ? "1 bop" : "\(count) bops")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
                sensitivityControl(for: signal)
            }

            if let thresholds {
                accelerationLegend(thresholds)
            }

            motionChart(signal, history: history, latestTimestamp: latestTimestamp, range: range, thresholds: thresholds)
                .frame(minHeight: signal == .verticalAcceleration ? 105 : 88)
                .overlay {
                    if minimum == nil {
                        Text(history.isEmpty ? "No motion samples yet" : "Signal unavailable in this window")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(8)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                            .allowsHitTesting(false)
                    }
                }
        }
    }

    private var displayedRotationAxes: [RotationAxis] {
        session.axis.map { [$0] } ?? RotationAxis.allCases
    }

    private var rotationLegend: some View {
        HStack(spacing: 8) {
            ForEach(displayedRotationAxes, id: \.self) { axis in
                HStack(spacing: 4) {
                    lineSwatch(axis.traceColor, style: axis.traceStyle, width: 15)
                    Text(axis.traceLabel)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(axis.traceLabel) axis")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize()
    }

    private func accelerationLegend(_ thresholds: AccelerationThresholds) -> some View {
        HStack(spacing: 14) {
            thresholdKey("Start", magnitude: thresholds.start, style: Self.startGuide)
                .help("Crossing the outer line begins a stroke. The guides reflect the current sensitivity.")
            thresholdKey("End", magnitude: thresholds.end, style: Self.endGuide)
                .help("Returning inside the inner line ends a stroke. A stroke needs sustained motion and enough accumulated acceleration to count.")
            Text("Three evenly spaced out-and-back cycles make a bop.")
                .foregroundStyle(.secondary)
        }
        .font(.caption)
    }

    private func thresholdKey(_ label: String, magnitude: Double, style: StrokeStyle) -> some View {
        let level = magnitude.formatted(.number.precision(.fractionLength(3)))

        return HStack(spacing: 5) {
            lineSwatch(.orange, style: style, width: 20)
            Text("\(label) ±\(level) g")
                .monospacedDigit()
        }
        .fixedSize()
    }

    private func lineSwatch(_ color: Color, style: StrokeStyle, width: CGFloat) -> some View {
        Path { path in
            path.move(to: CGPoint(x: 0, y: 2))
            path.addLine(to: CGPoint(x: width, y: 2))
        }
        .stroke(color, style: style)
        .frame(width: width, height: 4)
        .accessibilityHidden(true)
    }

    private func sensitivityControl(for signal: ComparisonSignal) -> some View {
        HStack(spacing: 6) {
            Text("Sensitivity")
                .accessibilityHidden(true)
            BopSensitivitySlider(
                session: session, signal: signal, label: "Sensitivity for \(signal.graphTitle)", width: 92
            )
            .controlSize(.small)
        }
        .font(.caption)
        .fixedSize()
    }

    private func motionChart(
        _ signal: ComparisonSignal,
        history: [BopSignalFrame],
        latestTimestamp: Double,
        range: ClosedRange<Double>,
        thresholds: AccelerationThresholds?
    ) -> some View {
        let ticks = [range.lowerBound, (range.lowerBound + range.upperBound) / 2, range.upperBound]
        let rotationAxes = displayedRotationAxes
        let selectedAxis = session.axis

        return Chart {
            if range.contains(0) {
                RuleMark(y: .value("Zero", 0.0))
                    .foregroundStyle(.secondary.opacity(0.5))
            }

            if let thresholds {
                ForEach([-1.0, 1.0], id: \.self) { direction in
                    RuleMark(y: .value("Stroke start (g)", direction * thresholds.start))
                        .foregroundStyle(Color.orange)
                        .lineStyle(Self.startGuide)
                    RuleMark(y: .value("Stroke end (g)", direction * thresholds.end))
                        .foregroundStyle(Color.orange)
                        .lineStyle(Self.endGuide)
                }
            }

            ForEach(history, id: \.timestamp) { frame in
                let time = frame.timestamp - latestTimestamp
                if signal == .rotation, let trace = frame.rotationTrace {
                    ForEach(rotationAxes, id: \.self) { axis in
                        LineMark(
                            x: .value("Time", time),
                            y: .value("\(axis.traceLabel) rotation (rad/s)", trace[axis]),
                            series: .value("Axis and segment", "\(axis.rawValue)-\(trace.segmentID)")
                        )
                        .foregroundStyle(axis.traceColor)
                        .lineStyle(axis.traceStyle)
                    }
                }

                if let point = frame[signal], signal != .rotation {
                    LineMark(
                        x: .value("Time", time),
                        y: .value("Motion", point.value),
                        series: .value("Motion segment", point.segmentID)
                    )
                    .foregroundStyle(Color.accentColor)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
            }

            ForEach(history, id: \.timestamp) { frame in
                if let point = frame[signal] {
                    let time = frame.timestamp - latestTimestamp
                    let markerValue = signal == .rotation && selectedAxis == nil ? 0 : point.value
                    if point.didBop {
                        PointMark(x: .value("Time", time), y: .value("Motion", markerValue))
                            .foregroundStyle(Color.green)
                            .symbol(.diamond)
                            .symbolSize(65)
                    } else if point.didCycle {
                        PointMark(x: .value("Time", time), y: .value("Motion", markerValue))
                            .foregroundStyle(Color.gray)
                            .symbol(.circle)
                            .symbolSize(28)
                    }
                }
            }
        }
        .chartXScale(domain: -4.0...0.0, range: .plotDimension(padding: 4))
        .chartYScale(domain: range, range: .plotDimension(padding: 4))
        .chartXAxis {
            AxisMarks(values: [-4.0, -3.0, -2.0, -1.0, 0.0]) { value in
                AxisGridLine()
                if signal == .verticalAcceleration, let time = value.as(Double.self) {
                    AxisTick()
                    if time == 0 {
                        AxisValueLabel(anchor: .topTrailing, collisionResolution: .disabled) {
                            Text("Latest")
                        }
                    } else {
                        AxisValueLabel { Text("\(Int(-time)) s ago") }
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: ticks) { value in
                AxisGridLine()
                AxisTick()
                AxisValueLabel {
                    if let level = value.as(Double.self) {
                        Text(level, format: .number.precision(.fractionLength(0...(signal == .orientation ? 1 : 2))))
                            .monospacedDigit()
                            .frame(width: 38, alignment: .trailing)
                    }
                }
            }
        }
        .chartPlotStyle { $0.clipped() }
        .accessibilityLabel("\(signal.graphTitle) over the last four seconds")
    }

    private var controls: some View {
        let isRunning = session.isLive || session.isReplaying

        return HStack(spacing: 8) {
            if isRunning {
                Button("Stop", systemImage: "stop.fill", action: session.stop)
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Listen to AirPods", systemImage: "headphones") {
                    startListening()
                }
                .buttonStyle(.borderedProminent)
            }
            Button("Play Demo", systemImage: "play.fill", action: session.playDemo)
                .disabled(isRunning)
            Button(
                session.isRecording ? "Stop Recording" : "Record",
                systemImage: session.isRecording ? "stop.circle" : "record.circle",
                action: session.toggleRecording
            )
            .disabled(!session.isLive && !session.isRecording)
            .help("Record up to 20 seconds of AirPods motion.")
            Button("Replay", systemImage: "arrow.counterclockwise", action: session.replayRecording)
                .disabled(isRunning || !session.canReplayRecording)
            Button("Save Recording…", systemImage: "square.and.arrow.down", action: saveRecording)
                .disabled(session.isRecording || !session.canReplayRecording)
                .help("Save the sensor data as a JSON file.")
            Button("Compare", systemImage: "chart.bar.xaxis") {
                isShowingComparison = true
            }
            .disabled(session.comparison == nil)
            .help("Compare detections from the latest replay or demo.")

            Spacer()
        }
        .buttonStyle(.bordered)
    }

    private func saveRecording() {
        do {
            guard let data = try session.recordedMotionData() else { return }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "Bop Recording"
            panel.allowedContentTypes = [.json]
            panel.begin { response in
                guard response == .OK, let url = panel.url else { return }
                do {
                    try data.write(to: url, options: .atomic)
                } catch {
                    recordingSaveError = error.localizedDescription
                }
            }
        } catch {
            recordingSaveError = error.localizedDescription
        }
    }

    private var detectorPicker: some View {
        Picker("Detector", selection: Binding(
            get: { session.rotationMethod },
            set: session.setRotationMethod
        )) {
            ForEach(RotationDetectionMethod.allCases, id: \.self) { method in
                Text(method.title).tag(method)
            }
        }
        .pickerStyle(.menu)
        .fixedSize()
        .disabled(session.isRecording || session.isReplaying)
        .help("Choose how Bop detects rhythmic head rotation. Changing detectors starts a fresh count.")
    }

    private var axisPicker: some View {
        Picker("Rotation axis", selection: $session.axis) {
            Text("Auto").tag(nil as RotationAxis?)
            ForEach(RotationAxis.allCases, id: \.self) { axis in
                Text(axis.rawValue.uppercased()).tag(Optional(axis))
            }
        }
        .pickerStyle(.segmented)
        .fixedSize()
        .disabled(session.isLive || session.isReplaying)
        .help("Auto shows all three axes. Choose X, Y, or Z to focus rotation detection on one axis.")
    }
}

extension RotationDetectionMethod {
    var title: String {
        switch self {
        case .nodRhythm: "Nod rhythm"
        case .autocorrelation: "Autocorrelation"
        }
    }
}

private extension ComparisonSignal {
    var graphTitle: String {
        switch self {
        case .rotation: "Rotation rate (rad/s)"
        case .orientation: "Orientation (° from first pose)"
        case .verticalAcceleration: "Vertical acceleration (g)"
        }
    }

    func graphRange(low: Double, high: Double) -> ClosedRange<Double> {
        let scale: (minimum: Double, step: Double)
        switch self {
        case .rotation:
            scale = (0.25, 0.25)
        case .orientation:
            // A change in posture can shift the trace far from zero.
            let floor = (low / 2).rounded(.down) * 2
            let ceiling = max(floor + 4, (high / 2).rounded(.up) * 2)
            return floor...ceiling
        case .verticalAcceleration:
            // Keep the scale steady for the start guides at most slider positions.
            scale = (0.10, 0.05)
        }

        let peak = max(abs(low), abs(high))
        let limit = max(scale.minimum, (peak / scale.step).rounded(.up) * scale.step)
        return -limit...limit
    }
}

private extension RotationAxis {
    var traceLabel: String { rawValue.uppercased() }

    var traceColor: Color {
        switch self {
        case .x: .blue
        case .y: .purple
        case .z: .orange
        }
    }

    var traceStyle: StrokeStyle {
        let dash: [CGFloat] = switch self {
        case .x: []
        case .y: [5, 3]
        case .z: [1, 3]
        }
        return StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: dash)
    }
}
