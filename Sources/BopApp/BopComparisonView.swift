import BopCore
import Charts
import SwiftUI

struct BopComparisonView: View {
    let result: BopComparisonResult
    let rotationMethod: RotationDetectionMethod

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Detector comparison")
                    .font(.title2.weight(.semibold))
                Text("Both rotation detectors use the same clip. Combined uses \(rotationMethod.title) with orientation and acceleration.")
                    .foregroundStyle(.secondary)
            }

            timeline
                .frame(height: 266)

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 640)
    }

    private var timeline: some View {
        let rows = timelineRows

        return Chart {
            ForEach(rows) { row in
                RuleMark(
                    xStart: .value("Clip start", 0.0),
                    xEnd: .value("Clip end", result.duration),
                    y: .value("Signal", row.lane)
                )
                .foregroundStyle(.secondary.opacity(0.3))
                .lineStyle(StrokeStyle(dash: row.hasData ? [] : [4, 4]))

                if row.hasData {
                    ForEach(row.detectionTimes, id: \.self) { time in
                        PointMark(x: .value("Detection time", time), y: .value("Signal", row.lane))
                            .foregroundStyle(row.isCombined ? Color.green : Color.accentColor)
                            .symbol(.diamond)
                            .symbolSize(65)
                            .accessibilityLabel(row.title)
                            .accessibilityValue("\(time, format: .number.precision(.fractionLength(0...2))) seconds")
                            .annotation(position: .top, spacing: 3) {
                                if row.showsDetectionTimes {
                                    Text("\(time, format: .number.precision(.fractionLength(0...2))) s")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .accessibilityHidden(true)
                                }
                            }
                    }
                }
            }
        }
        .chartXScale(domain: 0.0...max(0.1, result.duration), range: .plotDimension(padding: 6))
        .chartYScale(domain: -0.5...4.5)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { value in
                AxisGridLine()
                AxisTick()
                AxisValueLabel {
                    if let time = value.as(Double.self) {
                        Text("\(time, format: .number.precision(.fractionLength(0...1))) s")
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: rows.map(\.lane)) { value in
                if let lane = value.as(Double.self),
                   let row = rows.first(where: { $0.lane == lane }) {
                    AxisValueLabel {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(row.title)
                                .font(.callout.weight(row.isCombined ? .semibold : .medium))
                                .foregroundStyle(.primary)
                            Text(row.detail)
                                .font(.caption)
                                .foregroundStyle(.primary)
                        }
                    }
                }
            }
        }
        .accessibilityLabel("Bop detections over the full clip")
    }

    private var timelineRows: [TimelineRow] {
        let rotation = result.signals.first { $0.signal == .rotation }
        let rotationRows = RotationDetectionMethod.allCases.enumerated().map { index, method in
            let times = result.rotationDetectionTimes[method, default: []]
            return TimelineRow(
                lane: Double(4 - index),
                title: "Rotation · \(method.title)",
                detail: detail(for: rotation, detectionCount: times.count),
                detectionTimes: times,
                hasData: rotation?.hasData == true,
                isCombined: false,
                showsDetectionTimes: true
            )
        }
        let sensorRows = [ComparisonSignal.orientation, .verticalAcceleration].map { signal in
            let signalResult = result.signals.first { $0.signal == signal }
            return TimelineRow(
                lane: signal.lane,
                title: signal.title,
                detail: detail(for: signalResult),
                detectionTimes: signalResult?.detectionTimes ?? [],
                hasData: signalResult?.hasData == true,
                isCombined: false,
                showsDetectionTimes: false
            )
        }
        let combined = result.combined
        return rotationRows + sensorRows + [TimelineRow(
            lane: 0,
            title: "Combined",
            detail: combined.hasData ? "\(combined.detectionTimes.count) detected" : "Unavailable",
            detectionTimes: combined.detectionTimes,
            hasData: combined.hasData,
            isCombined: true,
            showsDetectionTimes: false
        )]
    }

    private func detail(for signalResult: BopComparisonResult.SignalResult?, detectionCount: Int? = nil) -> String {
        guard let signalResult, signalResult.hasData else { return "Unavailable" }
        let sensitivity = signalResult.sensitivity.formatted(.number.precision(.fractionLength(0...2)))
        let count = detectionCount ?? signalResult.detectionTimes.count
        let detection = "\(count) detected at \(sensitivity)×"
        return signalResult.signal == .rotation ? detection : "\(detection) · Experimental"
    }

    private struct TimelineRow: Identifiable {
        let lane: Double
        let title: String
        let detail: String
        let detectionTimes: [Double]
        let hasData: Bool
        let isCombined: Bool
        let showsDetectionTimes: Bool

        var id: Double { lane }
    }
}

private extension ComparisonSignal {
    var lane: Double {
        switch self {
        case .rotation: 3
        case .orientation: 2
        case .verticalAcceleration: 1
        }
    }

    var title: String {
        switch self {
        case .rotation: "Rotation rate"
        case .orientation: "Head orientation"
        case .verticalAcceleration: "Vertical acceleration"
        }
    }
}
