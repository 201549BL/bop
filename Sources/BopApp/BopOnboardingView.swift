import Accessibility
import AppKit
import SwiftUI

struct BopOnboardingView: View {
    private enum Step: Int, CaseIterable {
        case welcome, connect, tutorial, practice, menuBar
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.layoutDirection) private var layoutDirection
    @AccessibilityFocusState private var focusedStep: Step?
    @State private var step = Step.welcome
    @State private var movesForward = true
    @State private var resumeStep: Step?
    @State private var startedConnection = false
    @State private var hasDetectedBop = false

    let session: BopSession
    let completeSetup: () -> Void
    let deferSetup: () -> Void

    private var isConnected: Bool { session.motionStatus == .streaming }
    private var palette: OnboardingPalette { OnboardingPalette(colorScheme) }

    private var stepAnimation: Animation {
        .easeInOut(duration: reduceMotion ? 0.15 : 0.26)
    }

    private var stepTransition: AnyTransition {
        if reduceMotion { return .opacity }
        let entersFromRight = movesForward == (layoutDirection == .leftToRight)
        return .asymmetric(
            insertion: .offset(x: entersFromRight ? 18 : -18).combined(with: .opacity),
            removal: .opacity
        )
    }

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                stepPage
                    .id(step)
                    .transition(stepTransition)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .animation(stepAnimation, value: step)

            footer
        }
        .foregroundStyle(palette.foreground)
        .padding(.horizontal, 20)
        .padding(.bottom, 4)
        .frame(minWidth: 500, maxWidth: .infinity, minHeight: 560, maxHeight: .infinity)
        .background(palette.background)
        .task(id: step) {
            await Task.yield()
            guard !Task.isCancelled else { return }
            focusedStep = step
        }
        .onChange(of: isConnected) { _, connected in connectionChanged(connected) }
        .onChange(of: session.menuBopEvent) { _, event in
            guard step == .practice, !hasDetectedBop, event != nil else { return }
            hasDetectedBop = true
            AccessibilityNotification.Announcement("Bop detected.").post()
        }
    }

    @ViewBuilder
    private var stepPage: some View {
        switch step {
        case .welcome: welcome
        case .connect: connection
        case .tutorial: tutorial
        case .practice: practice
        case .menuBar: menuBar
        }
    }

    private var welcome: some View {
        page {
            VStack(spacing: 24) {
                ZStack {
                    Circle()
                        .fill(RadialGradient(colors: [palette.panel, palette.background], center: .center,
                                             startRadius: 28, endRadius: 65))
                        .frame(width: 145, height: 124)

                    Image(.bopLettering)
                        .resizable()
                        .frame(width: 84, height: 84)
                        .clipShape(.rect(cornerRadius: 23))
                        .shadow(color: .black.opacity(0.23), radius: 8, y: 6)
                }
                .accessibilityHidden(true)

                VStack(spacing: 8) {
                    heading("Welcome to Bop")
                    caption("Bop detects when you nod in rhythm.")
                }
            }
        } actions: {
            VStack(spacing: 1) {
                primaryButton("Get Started") { move(to: .connect) }
                Button("Set Up Later", action: deferSetup)
                    .buttonStyle(OnboardingButtonStyle(.quiet))
            }
        }
    }

    private var connection: some View {
        page {
            VStack(spacing: 16) {
                VStack(spacing: 8) {
                    heading("Connect your AirPods")
                    caption("Bop uses their motion sensors to pick up your nods.")
                }

                VStack(spacing: 0) {
                    permissionRow("AirPods", message: "Put them on and connect them to this Mac.", icon: "airpods")
                    Divider().overlay(palette.border)
                    permissionRow("Motion access", message: "Choose Allow if macOS asks.", icon: "waveform")
                }
                .frame(maxWidth: 435)
                .background(palette.panel, in: .rect(cornerRadius: 13))
                .overlay { panelBorder }

                if let connectionFeedback {
                    caption(connectionFeedback, size: 13)
                        .frame(maxWidth: 435)
                }
            }
        } actions: {
            if isConnected {
                primaryButton("Continue", action: continueAfterConnection)
            } else if session.isLive {
                VStack(spacing: 1) {
                    if startedConnection {
                        Button("Cancel", action: cancelConnection)
                            .buttonStyle(OnboardingButtonStyle(.secondary))
                    }
                    Button("Set Up Later", action: deferSetup)
                        .buttonStyle(OnboardingButtonStyle(.quiet))
                }
            } else {
                VStack(spacing: 1) {
                    HStack(spacing: 8) {
                        if session.motionStatus != .restricted {
                            primaryButton(session.motionStatus == .denied ? "Try Again" : "Connect AirPods",
                                          action: connectAirPods)
                        }
                        if session.motionStatus == .denied {
                            Button("Open System Settings", action: openMotionSettings)
                                .buttonStyle(OnboardingButtonStyle(.secondary))
                        }
                    }

                    Button("Set Up Later", action: deferSetup)
                        .buttonStyle(OnboardingButtonStyle(.quiet))
                }
            }
        }
    }

    private var tutorial: some View {
        page {
            VStack(spacing: 16) {
                VStack(spacing: 8) {
                    heading("How Bop works")
                    caption("Nod along to a beat to make a bop.")
                }

                BopOnboardingTutorial()
            }
        } actions: {
            primaryButton("Give It a Go", action: beginPractice)
        }
    }

    private var practice: some View {
        page {
            VStack(spacing: 14) {
                heading("Now it’s your turn")

                VStack(spacing: 4) {
                    HStack(spacing: 6) {
                        if isConnected {
                            Circle()
                                .fill(palette.success)
                                .frame(width: 6, height: 6)
                                .accessibilityHidden(true)
                        }
                        Text(isConnected ? "AirPods connected" : session.status)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(palette.muted)
                    }
                    .padding(.top, 10)

                    BobbleheadPracticeView(session: session)
                        .frame(height: 270)
                        .frame(maxWidth: .infinity)

                    beatDots(session.rotationProgress, total: BopSession.practiceBeatCount)
                        .padding(.bottom, 10)
                }
                .frame(maxWidth: 480)
                .background(palette.studioGradient)
                .clipShape(.rect(cornerRadius: 13))
                .overlay { panelBorder }

                caption(hasDetectedBop ? "Bop detected. Keep nodding in rhythm." : "Nod up and down in rhythm, with or without the beat.")
            }
        } actions: {
            HStack(spacing: 12) {
                if isConnected {
                    PracticeBeatButton()
                }
                if hasDetectedBop {
                    primaryButton("Continue") { move(to: .menuBar) }
                } else {
                    Button("Skip Practice") { move(to: .menuBar) }
                        .buttonStyle(OnboardingButtonStyle(.secondary))
                }
            }
        }
    }

    private var menuBar: some View {
        page {
            VStack(spacing: 16) {
                VStack(spacing: 8) {
                    heading("Bop in the menu bar")
                    caption(reduceMotion
                            ? "The green dot means Bop is listening. An underline marks each bop."
                            : "The green dot means Bop is listening. The letters hop when you land a bop.")
                }

                BopOnboardingMenuPreview()

                caption("Bop keeps listening when you close its window.")
            }
        } actions: {
            primaryButton("Open Settings", action: finishSetup)
        }
    }

    private var footer: some View {
        ZStack(alignment: .leading) {
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.self) { item in
                    Capsule()
                        .fill(item == step ? palette.foreground : palette.inactive)
                        .frame(width: item == step ? 16 : 5, height: 5)
                }
            }
            .frame(maxWidth: .infinity)
            .animation(reduceMotion ? nil : stepAnimation, value: step)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Step \(step.rawValue + 1) of \(Step.allCases.count)")

            if step != .welcome {
                Button("Back", action: goBack)
                    .buttonStyle(OnboardingButtonStyle(.quiet))
                    .keyboardShortcut(.cancelAction)
            }
        }
        .frame(maxWidth: 670)
        .frame(height: 35)
    }

    private var connectionFeedback: String? {
        switch session.motionStatus {
        case nil, .streaming: nil
        case .waiting: "Looking for compatible AirPods…"
        case .requestingPermission: "Choose Allow when macOS asks for motion access."
        case .connecting: "Checking for motion. Keep your AirPods in your ears."
        case .disconnected: "AirPods disconnected. Waiting to reconnect…"
        case .denied: "Allow Bop under Privacy & Security → Motion & Fitness, then try again."
        case .restricted: "Motion access is restricted on this Mac."
        case .failed: "Waiting for motion data. Keep your AirPods in your ears."
        }
    }

    private var panelBorder: some View {
        RoundedRectangle(cornerRadius: 13)
            .strokeBorder(palette.border)
            .allowsHitTesting(false)
    }

    private func page<Content: View, Actions: View>(
        @ViewBuilder content: () -> Content,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(spacing: 10) {
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, 16)
                .multilineTextAlignment(.center)
            actions()
                .frame(height: 65, alignment: .top)
        }
    }

    private func heading(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 36, weight: .bold))
            .tracking(-1.4)
            .accessibilityAddTraits(.isHeader)
            .accessibilityFocused($focusedStep, equals: step)
    }

    private func caption(_ text: String, size: CGFloat = 15) -> some View {
        Text(text)
            .font(.system(size: size))
            .foregroundStyle(palette.muted)
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(OnboardingButtonStyle(.primary))
            .keyboardShortcut(.defaultAction)
    }

    private func permissionRow(_ title: String, message: String, icon: String) -> some View {
        HStack(spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .frame(width: 33, height: 33)
                .background(palette.iconBackground, in: .rect(cornerRadius: 8))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(palette.muted)
            }
            .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    private func beatDots(_ count: Int, total: Int) -> some View {
        HStack(spacing: 7) {
            ForEach(0..<total, id: \.self) { index in
                Circle()
                    .fill(index < count ? palette.foreground : palette.inactive)
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityHidden(true)
    }

    private func connectAirPods() {
        startedConnection = true
        let window = NSApp.keyWindow
        session.startListening { [weak window] in
            window?.restoreAfterMotionPermission()
        }
    }

    private func cancelConnection() {
        startedConnection = false
        session.stop()
    }

    private func connectionChanged(_ connected: Bool) {
        if connected {
            if step == .connect && (startedConnection || resumeStep != nil) {
                continueAfterConnection()
            }
        } else if step.rawValue > Step.connect.rawValue {
            resumeStep = step
            hasDetectedBop = false
            move(to: .connect)
        }
    }

    private func continueAfterConnection() {
        guard isConnected else { return }
        if resumeStep == .practice {
            beginPractice()
        } else {
            move(to: resumeStep ?? .tutorial)
        }
        resumeStep = nil
    }

    private func move(to nextStep: Step) {
        movesForward = nextStep.rawValue > step.rawValue
        step = nextStep
    }

    private func goBack() {
        switch step {
        case .welcome: break
        case .connect:
            if startedConnection && session.isLive && !isConnected { cancelConnection() }
            resumeStep = nil
            move(to: .welcome)
        case .tutorial: move(to: .connect)
        case .practice: move(to: .tutorial)
        case .menuBar: beginPractice()
        }
    }

    private func beginPractice() {
        guard isConnected else { return }
        session.resetBopDetection()
        hasDetectedBop = false
        move(to: .practice)
    }

    private func finishSetup() {
        guard isConnected else { return }
        completeSetup()
    }

    private func openMotionSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Motion") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct OnboardingPalette {
    let isDark: Bool

    init(_ colorScheme: ColorScheme) {
        isDark = colorScheme == .dark
    }

    var background: Color { isDark ? Color(white: 0.10) : .white }
    var foreground: Color { isDark ? Color(white: 0.95) : .black }
    var pressedPrimary: Color { Color(white: isDark ? 0.76 : 0.23) }
    var muted: Color { Color(white: isDark ? 0.73 : 0.36) }
    var panel: Color { Color(white: isDark ? 0.15 : 0.975) }
    var iconBackground: Color { Color(white: isDark ? 0.22 : 0.92) }
    var border: Color { Color(white: isDark ? 0.30 : 0.87) }
    var inactive: Color { Color(white: isDark ? 0.46 : 0.64) }

    var success: Color {
        isDark ? Color(red: 0.44, green: 0.83, blue: 0.58) : Color(red: 0.16, green: 0.43, blue: 0.29)
    }

    var studioGradient: RadialGradient {
        RadialGradient(
            colors: [isDark ? iconBackground : background, Color(white: isDark ? 0.125 : 0.925)],
            center: .top, startRadius: 5, endRadius: 300
        )
    }

    var desktopGradient: LinearGradient {
        LinearGradient(
            colors: [Color(white: isDark ? 0.25 : 0.92), Color(white: isDark ? 0.15 : 0.74)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }
}

struct OnboardingButtonStyle: ButtonStyle {
    enum Kind {
        case primary, secondary, quiet
    }

    let kind: Kind
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    init(_ kind: Kind) {
        self.kind = kind
    }

    func makeBody(configuration: Configuration) -> some View {
        let palette = OnboardingPalette(colorScheme)
        let labelColor = switch kind {
        case .primary: palette.background
        case .secondary: palette.foreground
        case .quiet: palette.muted
        }

        configuration.label
            .font(.system(size: kind == .quiet ? 12 : 13, weight: .semibold))
            .foregroundStyle(labelColor)
            .padding(.horizontal, kind == .quiet ? 8 : 16)
            .frame(minWidth: kind == .primary ? 168 : nil)
            .frame(height: kind == .quiet ? 26 : 39)
            .background {
                switch kind {
                case .primary:
                    RoundedRectangle(cornerRadius: 9)
                        .fill(configuration.isPressed ? palette.pressedPrimary : palette.foreground)
                case .secondary:
                    RoundedRectangle(cornerRadius: 9)
                        .fill(configuration.isPressed ? palette.panel : palette.background)
                        .strokeBorder(palette.border)
                case .quiet:
                    RoundedRectangle(cornerRadius: 5)
                        .fill(configuration.isPressed ? palette.panel : .clear)
                }
            }
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(.rect)
    }
}
