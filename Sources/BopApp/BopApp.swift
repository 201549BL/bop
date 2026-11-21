import AppKit
import Observation
import SwiftUI

@main
@MainActor
@Observable
final class BopAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private static let onboardingVersion = 1
    private static let onboardingKey = "completedOnboardingVersion"
    private static let cueKey = "showBopCue"

    private let session = BopSession()
    private let spotify = SpotifyIntegration()
    private var setupWindow: NSWindow?
    private var settingsSection = BopSettingsView.Section.general
    @ObservationIgnored private var settingsWindow: NSWindow?
    @ObservationIgnored private var graphsWindow: NSWindow?
    @ObservationIgnored private var wasListeningBeforeSetup = false
    @ObservationIgnored private var finishedSetup = false
    @ObservationIgnored private var menuBar: BopMenuBar?
    private var showBopCue = UserDefaults.standard.object(forKey: BopAppDelegate.cueKey) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(showBopCue, forKey: Self.cueKey)
            if !showBopCue { menuBar?.dismissHUD() }
        }
    }

    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let delegate = BopAppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        spotify.restore()
        session.onLiveBop = { [weak self] date in
            self?.handleLiveBop(at: date)
        }
        session.onLiveListeningEnded = { [weak self] in
            self?.spotify.cancelPendingSaves()
            self?.menuBar?.endFeedback()
        }
        spotify.onBopUpdate = { [weak self] event, update in
            self?.menuBar?.updateBop(update, event: event)
        }
        menuBar = BopMenuBar(
            session: session,
            spotify: spotify,
            hasCompletedSetup: { [weak self] in self?.hasCompletedSetup == true },
            isSettingUp: { [weak self] in self?.setupWindow != nil }
        ) { [weak self] action in
            self?.performMenuAction(action)
        }
        if !hasCompletedSetup { showAirPodsSetup() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            if hasCompletedSetup { showSettings() } else { showAirPodsSetup() }
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        session.stop()
        spotify.shutdown()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === setupWindow {
            if session.isLive {
                if finishedSetup || wasListeningBeforeSetup {
                    session.resetBopDetection()
                } else {
                    session.stop()
                }
            }
            setupWindow = nil
        } else if window === settingsWindow {
            settingsWindow = nil
        } else if window === graphsWindow {
            graphsWindow = nil
        }
    }

    private var hasCompletedSetup: Bool {
        UserDefaults.standard.integer(forKey: Self.onboardingKey) >= Self.onboardingVersion
    }

    private func startListening() {
        if setupWindow != nil || !hasCompletedSetup || session.motionStatus == .denied || session.motionStatus == .restricted {
            showAirPodsSetup()
            return
        }
        let window = NSApp.keyWindow
        session.startListening { [weak window] in
            window?.restoreAfterMotionPermission()
        }
    }

    private func showAirPodsSetup() {
        if let setupWindow { present(setupWindow); return }
        wasListeningBeforeSetup = session.isLive
        finishedSetup = false
        spotify.cancelPendingSaves()
        menuBar?.endFeedback()
        let view = BopOnboardingView(
            session: session,
            completeSetup: { [weak self] in self?.finishAirPodsSetup() },
            deferSetup: { [weak self] in self?.setupWindow?.close() }
        )
        let window = makeWindow("Bop Setup", size: NSSize(width: 720, height: 560), rootView: view)
        window.contentMinSize = NSSize(width: 500, height: 560)
        setupWindow = window
        present(window)
    }

    private func finishAirPodsSetup() {
        guard session.isLive, session.motionStatus == .streaming else { return }
        UserDefaults.standard.set(Self.onboardingVersion, forKey: Self.onboardingKey)
        finishedSetup = true
        setupWindow?.close()
        showSettings()
    }

    @objc private func showSettings() {
        presentSettings()
    }

    private func presentSettings(section: BopSettingsView.Section? = nil) {
        if let settingsWindow {
            if let section { settingsSection = section }
            if settingsWindow.isMiniaturized { settingsWindow.deminiaturize(nil) }
            present(settingsWindow)
            return
        }

        settingsSection = section ?? .general
        let view = BopSettingsView(
            session: session,
            spotify: spotify,
            section: Binding(get: { [weak self] in self?.settingsSection ?? .general }, set: { [weak self] in self?.settingsSection = $0 }),
            showBopCue: Binding(get: { [weak self] in self?.showBopCue ?? true }, set: { [weak self] in self?.showBopCue = $0 }),
            showAirPodsSetup: { [weak self] in self?.showAirPodsSetup() },
            showMotionGraphs: { [weak self] in self?.showMotionGraphs() }
        )
        let window = makeWindow("Bop Settings", size: NSSize(width: 630, height: 370), rootView: view)
        settingsWindow = window
        present(window)
    }

    private func showMotionGraphs() {
        if let graphsWindow { present(graphsWindow); return }
        let view = BopView(session: session, startListening: { [weak self] in self?.startListening() })
        let window = makeWindow("Motion Graphs", size: NSSize(width: 700, height: 650), rootView: view)
        graphsWindow = window
        present(window)
    }

    private func makeWindow(_ title: String, size: NSSize, rootView: some View) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: rootView)
        window.delegate = self
        window.center()
        return window
    }

    private func present(_ window: NSWindow) {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Bop")
        let settingsItem = appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Bop", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)
        NSApp.mainMenu = mainMenu
    }

    private func handleLiveBop(at date: Date) {
        guard setupWindow == nil, hasCompletedSetup, let event = session.menuBopEvent else { return }
        let detail: String? = if spotify.autosave {
            BopMenuBar.checkingSpotify
        } else if spotify.playlistURL != nil {
            "Song saving paused"
        } else {
            nil
        }
        menuBar?.showBop(event: event, detail: detail, awaitingPlayback: spotify.autosave, showHUD: showBopCue)
        if spotify.autosave { spotify.captureBop(at: date, event: event) }
    }

    private func performMenuAction(_ action: BopMenuBar.Action) {
        switch action {
        case .toggleListening:
            if setupWindow != nil {
                showAirPodsSetup()
            } else if session.isLive || session.isReplaying {
                session.stop()
            } else {
                startListening()
            }
        case .showSettings:
            showSettings()
        case .showMusicSettings:
            presentSettings(section: .music)
        case .openTrack(let url):
            NSWorkspace.shared.open(url)
        case .openBopPlaylist:
            if let url = spotify.playlistURL { NSWorkspace.shared.open(url) }
        case .openSpotify:
            spotify.connect()
        case .quit:
            NSApp.terminate(nil)
        }
    }
}

@MainActor
private final class BopMenuBar: NSObject {
    enum Action {
        case toggleListening, showSettings, showMusicSettings, openSpotify, openBopPlaylist, openTrack(URL), quit
    }

    private enum Cue {
        case resting, jumping(Int), underline
    }

    private static let jumpFrameCount = 24
    private static let restingImage = makeImage()
    private static let underlinedImage = makeImage(isDetected: true)
    private static let jumpImages = makeJumpImages()
    private static let bopDetected = "Bop detected"
    static let checkingSpotify = "Checking Spotify…"

    private let session: BopSession
    private let spotify: SpotifyIntegration
    private let hasCompletedSetup: () -> Bool
    private let isSettingUp: () -> Bool
    private let perform: (Action) -> Void
    private let item = NSStatusBar.system.statusItem(withLength: BopMenuWordmark.width)
    private let menu = BopStatusMenu()
    private let hud = BopFeedbackHUD()
    private let listeningDot = BopListeningDot()
    private var visibilityObservation: NSKeyValueObservation?
    private var feedbackEvent: Int?
    private var lastBopDetail: String?
    private var cueTask: Task<Void, Never>?
    private var cue = Cue.resting
    private var showsRecentBops = false

    init(
        session: BopSession,
        spotify: SpotifyIntegration,
        hasCompletedSetup: @escaping () -> Bool,
        isSettingUp: @escaping () -> Bool,
        perform: @escaping (Action) -> Void
    ) {
        self.session = session
        self.spotify = spotify
        self.hasCompletedSetup = hasCompletedSetup
        self.isSettingUp = isSettingUp
        self.perform = perform
        super.init()

        menu.willOpen = { [weak self] in self?.prepareMenu() }
        item.menu = menu.menu

        if let button = item.button {
            button.imagePosition = .imageOnly
            listeningDot.isHidden = true
            listeningDot.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(listeningDot)

            let diameter = BopMenuWordmark.listeningDotDiameter
            let offset = BopMenuWordmark.listeningDotOffset
            NSLayoutConstraint.activate([
                listeningDot.widthAnchor.constraint(equalToConstant: diameter),
                listeningDot.heightAnchor.constraint(equalToConstant: diameter),
                listeningDot.centerXAnchor.constraint(equalTo: button.centerXAnchor, constant: offset.width),
                listeningDot.centerYAnchor.constraint(equalTo: button.centerYAnchor, constant: button.isFlipped ? offset.height : -offset.height)
            ])
        }
        item.behavior = .removalAllowed
        visibilityObservation = item.observe(\.isVisible, options: [.new]) { [weak self] _, change in
            guard change.newValue == false else { return }
            Task { @MainActor in
                self?.perform(.quit)
            }
        }
        updateIcon()
        observeSession()
    }

    private func prepareMenu() {
        hud.dismiss()
        showsRecentBops = false
        spotify.refresh()
        updateMenu(makeMenuContent())
    }

    private func makeMenuContent() -> BopMenuContent {
        let hasPlaylist = spotify.playlistURL != nil
        let hasAutosave = spotify.autosave
        let spotifyRow = BopMenuSpotifyRow(spotify.connection)
        let autosaveStatus: String? = if spotify.connection == .connecting {
            "Connecting to Spotify…"
        } else if hasAutosave, let spotifyRow {
            spotifyRow.saveBlocker
        } else if hasPlaylist {
            hasAutosave ? "Spotify autosave on" : "Spotify autosave off"
        } else {
            nil
        }

        let actionTitle: String
        let symbol: String
        let status: String
        var detail = autosaveStatus
        var isListening = false
        if isSettingUp() {
            actionTitle = "Continue Setup…"
            symbol = "headphones"
            status = "AirPods setup"
        } else if session.isLive {
            actionTitle = "Pause Listening"
            symbol = "pause"
            isListening = session.motionStatus == .streaming
            status = switch session.motionStatus {
            case .streaming: "Listening to AirPods"
            case .waiting, .disconnected, nil: "Waiting for AirPods"
            default: session.status
            }
            if isListening, hasPlaylist, hasAutosave, spotify.isConnected { detail = "Saving songs to Spotify" }
        } else if session.isReplaying {
            actionTitle = "Stop Replay"
            symbol = "stop"
            status = session.status
        } else {
            let needsMotionAccess = session.motionStatus == .denied || session.motionStatus == .restricted
            let needsSetup = !hasCompletedSetup() || needsMotionAccess
            actionTitle = needsSetup ? "Set Up AirPods…" : "Start Listening"
            symbol = "headphones"
            status = needsSetup ? "AirPods setup" : "Listening paused"
            if needsMotionAccess { detail = session.status }
        }
        return BopMenuContent(
            status: BopMenuStatusHeader(title: status, detail: detail, isListening: isListening),
            listeningTitle: actionTitle,
            listeningSymbol: symbol,
            tracks: spotify.recentBops,
            lastResult: lastBopDetail.map { $0 == Self.bopDetected ? $0 : "Last bop · \($0)" },
            providerConnected: spotify.isEnabled,
            spotifyRow: spotifyRow,
            autosaveEnabled: hasAutosave,
            playlistAvailable: hasPlaylist,
            isExpanded: showsRecentBops,
            toggleRecentBops: { [weak self] in
                guard let self else { return }
                self.showsRecentBops.toggle()
                self.updateMenu(self.makeMenuContent())
            },
            perform: { [weak self] action in
                self?.menu.dismiss()
                // Let the menu finish closing before a window opens or the app quits.
                DispatchQueue.main.async { self?.perform(action) }
            },
            dismiss: { [weak self] in self?.menu.dismiss() },
            resize: { [weak self] size in self?.resizeMenu(to: size) }
        )
    }

    private func updateMenu(_ content: BopMenuContent) {
        if menu.isVisible, let controller = menu.content as? NSHostingController<BopMenuContent> {
            controller.rootView = content
            return
        }

        let controller = NSHostingController(rootView: content)
        controller.sizingOptions = []
        menu.setContent(controller)
    }

    private func resizeMenu(to measuredSize: CGSize) {
        // SwiftUI animates the layout and supplies its current size on every frame.
        let size = CGSize(width: measuredSize.width, height: measuredSize.height.rounded(.up))
        guard menu.isVisible, size.height > 0 else { return }
        menu.resize(to: size)
    }

    func showBop(event: Int, detail: String?, awaitingPlayback: Bool, showHUD: Bool) {
        feedbackEvent = event
        lastBopDetail = detail ?? Self.bopDetected
        cueTask?.cancel()
        if menu.isVisible, showsRecentBops { updateMenu(makeMenuContent()) }
        if showHUD, item.isVisible, !menu.isVisible, let button = item.button {
            hud.show(event: event, detail: detail, awaitingPlayback: awaitingPlayback, anchoredTo: button)
        }
        startCue()
    }

    func updateBop(_ update: SpotifyIntegration.BopUpdate, event: Int) {
        guard event == feedbackEvent else { return }
        switch update {
        case .trackCaptured(let track):
            hud.update(event: event, detail: "Saving to playlist…", track: track)
        case .result(let result):
            lastBopDetail = result
            if menu.isVisible, showsRecentBops { updateMenu(makeMenuContent()) }
            hud.update(event: event, detail: result)
        }
    }

    func dismissHUD() {
        hud.dismiss()
    }

    func endFeedback() {
        feedbackEvent = nil
        if lastBopDetail == Self.checkingSpotify { lastBopDetail = Self.bopDetected }
        hud.dismiss()
        cueTask?.cancel()
        cueTask = nil
        cue = .resting
        updateIcon()
    }

    private func observeSession() {
        let content = withObservationTracking {
            makeMenuContent()
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.observeSession()
            }
        }
        item.button?.setAccessibilityLabel(content.status.isListening ? "Bop, listening" : "Bop")
        listeningDot.isHidden = !content.status.isListening
        if menu.isVisible { updateMenu(content) }
    }

    private func startCue() {
        let animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        cue = animates ? .jumping(0) : .underline
        updateIcon()
        cueTask = Task { [weak self] in
            guard let self else { return }
            do {
                if animates {
                    try await self.playJump()
                } else {
                    try await Task.sleep(for: .seconds(BopMenuWordmark.detectionDuration))
                }
                try Task.checkCancellation()
            } catch {
                return
            }
            self.cueTask = nil
            self.cue = .resting
            self.updateIcon()
        }
    }

    private func playJump() async throws {
        let duration = BopMenuWordmark.animationDuration
        let interval = duration / Double(Self.jumpFrameCount)
        let clock = ContinuousClock()
        let start = clock.now
        for index in 1..<Self.jumpFrameCount {
            try await clock.sleep(until: start + .seconds(Double(index) * interval), tolerance: .milliseconds(2))
            try Task.checkCancellation()
            cue = .jumping(index)
            updateIcon()
        }
        try await clock.sleep(until: start + .seconds(duration), tolerance: .milliseconds(2))
    }

    private func updateIcon() {
        let image = switch cue {
        case .resting: Self.restingImage
        case .jumping(let index): Self.jumpImages[index]
        case .underline: Self.underlinedImage
        }
        item.button?.image = image ?? Self.restingImage
    }

    private static func makeJumpImages() -> [NSImage?] {
        let interval = BopMenuWordmark.animationDuration / Double(jumpFrameCount)
        return (0..<jumpFrameCount).map { index in
            makeImage(isDetected: true, jumpTime: Double(index) * interval)
        }
    }

    private static func makeImage(isDetected: Bool = false, jumpTime: Double? = nil) -> NSImage? {
        let wordmark = BopMenuWordmark(isDetected: isDetected, jumpTime: jumpTime)
        let renderer = ImageRenderer(content: wordmark.foregroundStyle(.black))
        renderer.scale = 2
        let image = renderer.nsImage
        image?.isTemplate = true
        return image
    }
}

private struct BopMenuStatusHeader: View {
    let title: String
    var detail: String? = nil
    var isListening = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(isListening ? Color(nsColor: BopMenuWordmark.listeningDotColor) : Color.secondary)
                .frame(width: 8, height: 8)
                .padding(.top, 5)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                if let detail {
                    Text(detail)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 11)
        .frame(width: 300, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

private struct BopMenuContent: View {
    private enum Row: Hashable {
        case listening, musicSetup, spotify, recentBops, track(String), playlist, settings, quit
    }

    let status: BopMenuStatusHeader
    let listeningTitle: String
    let listeningSymbol: String
    let tracks: [SpotifyIntegration.RecentBop]
    let lastResult: String?
    let providerConnected: Bool
    let spotifyRow: BopMenuSpotifyRow?
    let autosaveEnabled: Bool
    let playlistAvailable: Bool
    let isExpanded: Bool
    let toggleRecentBops: () -> Void
    let perform: (BopMenuBar.Action) -> Void
    let dismiss: () -> Void
    let resize: (CGSize) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusedRow: Row?
    @State private var hoveredRow: Row?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            status
            menuRow(.listening, listeningTitle, symbol: listeningSymbol) { perform(.toggleListening) }
            divider
            if providerConnected {
                if let spotifyRow {
                    menuRow(.spotify, spotifyRow.title, symbol: spotifyRow.symbol, detail: spotifyRow.detail) {
                        perform(spotifyRow.action)
                    }
                }
                menuRow(.recentBops, "Recent Bops", symbol: "clock", action: toggleRecentBops) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

                BopRecentBopsLayout(reveal: isExpanded ? 1 : 0) {
                    recentTracks
                }
                .clipped()
                .contentShape(Rectangle())
                .allowsHitTesting(isExpanded)
                .accessibilityHidden(!isExpanded)
            } else {
                menuRow(.musicSetup, "Set Up Music…", symbol: "music.note", detail: "Save the songs you bop to") {
                    perform(.showMusicSettings)
                }
            }

            if playlistAvailable {
                menuRow(.playlist, "Open Playlist", symbol: "music.note.list") { perform(.openBopPlaylist) }
            }
            menuRow(.settings, "Settings…", symbol: "slider.horizontal.3", action: { perform(.showSettings) }) {
                Text("⌘,")
            }
            .keyboardShortcut(",", modifiers: .command)

            divider
            menuRow(.quit, "Quit Bop", symbol: "power", action: { perform(.quit) }) {
                Text("⌘Q")
            }
            .keyboardShortcut("q", modifiers: .command)
        }
        .padding(.bottom, 7)
        .frame(width: 300)
        .fixedSize(horizontal: false, vertical: true)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: isExpanded)
        .onGeometryChange(for: CGSize.self, of: \.size, action: resize)
        .defaultFocus($focusedRow, .listening)
        .onMoveCommand(perform: moveFocus)
        .onExitCommand(perform: dismiss)
    }

    private var linkedTracks: [SpotifyIntegration.RecentBop] {
        tracks.filter { $0.track.url != nil }
    }

    private var recentTracks: some View {
        VStack(alignment: .leading, spacing: 0) {
            if linkedTracks.isEmpty {
                if autosaveEnabled {
                    recentNote("No bopped songs yet")
                } else {
                    menuRow(.musicSetup, playlistAvailable ? "Set Up Autosave…" : "Create Bop! Playlist…") {
                        perform(.showMusicSettings)
                    }
                }
            }
            ForEach(linkedTracks, id: \.track.uri) { bop in
                let track = bop.track
                if let url = track.url {
                    menuRow(.track(track.uri), track.title ?? "Spotify track", detail: track.artist) {
                        perform(.openTrack(url))
                    }
                    .help(track.title ?? "Open track in Spotify")
                }
            }
            if let lastResult {
                recentNote(lastResult)
            }
        }
        .padding(.bottom, 3)
    }

    private var divider: some View {
        Divider()
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
    }

    private func recentNote(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 39)
            .padding(.trailing, 14)
            .padding(.vertical, 5)
    }

    private func menuRow(
        _ row: Row,
        _ title: String,
        symbol: String? = nil,
        detail: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        menuRow(row, title, symbol: symbol, detail: detail, action: action) { EmptyView() }
    }

    private func menuRow<Trailing: View>(
        _ row: Row,
        _ title: String,
        symbol: String? = nil,
        detail: String? = nil,
        action: @escaping () -> Void,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Group {
                    if let symbol { Image(systemName: symbol) } else { Color.clear }
                }
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 15)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13))
                    if let detail {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)

                Spacer(minLength: 2)
                trailing()
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 6)
            .frame(minHeight: 28)
            .contentShape(Rectangle())
            .background {
                if focusedRow == row {
                    RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.20))
                } else if hoveredRow == row {
                    RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.08))
                }
            }
        }
        .buttonStyle(.plain)
        .focused($focusedRow, equals: row)
        .focusEffectDisabled()
        .onHover { hovering in
            if hovering { hoveredRow = row }
            else if hoveredRow == row { hoveredRow = nil }
        }
        .padding(.horizontal, 7)
    }

    private func moveFocus(_ direction: MoveCommandDirection) {
        guard direction == .up || direction == .down else { return }
        var rows: [Row] = [.listening]
        if providerConnected {
            if spotifyRow != nil { rows.append(.spotify) }
            rows.append(.recentBops)
        } else {
            rows.append(.musicSetup)
        }
        if providerConnected, isExpanded {
            rows.append(contentsOf: linkedTracks.map { .track($0.track.uri) })
            if linkedTracks.isEmpty, !autosaveEnabled { rows.append(.musicSetup) }
        }
        if playlistAvailable { rows.append(.playlist) }
        rows.append(contentsOf: [.settings, .quit])

        guard let focusedRow, let index = rows.firstIndex(of: focusedRow) else {
            focusedRow = direction == .down ? rows.first : rows.last
            return
        }
        let step = direction == .down ? 1 : -1
        self.focusedRow = rows[(index + step + rows.count) % rows.count]
    }
}

private struct BopRecentBopsLayout: Layout {
    var reveal: CGFloat

    var animatableData: CGFloat {
        get { reveal }
        set { reveal = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let size = content.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: size.width, height: size.height * reveal)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}

private final class BopListeningDot: NSView {
    override func draw(_ dirtyRect: NSRect) {
        BopMenuWordmark.listeningDotColor.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

extension NSWindow {
    @discardableResult
    func restoreAfterMotionPermission() -> Bool {
        guard isVisible, isOnActiveSpace, !isMiniaturized, !NSApp.isHidden else { return false }
        if !NSApp.isActive || !isKeyWindow {
            NSApp.activate()
            makeKeyAndOrderFront(nil)
            // Activation is cooperative. Keep the window visible even if focus stays elsewhere.
            if !NSApp.isActive || !isKeyWindow {
                orderFrontRegardless()
            }
        }
        return true
    }
}

/// The menu row that tells the user what Spotify needs before Bop can save songs.
private struct BopMenuSpotifyRow {
    let title: String
    let detail: String
    let symbol: String
    let saveBlocker: String
    let action: BopMenuBar.Action

    init?(_ connection: SpotifyIntegration.Connection) {
        switch connection {
        case .spotifyNotRunning:
            title = "Open Spotify"
            detail = "Bop saves songs while Spotify is open"
            symbol = "arrow.up.forward.app"
            saveBlocker = "Open Spotify to save songs"
            action = .openSpotify
        case .needsRestart:
            title = "Restart Spotify…"
            detail = "Spotify is open without Bop’s connection"
            symbol = "arrow.clockwise"
            saveBlocker = "Restart Spotify to save songs"
            action = .showMusicSettings
        case .failed(let message):
            title = "Spotify Needs Attention…"
            detail = message
            symbol = "exclamationmark.triangle"
            saveBlocker = "Spotify isn’t saving songs"
            action = .showMusicSettings
        case .off, .connecting, .connected:
            return nil
        }
    }
}

/// The status item's menu. A real NSMenu, so the system draws the icon highlight, the menu
/// background, and the placement, and hosts Bop's SwiftUI content as a single item.
@MainActor
private final class BopStatusMenu: NSObject, NSMenuDelegate {
    private static let width: CGFloat = 300
    let menu = NSMenu()
    private let contentItem = NSMenuItem()
    private(set) var content: NSViewController?
    private(set) var isVisible = false
    var willOpen: (() -> Void)?

    override init() {
        super.init()
        menu.delegate = self
        menu.addItem(contentItem)
    }

    func setContent(_ controller: NSViewController) {
        content = controller
        let height = (controller as? NSHostingController<BopMenuContent>)?
            .sizeThatFits(in: NSSize(width: Self.width, height: .greatestFiniteMagnitude)).height ?? 0
        controller.view.frame = NSRect(x: 0, y: 0, width: Self.width, height: height)
        contentItem.view = controller.view
    }

    func resize(to size: CGSize) {
        guard let view = contentItem.view, view.frame.size != size else { return }
        view.setFrameSize(size)
    }

    func dismiss() {
        menu.cancelTracking()
    }

    func menuWillOpen(_ menu: NSMenu) {
        willOpen?()
        isVisible = true
    }

    func menuDidClose(_ menu: NSMenu) {
        isVisible = false
    }
}
