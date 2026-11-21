import BopCore
import Foundation
import Observation

@MainActor
@Observable
final class SpotifyIntegration {
    enum BopUpdate {
        case trackCaptured(SpotifyBoppedTrack)
        case result(String)
    }

    /// How Bop stands with the Spotify app on this Mac.
    enum Connection: Equatable {
        case off
        case connecting
        case spotifyNotRunning
        /// Spotify is running without the debugging port, and only the user may interrupt it.
        case needsRestart
        case connected(accountID: String)
        case failed(String)
    }

    struct RecentBop: Codable {
        let track: SpotifyBoppedTrack
        let detectedAt: Date
    }

    private struct RecentHistory: Codable {
        let accountID: String
        let bops: [RecentBop]
    }

    private struct PendingTrack {
        let uri: String
        var event: Int
    }

    private static let enabledKey = "spotifyEnabled"
    private static let accountKey = "spotifyAccount"
    private static let playlistsKey = "spotifyPlayerPlaylists"
    private static let autosaveKey = "spotifyPlayerAutosave"
    private static let recentHistoryKey = "spotifyRecentBops"
    private static let recentLimit = 5

    private let defaults = UserDefaults.standard
    /// Present while Spotify is turned on in Bop. Work started with an older instance is stale.
    private var desktop: SpotifyDesktop?
    /// The account whose playlist and recent bops are loaded. Bop remembers it while Spotify is closed.
    private var accountID: String?

    private(set) var connection = Connection.off
    var isEnabled: Bool { connection != .off }
    var isConnected: Bool { if case .connected = connection { true } else { false } }
    var isCreatingPlaylist: Bool { playlistCreationTask != nil }
    private(set) var autosave = false
    private(set) var status: String?
    private(set) var playlistURL: URL?
    private(set) var recentBops: [RecentBop] = []
    private var playlistCreationTask: Task<Void, Never>?

    @ObservationIgnored private var connectTask: Task<Void, Never>?
    @ObservationIgnored private var setsUpSavingOnConnect = false
    @ObservationIgnored private var captureTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var pendingTracks: [PendingTrack] = []
    @ObservationIgnored private var writingTrack: PendingTrack?
    @ObservationIgnored private var writeTask: Task<Void, Never>?
    @ObservationIgnored private var latestCaptureEvent: Int?
    @ObservationIgnored var onBopUpdate: ((Int, BopUpdate) -> Void)?

    /// Checks on Spotify without opening it, since the user may have closed it on purpose.
    func restore() {
        guard defaults.bool(forKey: Self.enabledKey) else { return }
        desktop = SpotifyDesktop()
        if let account = defaults.string(forKey: Self.accountKey) { load(account) }
        startConnecting { try await $0.accountID() }
    }

    /// Turns Spotify on, opening the app with its debugging port when it isn't running.
    /// Turning it on finds or creates the playlist and starts saving songs.
    func connect() {
        if connection == .off { setsUpSavingOnConnect = true }
        defaults.set(true, forKey: Self.enabledKey)
        if desktop == nil { desktop = SpotifyDesktop() }
        startConnecting { try await $0.launch() }
    }

    /// Rechecks Spotify without opening it or showing progress, so the menu reflects its current state.
    func refresh() {
        guard connectTask == nil else { return }
        startConnecting(showsProgress: false) { try await $0.accountID() }
    }

    /// Quits and reopens Spotify with its debugging port. Only the user's click should get here.
    func restartSpotify() {
        guard connection == .needsRestart else { return }
        startConnecting { try await $0.restart() }
    }

    private func startConnecting(
        showsProgress: Bool = true, _ operation: @escaping @MainActor (SpotifyDesktop) async throws -> String
    ) {
        guard let desktop, connection != .connecting else { return }
        if showsProgress {
            connection = .connecting
            status = nil
        }
        connectTask = Task { [weak self] in
            defer {
                if self?.desktop === desktop { self?.connectTask = nil }
            }
            do {
                let account = try await operation(desktop)
                guard let self, self.desktop === desktop else { return }
                self.connected(account)
            } catch {
                guard !Task.isCancelled, let self, self.desktop === desktop else { return }
                if !self.noteUnreachable(error) { self.connection = .failed(error.localizedDescription) }
            }
        }
    }

    private func connected(_ account: String) {
        connection = .connected(accountID: account)
        if account != accountID { load(account) }
        guard setsUpSavingOnConnect else { return }
        setsUpSavingOnConnect = false
        if playlistURL == nil { createPlaylist() } else { setAutosave(true) }
    }

    /// Moves to the state an unreachable Spotify implies. Returns false for other failures.
    private func noteUnreachable(_ error: any Error) -> Bool {
        switch error as? SpotifyDesktop.Failure {
        case .notRunning: connection = .spotifyNotRunning
        case .missingDebugPort: connection = .needsRestart
        case .notInstalled: connection = .failed(error.localizedDescription)
        default: return false
        }
        return true
    }

    private func load(_ account: String) {
        cancelPendingSaves()
        accountID = account
        defaults.set(account, forKey: Self.accountKey)
        if let data = defaults.data(forKey: Self.recentHistoryKey),
           let history = try? PropertyListDecoder().decode(RecentHistory.self, from: data),
           history.accountID == account {
            recentBops = history.bops
        } else {
            recentBops = []
            defaults.removeObject(forKey: Self.recentHistoryKey)
        }
        let preference = playlistPreferences[account]
        if let preference {
            playlistPreferences = [account: preference]
        } else {
            defaults.removeObject(forKey: Self.playlistsKey)
        }
        playlistURL = preference?["ready"] == "true"
            ? preference?["id"].flatMap(SpotifyDesktop.playlistURL(for:))
            : nil
        autosave = playlistURL != nil && defaults.string(forKey: Self.autosaveKey) == account
        if !autosave {
            defaults.removeObject(forKey: Self.autosaveKey)
        }
    }

    func createPlaylist() {
        guard let desktop, case let .connected(accountID) = connection, accountID == self.accountID,
              playlistURL == nil, playlistCreationTask == nil else { return }
        status = nil
        playlistCreationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.desktop === desktop { self.playlistCreationTask = nil }
            }
            do {
                let (id, url) = try await self.preparePlaylist(using: desktop, accountID: accountID)
                try Task.checkCancellation()
                guard self.desktop === desktop, self.accountID == accountID else { return }
                self.playlistPreferences[accountID] = ["id": id, "ready": "true"]
                self.playlistURL = url
                self.setAutosave(true)
            } catch {
                guard !Task.isCancelled, self.desktop === desktop else { return }
                _ = self.noteUnreachable(error)
                self.status = error.localizedDescription
            }
        }
    }

    func shutdown() {
        stopConnectionWork()
    }

    private func stopConnectionWork() {
        setsUpSavingOnConnect = false
        connectTask?.cancel()
        connectTask = nil
        cancelPlaylistCreation()
        cancelPendingSaves()
    }

    /// Turns Spotify off in Bop and forgets its playlist and recent bops. Spotify keeps running.
    func disconnect() {
        let interruptedEvent = latestCaptureEvent
        stopConnectionWork()
        desktop = nil
        accountID = nil
        connection = .off
        autosave = false
        playlistURL = nil
        recentBops = []
        status = nil
        for key in [Self.enabledKey, Self.accountKey, Self.playlistsKey, Self.autosaveKey, Self.recentHistoryKey] {
            defaults.removeObject(forKey: key)
        }
        if let interruptedEvent {
            onBopUpdate?(interruptedEvent, .result("Spotify disconnected"))
        }
    }

    func setAutosave(_ enabled: Bool) {
        guard let accountID, !enabled || playlistURL != nil else { return }
        autosave = enabled
        defaults.set(enabled ? accountID : nil, forKey: Self.autosaveKey)
        status = nil
        if !enabled {
            let interruptedEvent = latestCaptureEvent
            cancelPendingSaves()
            if let interruptedEvent { onBopUpdate?(interruptedEvent, .result("Song saving paused")) }
        }
    }

    func cancelPendingSaves() {
        for task in captureTasks.values { task.cancel() }
        captureTasks.removeAll()
        pendingTracks.removeAll()
        writingTrack = nil
        writeTask?.cancel()
        latestCaptureEvent = nil
    }

    /// Reads Spotify even when Bop last saw it closed, so a bop is the moment Bop notices it reopened.
    func captureBop(at detectedAt: Date, event: Int) {
        guard autosave, playlistURL != nil, let desktop, let accountID else { return }

        latestCaptureEvent = event
        status = nil
        guard captureTasks.count < 4 else {
            publishBopResult("Spotify is busy. Try another bop in a moment.", event: event)
            return
        }
        let id = UUID()
        captureTasks[id] = Task { [weak self] in
            defer { self?.captureTasks.removeValue(forKey: id) }
            do {
                let capture = try await desktop.playing(detectedAt: detectedAt)
                try Task.checkCancellation()
                guard let self, self.isCurrent(desktop) else { return }
                guard let capture else {
                    self.publishBopResult("No active Spotify track captured", event: event)
                    return
                }
                guard capture.accountID == accountID else {
                    self.publishBopResult(
                        "Spotify is signed in to a different account. Set up its playlist in Bop’s settings.",
                        event: event
                    )
                    self.connected(capture.accountID)
                    return
                }
                if !self.isConnected { self.connected(accountID) }
                if let track = capture.track {
                    if event == self.latestCaptureEvent { self.onBopUpdate?(event, .trackCaptured(track)) }
                    self.recordBop(track, detectedAt: detectedAt, accountID: accountID)
                    self.enqueue(PendingTrack(uri: track.uri, event: event))
                } else {
                    self.publishBopResult("No active Spotify track captured", event: event)
                }
            } catch {
                if !Task.isCancelled, let self, self.isCurrent(desktop) {
                    self.reportCaptureError(error, event: event)
                }
            }
        }
    }

    private func recordBop(_ track: SpotifyBoppedTrack, detectedAt: Date, accountID: String) {
        if let previous = recentBops.first(where: { $0.track.uri == track.uri }),
           previous.detectedAt > detectedAt { return }

        var bops = recentBops.filter { $0.track.uri != track.uri }
        let index = bops.firstIndex { $0.detectedAt <= detectedAt } ?? bops.endIndex
        bops.insert(RecentBop(track: track, detectedAt: detectedAt), at: index)
        recentBops = Array(bops.prefix(Self.recentLimit))
        let history = RecentHistory(accountID: accountID, bops: recentBops)
        if let data = try? PropertyListEncoder().encode(history) {
            defaults.set(data, forKey: Self.recentHistoryKey)
        }
    }

    private func enqueue(_ track: PendingTrack) {
        if let writingTrack, writingTrack.uri == track.uri {
            self.writingTrack?.event = max(writingTrack.event, track.event)
            return
        }
        if let index = pendingTracks.firstIndex(where: { $0.uri == track.uri }) {
            pendingTracks[index].event = max(pendingTracks[index].event, track.event)
            return
        }
        guard pendingTracks.count < 16 else {
            publishBopResult("Spotify is taking longer than expected. Try another bop in a moment.", event: track.event)
            return
        }
        pendingTracks.append(track)
        writeNextTrack()
    }

    private func writeNextTrack() {
        guard writeTask == nil, !pendingTracks.isEmpty, autosave, playlistURL != nil,
              let desktop, let accountID, let playlistID = playlistPreferences[accountID]?["id"] else { return }
        let track = pendingTracks.removeFirst()
        writingTrack = track
        writeTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.writeTask = nil
                self.writingTrack = nil
                self.writeNextTrack()
            }
            do {
                let result = try await desktop.save(trackURI: track.uri, playlistID: playlistID)
                try Task.checkCancellation()
                guard self.isCurrent(desktop) else { return }
                let message = result == .saved ? "Saved to playlist" : "Already in playlist"
                self.publishBopResult(message, event: self.writingTrack?.event ?? track.event)
            } catch SpotifyDesktop.Failure.playlistMissing {
                if !Task.isCancelled, self.isCurrent(desktop) {
                    self.forgetMissingPlaylist(accountID: accountID, id: playlistID)
                }
            } catch {
                if !Task.isCancelled, self.isCurrent(desktop) {
                    self.reportCaptureError(error, event: self.writingTrack?.event ?? track.event)
                }
            }
        }
    }

    private func isCurrent(_ desktop: SpotifyDesktop) -> Bool {
        autosave && playlistURL != nil && self.desktop === desktop
    }

    private var playlistPreferences: [String: [String: String]] {
        get { defaults.dictionary(forKey: Self.playlistsKey) as? [String: [String: String]] ?? [:] }
        set { defaults.set(newValue, forKey: Self.playlistsKey) }
    }

    private func preparePlaylist(using desktop: SpotifyDesktop, accountID: String) async throws -> (String, URL) {
        try Task.checkCancellation()
        if let id = playlistPreferences[accountID]?["id"], let url = SpotifyDesktop.playlistURL(for: id) {
            do {
                try await desktop.validatePlaylist(id)
                return (id, url)
            } catch SpotifyDesktop.Failure.playlistMissing {
                try Task.checkCancellation()
                playlistPreferences.removeValue(forKey: accountID)
            }
        }
        let id = try await desktop.createPlaylist()
        try Task.checkCancellation()
        guard let url = SpotifyDesktop.playlistURL(for: id) else {
            throw SpotifyDesktop.Failure.playlistUnavailable
        }
        // Keep the ID if verification is interrupted, so retrying can check the same playlist.
        playlistPreferences[accountID] = ["id": id]
        try await desktop.validatePlaylist(id)
        return (id, url)
    }

    private func cancelPlaylistCreation() {
        playlistCreationTask?.cancel()
        playlistCreationTask = nil
    }

    private func forgetMissingPlaylist(accountID: String, id: String) {
        guard playlistPreferences[accountID]?["id"] == id else { return }
        let event = latestCaptureEvent
        playlistPreferences.removeValue(forKey: accountID)
        playlistURL = nil
        autosave = false
        defaults.removeObject(forKey: Self.autosaveKey)
        cancelPendingSaves()
        let message = "Spotify couldn’t find your playlist. Set it up again to resume saving."
        status = message
        if let event { onBopUpdate?(event, .result(message)) }
    }

    private func publishBopResult(_ message: String, event: Int) {
        guard event == latestCaptureEvent else { return }
        latestCaptureEvent = nil
        status = message
        onBopUpdate?(event, .result(message))
    }

    private func reportCaptureError(_ error: any Error, event: Int) {
        _ = noteUnreachable(error)
        publishBopResult(error.localizedDescription, event: event)
    }
}
