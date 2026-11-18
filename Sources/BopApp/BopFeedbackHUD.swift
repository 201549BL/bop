import AppKit
import SwiftUI

@MainActor
final class BopFeedbackHUD {
    private var event: Int?
    private var content: BopFeedbackContent?
    private weak var anchor: NSView?
    private var panel: FeedbackPanel?
    private var dismissal: Task<Void, Never>?

    func show(
        event: Int,
        detail: String?,
        awaitingPlayback: Bool,
        anchoredTo anchor: NSView
    ) {
        dismiss()
        let content = BopFeedbackContent(detail: detail, source: awaitingPlayback ? .spotify : nil)
        self.event = event
        self.content = content
        self.anchor = anchor

        let panel = FeedbackPanel()
        self.panel = panel
        guard place(panel, content: content) else {
            dismiss()
            return
        }

        panel.orderFrontRegardless()
        let announcement = detail.map { "Bop detected. \($0)" } ?? "Bop detected"
        announce(announcement, on: panel)
        // Spotify can confirm playback up to three seconds after a bop.
        scheduleDismissal(after: awaitingPlayback ? .seconds(3.2) : .seconds(2.4))
    }

    func update(event: Int, detail: String, track: SpotifyBoppedTrack? = nil) {
        guard event == self.event, let panel, panel.isVisible, let previous = content else { return }
        let content = BopFeedbackContent(detail: detail, source: previous.source, track: track ?? previous.track)
        let trackChanged = content.track != previous.track
        guard detail != previous.detail || trackChanged else { return }
        guard place(panel, content: content) else {
            dismiss()
            return
        }

        self.content = content
        let announcement = trackChanged
            ? [content.title, content.track?.artist, detail].compactMap { $0 }.joined(separator: ". ")
            : detail
        announce(announcement, on: panel)
        scheduleDismissal()
    }

    func dismiss() {
        dismissal?.cancel()
        dismissal = nil
        panel?.orderOut(nil)
        panel = nil
        event = nil
        content = nil
        anchor = nil
    }

    private func scheduleDismissal(after duration: Duration = .seconds(2.4)) {
        dismissal?.cancel()
        dismissal = Task { [weak self] in
            do {
                try await Task.sleep(for: duration)
                try Task.checkCancellation()
                self?.dismiss()
            } catch {
                return
            }
        }
    }

    private func place(_ panel: FeedbackPanel, content: BopFeedbackContent) -> Bool {
        let anchoredPlacement = placementAtAnchor()
        let screen = anchoredPlacement?.screen ?? NSScreen.screens.first {
            $0.frame.contains(NSEvent.mouseLocation)
        } ?? NSScreen.main
        guard let workArea = screen?.visibleFrame.insetBy(dx: 8, dy: 8), !workArea.isEmpty else { return false }

        let controller = NSHostingController(rootView: content)
        let width = min(controller.view.fittingSize.width, workArea.width)
        let size = controller.sizeThatFits(in: CGSize(width: width, height: workArea.height))
        guard size.width > 0, size.height > 0,
              size.width <= workArea.width, size.height <= workArea.height else { return false }

        let centerX = anchoredPlacement?.rect.midX ?? workArea.midX
        let top = min(workArea.maxY, anchoredPlacement.map { $0.rect.minY - 6 } ?? workArea.maxY)
        let left = min(max(centerX - size.width / 2, workArea.minX), workArea.maxX - size.width)
        let bottom = max(top - size.height, workArea.minY)
        panel.contentViewController = controller
        panel.setFrame(NSRect(origin: NSPoint(x: left, y: bottom), size: size), display: true)
        return true
    }

    private func placementAtAnchor() -> (screen: NSScreen, rect: NSRect)? {
        guard let anchor, let window = anchor.window, let screen = window.screen,
              window.isVisible, window.occlusionState.contains(.visible),
              !anchor.isHiddenOrHasHiddenAncestor, !anchor.bounds.isEmpty,
              anchor.visibleRect.contains(anchor.bounds) else { return nil }

        let rect = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        // An auto-hidden menu bar can still leave a status item window on screen.
        guard screen.frame.contains(rect), abs(window.frame.maxY - screen.frame.maxY) <= 2 else { return nil }
        return (screen, rect)
    }

    private func announce(_ message: String, on panel: FeedbackPanel) {
        NSAccessibility.post(
            element: panel,
            notification: .announcementRequested,
            userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.low.rawValue]
        )
    }
}

private final class FeedbackPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        level = .floating
        animationBehavior = .none
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isExcludedFromWindowsMenu = true
    }
}

struct BopFeedbackContent: View {
    enum Source {
        case spotify
    }

    let detail: String?
    var source: Source? = nil
    var track: SpotifyBoppedTrack? = nil

    var title: String {
        if let track { return track.title ?? "Spotify track" }
        return "Bop detected"
    }

    var body: some View {
        HStack(spacing: 8) {
            icon

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                if let artist = track?.artist {
                    Text(artist)
                        .font(.system(size: 11))
                        .foregroundStyle(Color(white: 0.9))
                        .lineLimit(1)
                }
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Color(white: 0.84))
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: 240, alignment: .leading)
        }
        .padding(.vertical, 8)
        .padding(.leading, 8)
        .padding(.trailing, 12)
        .background(Color(white: 0.13), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.white.opacity(0.16))
        }
        .accessibilityElement(children: .combine)
    }

    private var icon: some View {
        Group {
            switch source {
            case .spotify:
                Image("SpotifyIcon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 18, height: 18)
            case nil:
                Image(systemName: "waveform")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 28, height: 28)
        .background(source == .spotify ? .black : Color(white: 0.23), in: RoundedRectangle(cornerRadius: 7))
        .accessibilityHidden(true)
    }
}
