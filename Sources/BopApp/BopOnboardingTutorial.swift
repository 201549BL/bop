import Accessibility
import AppKit
import AVFoundation
import SwiftUI

struct BopOnboardingTutorial: View {
    private struct Media {
        static let light = Media("OnboardingTutorial")
        static let dark = Media("OnboardingTutorialDark")

        let movie: URL?
        let poster: NSImage?

        init(_ name: String) {
            movie = Bundle.main.url(forResource: name, withExtension: "mp4")
            poster = Bundle.main.url(forResource: "\(name)Poster", withExtension: "png")
                .flatMap(NSImage.init(contentsOf:))
        }
    }

    private struct Playback: Equatable {
        let replay: Int
        let reduceMotion: Bool
        let colorScheme: ColorScheme
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var replay = 0
    @State private var phase = TutorialPhase.atDesk
    @State private var player: AVPlayer?

    private var palette: OnboardingPalette { OnboardingPalette(colorScheme) }
    private var media: Media { palette.isDark ? .dark : .light }

    var body: some View {
        VStack(spacing: 0) {
            scene.aspectRatio(960.0 / 508.0, contentMode: .fit)
            Divider().overlay(palette.border)
            nodProgress
        }
        .background(palette.background)
        .frame(maxWidth: 480)
        .clipShape(.rect(cornerRadius: 13))
        .overlay { RoundedRectangle(cornerRadius: 13).strokeBorder(palette.border).allowsHitTesting(false) }
        .task(id: Playback(replay: replay, reduceMotion: reduceMotion, colorScheme: colorScheme)) {
            await playTutorial()
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }

    private var scene: some View {
        GeometryReader { geometry in
            ZStack {
                if let poster = media.poster {
                    Image(nsImage: poster)
                        .resizable()
                        .accessibilityHidden(true)
                }

                if let player {
                    OnboardingTutorialVideo(player: player)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }

                TutorialBopCue(
                    bounds: geometry.size,
                    isSent: phase == .sent,
                    reduceMotion: reduceMotion || player == nil,
                    palette: palette
                )
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .background(palette.studioGradient)
        }
    }

    private var nodProgress: some View {
        HStack(spacing: 7) {
            ForEach(0..<TutorialPhase.sent.nodCount, id: \.self) { index in
                Circle()
                    .fill(index < phase.nodCount ? palette.foreground : palette.inactive)
                    .frame(width: 8, height: 8)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: phase.nodCount)
        .accessibilityHidden(true)
        .frame(maxWidth: .infinity)
        .frame(height: 40)
        .overlay(alignment: .trailing) {
            if phase == .sent, player != nil {
                Button {
                    replay += 1
                } label: {
                    Label("Replay", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(OnboardingButtonStyle(.quiet))
                .accessibilityLabel("Replay tutorial")
                .padding(.trailing, 9)
            }
        }
    }

    private enum PlaybackError: Error {
        case failed
    }

    private func playTutorial() async {
        guard !Task.isCancelled else { return }
        player = nil

        guard !reduceMotion, let movie = media.movie else {
            phase = .sent
            return
        }

        let item = AVPlayerItem(url: movie)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        phase = .atDesk
        self.player = player

        let (phases, updates) = AsyncThrowingStream<TutorialPhase, any Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 24), queue: .main
        ) { time in
            updates.yield(TutorialPhase(time: time.seconds))
        }
        let statusObserver = item.observe(\.status, options: [.initial, .new]) { item, _ in
            if item.status == .failed { updates.finish(throwing: PlaybackError.failed) }
        }
        let endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { _ in
            updates.yield(.sent)
            updates.finish()
        }
        defer {
            NotificationCenter.default.removeObserver(endObserver)
            statusObserver.invalidate()
            player.removeTimeObserver(timeObserver)
            player.pause()
        }

        player.play()
        do {
            for try await phase in phases {
                guard !Task.isCancelled else { return }
                if self.phase != phase {
                    self.phase = phase
                    if phase == .sent {
                        AccessibilityNotification.Announcement("Bop sent in the tutorial.").post()
                    }
                }
            }
        } catch {
            guard !Task.isCancelled else { return }
            self.player = nil
            phase = .sent
        }
    }
}

struct BopOnboardingMenuPreview: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var replay = 0
    @State private var cueStart: Date?
    @State private var showsFeedback = false

    private var palette: OnboardingPalette { OnboardingPalette(colorScheme) }

    var body: some View {
        VStack(spacing: 0) {
            menuBar
            Divider().overlay(palette.border)
            ZStack {
                palette.desktopGradient

                Button("Preview a bop") { replay += 1 }
                    .buttonStyle(OnboardingButtonStyle(.secondary))
                    .accessibilityHint("Shows how the menu bar responds to a bop")
            }
            .frame(height: 99)
            .overlay(alignment: .topTrailing) {
                BopFeedbackContent(detail: nil)
                    .fixedSize()
                    .padding(7)
                    .opacity(showsFeedback ? 1 : 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: 480)
        .clipShape(.rect(cornerRadius: 13))
        .overlay { RoundedRectangle(cornerRadius: 13).strokeBorder(palette.border).allowsHitTesting(false) }
        .task(id: PreviewPlayback(replay: replay, reduceMotion: reduceMotion)) {
            await playCue()
        }
        .onDisappear {
            cueStart = nil
            showsFeedback = false
        }
    }

    private var menuBar: some View {
        HStack(spacing: 13) {
            Text("Finder").fontWeight(.semibold)
            Text("File")
            Text("Edit")
            Text("View")
            Spacer()

            TimelineView(.animation(paused: cueStart == nil || reduceMotion)) { timeline in
                let jumpTime = reduceMotion ? nil : cueStart.map { start in
                    min(BopMenuWordmark.animationDuration, max(0, timeline.date.timeIntervalSince(start)))
                }
                BopMenuWordmark(isListening: true, isDetected: cueStart != nil, jumpTime: jumpTime)
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(palette.background)
        .foregroundStyle(palette.foreground)
        .accessibilityHidden(true)
    }

    private func playCue() async {
        guard !Task.isCancelled else { return }
        cueStart = nil
        showsFeedback = false
        if reduceMotion && replay == 0 { return }

        do {
            if replay == 0 { try await Task.sleep(for: .milliseconds(550)) }
            try Task.checkCancellation()
            cueStart = .now
            showsFeedback = true
            if replay > 0 {
                AccessibilityNotification.Announcement("Preview of a bop detection.").post()
            }
            try await Task.sleep(for: .seconds(BopMenuWordmark.detectionDuration))
            cueStart = nil
            try await Task.sleep(for: .seconds(2.4 - BopMenuWordmark.detectionDuration))
            showsFeedback = false
        } catch {
            return
        }
    }
}

private struct PreviewPlayback: Equatable {
    let replay: Int
    let reduceMotion: Bool
}

private struct TutorialBopCue: View {
    private struct Pose {
        var travel: CGFloat = 0
        var letteringOpacity = 0.0
        var confirmationOpacity = 0.0
    }

    let bounds: CGSize
    let isSent: Bool
    let reduceMotion: Bool
    let palette: OnboardingPalette

    var body: some View {
        Group {
            if reduceMotion {
                cue(at: Pose(travel: 1, letteringOpacity: 1, confirmationOpacity: 1))
            } else {
                Color.clear.keyframeAnimator(initialValue: Pose(), trigger: isSent) { _, pose in
                    cue(at: pose)
                } keyframes: { _ in
                    KeyframeTrack(\.travel) {
                        MoveKeyframe(0)
                        SpringKeyframe(1, duration: 0.52, spring: Spring(duration: 0.44, bounce: 0.33))
                    }
                    KeyframeTrack(\.letteringOpacity) {
                        MoveKeyframe(0)
                        LinearKeyframe(1, duration: 0.07)
                    }
                    KeyframeTrack(\.confirmationOpacity) {
                        MoveKeyframe(0)
                        LinearKeyframe(0, duration: 0.28)
                        LinearKeyframe(1, duration: 0.18, timingCurve: .easeOut)
                    }
                }
            }
        }
        .opacity(isSent ? 1 : 0)
        .allowsHitTesting(false)
        .accessibilityHidden(!isSent)
    }

    private nonisolated func cue(at pose: Pose) -> some View {
        let travel = pose.travel
        let arc = 0.048 * sin(.pi * travel)
        let letteringWidth = bounds.width * 0.23

        return ZStack {
            BopLettering(width: letteringWidth)
                .foregroundStyle(palette.foreground)
                .scaleEffect(0.2 + 0.8 * travel)
                .rotationEffect(.degrees(-14 * (1 - travel)))
                .opacity(pose.letteringOpacity)
                .position(x: bounds.width * (0.47 + 0.31 * travel), y: bounds.height * (0.34 - arc))
                .accessibilityHidden(true)

            Label("Bop sent", systemImage: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(palette.success)
                .opacity(pose.confirmationOpacity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Bop sent")
                .position(x: bounds.width * 0.78, y: bounds.height * 0.34 + letteringWidth * 0.29 + 16)
        }
    }
}

private enum TutorialPhase: Equatable {
    case atDesk, firstNod, sent

    init(time: Double) {
        // Match the first two nods' return poses in the tutorial render.
        switch time {
        case (81.0 / 24)...: self = .sent
        case (67.0 / 24)...: self = .firstNod
        default: self = .atDesk
        }
    }

    var nodCount: Int {
        switch self {
        case .atDesk: 0
        case .firstNod: 1
        case .sent: 2
        }
    }
}

private struct OnboardingTutorialVideo: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let layer = AVPlayerLayer()
        layer.videoGravity = .resizeAspect
        view.layer = layer
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        (view.layer as? AVPlayerLayer)?.player = player
    }
}
