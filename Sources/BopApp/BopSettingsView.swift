import AppKit
import BopCore
import SwiftUI

struct BopSettingsView: View {
    enum Section: String, CaseIterable {
        case general = "General"
        case music = "Music"

        var symbol: String {
            switch self {
            case .general: "slider.horizontal.3"
            case .music: "music.note"
            }
        }
    }

    let session: BopSession
    let spotify: SpotifyIntegration
    @Binding var section: Section
    @Binding var showBopCue: Bool
    let showAirPodsSetup: () -> Void
    let showMotionGraphs: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            sidebar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(section.rawValue)
                        .font(.title2.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)

                    switch section {
                    case .general: generalSettings
                    case .music: musicSettings
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(22)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 550, minHeight: 320)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Section.allCases, id: \.self) { item in
                Button {
                    section = item
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: item.symbol)
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                            .accessibilityHidden(true)
                        Text(item.rawValue)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .background {
                        if item == section {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.primary.opacity(0.10))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(item == section ? .isSelected : [])
            }
            Spacer()
        }
        .padding(10)
        .frame(width: 144)
        .frame(maxHeight: .infinity)
        .background(.regularMaterial)
    }

    private var generalSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            BopSettingsGroup {
                BopSettingsRow {
                    BopSettingsLabel("AirPods", detail: airPodsStatus)
                } control: {
                    Button("Set Up…", action: showAirPodsSetup)
                        .accessibilityLabel("Set up AirPods")
                }

                Divider()

                BopSettingsRow {
                    BopSettingsLabel("Bop sensitivity", detail: BopSensitivitySlider.helpText)
                        .accessibilityHidden(true)
                } control: {
                    BopSensitivitySlider(session: session, signal: .rotation, label: "Bop sensitivity", width: 116)
                }

                Divider()

                BopSettingsRow {
                    BopSettingsLabel("Show bop cue", detail: "Show a brief cue when Bop detects a rhythm.")
                        .accessibilityHidden(true)
                } control: {
                    Toggle("Show bop cue", isOn: $showBopCue)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityHint("Show a brief cue when Bop detects a rhythm.")
                }
            }

            DisclosureGroup("Advanced") {
                BopSettingsGroup {
                    BopSettingsRow {
                        BopSettingsLabel("Motion graphs", detail: "Inspect, record, and replay motion.")
                    } control: {
                        Button("Open…", action: showMotionGraphs)
                            .accessibilityLabel("Open motion graphs")
                    }
                }
                .padding(.top, 7)
            }
        }
    }

    private var musicSettings: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Integrations")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            SpotifySettingsView(spotify: spotify)
        }
    }

    private var airPodsStatus: String {
        if session.motionStatus == .streaming { return "Connected" }
        if session.isLive || session.motionStatus != nil { return session.status }
        return "Listening is off"
    }
}

struct BopSensitivitySlider: View {
    static let helpText = "Higher sensitivity detects smaller movements."

    private struct ValueChange: Equatable {
        let from: Double
        let to: Double
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var valueChange: ValueChange?

    let session: BopSession
    let signal: ComparisonSignal
    let label: LocalizedStringKey
    let width: CGFloat

    var body: some View {
        let value = session.sensitivity(for: signal)
        let format = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...2))
        let sensitivity = Binding(
            get: { session.sensitivity(for: signal) },
            set: { session.setSensitivity($0, for: signal) }
        )

        HStack(spacing: 6) {
            Slider(value: sensitivity, in: BopSignalDetector.sensitivityRange, step: 0.25) {
                Text(label)
            }
            .labelsHidden()
            .frame(width: width)
            .disabled(session.isReplaying)
            .accessibilityLabel(Text(label))
            .accessibilityValue("\(value, format: format) times")
            .accessibilityHint(Self.helpText)
            KeyframeAnimator(initialValue: 1.0, trigger: valueChange) { progress in
                let updatedValue = valueChange?.to ?? value
                let previousValue = valueChange?.from ?? updatedValue
                let slidesRight = (updatedValue > previousValue) == (layoutDirection == .leftToRight)
                let direction = slidesRight ? 1.0 : -1.0
                let distance = reduceMotion ? 0 : 6 * direction

                ZStack {
                    if valueChange != nil {
                        Text("\(previousValue, format: format)×")
                            .offset(x: distance * progress)
                            .opacity(1 - progress)
                    }
                    Text("\(updatedValue, format: format)×")
                        .offset(x: -distance * (1 - progress))
                        .opacity(progress)
                }
                .monospacedDigit()
            } keyframes: { _ in
                MoveKeyframe(0)
                LinearKeyframe(1, duration: 0.16, timingCurve: .easeOut)
            }
            .frame(width: 48)
            .clipped()
            .accessibilityHidden(true)
            .onChange(of: value) { previousValue, updatedValue in
                valueChange = ValueChange(from: previousValue, to: updatedValue)
            }
        }
        .help(Self.helpText)
    }
}

struct BopSettingsGroup<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(.quaternary, lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }
}

struct BopSettingsRow<Label: View, Control: View>: View {
    @ViewBuilder let label: () -> Label
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(spacing: 12) {
            label()
            Spacer(minLength: 0)
            control()
                .fixedSize()
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 11)
    }
}

struct BopSettingsLabel: View {
    let title: LocalizedStringKey
    let detail: String?

    init(_ title: LocalizedStringKey, detail: String? = nil) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).fontWeight(.medium)
            if let detail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
