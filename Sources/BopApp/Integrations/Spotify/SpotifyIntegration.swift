import Foundation
import Observation

@MainActor
@Observable
final class SpotifyIntegration {
    enum BopUpdate {
        case trackCaptured(SpotifyBoppedTrack)
        case result(String)
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

    private static let playlistsKey = "spotifyPlayerPlaylists"
    private static let autosaveKey = "spotifyPlayerAutosave"
    private static let disconnectPendingKey = "spotifyPlayerDisconnectPending"
    private static let recentHistoryKey = "spotifyRecentBops"
    private static let recentLimit = 5

    private let defaults = UserDefaults.standard
    private var connection: (client: SpotifyPlayerConnection, accountID: String)?
    private var pendingConnection: SpotifyPlayerConnection?

    var isConnected: Bool { connection != nil }
    var isConnecting: Bool { pendingConnection != nil }
    var isCreatingPlaylist: Bool { playlistCreationTask != nil }
    private(set) var needsKeychainCleanup = false
    private(set) var autosave = false
    private(set) var status: String?
    private(set) var playlistURL: URL?
    private(set) var recentBops: [RecentBop] = []
    private var playlistCreationTask: Task<Void, Never>?

    @ObservationIgnored private var signInTask: Task<Void, Never>?
    @ObservationIgnored private var captureTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var pendingTracks: [PendingTrack] = []
    @ObservationIgnored private var writingTrack: PendingTrack?
    @ObservationIgnored private var writeTask: Task<Void, Never>?
    @ObservationIgnored private var latestCaptureEvent: Int?
    @ObservationIgnored var onBopUpdate: ((Int, BopUpdate) -> Void)?

    func restore() {
        if defaults.bool(forKey: Self.disconnectPendingKey) {
            clearSavedSpotifyData()
            needsKeychainCleanup = true
            status = "Finish removing the Spotify sign-in from Keychain."
            return
        }
        guard SpotifyPlayerConnection.isAvailable else { return }
        let candidate = SpotifyPlayerConnection()
        do {
            guard let accountID = try candidate.restore() else {
                clearSavedSpotifyData()
                return
            }
            activate(candidate, accountID: accountID)
        } catch {
            status = error.localizedDescription
        }
    }

    func connect() {
        guard SpotifyPlayerConnection.isAvailable, !isConnected, !isConnecting, !needsKeychainCleanup else {
            return
        }

        status = nil
        let candidate = SpotifyPlayerConnection()
        pendingConnection = candidate
        signInTask = Task { [weak self] in
            defer {
                if self?.connection?.client !== candidate { candidate.invalidate() }
                if self?.pendingConnection === candidate {
                    self?.pendingConnection = nil
                    self?.signInTask = nil
                }
            }
            do {
                let accountID = try await candidate.connect()
                guard let self, self.pendingConnection === candidate else { return }
                self.activate(candidate, accountID: accountID)
            } catch {
                guard !Task.isCancelled, let self, self.pendingConnection === candidate else { return }
                self.status = error.localizedDescription
            }
        }
    }

    private func activate(_ client: SpotifyPlayerConnection, accountID: String) {
        connection = (client, accountID)
        if let data = defaults.data(forKey: Self.recentHistoryKey),
           let history = try? PropertyListDecoder().decode(RecentHistory.self, from: data),
           history.accountID == accountID {
            recentBops = history.bops
        } else {
            recentBops = []
            defaults.removeObject(forKey: Self.recentHistoryKey)
        }
        let preference = playlistPreferences[accountID]
        if let preference {
            playlistPreferences = [accountID: preference]
        } else {
            defaults.removeObject(forKey: Self.playlistsKey)
        }
        playlistURL = preference?["ready"] == "true"
            ? preference?["id"].flatMap(SpotifyPlayerConnection.playlistURL(for:))
            : nil
        autosave = playlistURL != nil && defaults.string(forKey: Self.autosaveKey) == accountID
        if !autosave {
            defaults.removeObject(forKey: Self.autosaveKey)
        }
    }

    func createPlaylist() {
        guard let connection, playlistURL == nil, playlistCreationTask == nil else { return }
        let client = connection.client
        let accountID = connection.accountID
        status = nil
        playlistCreationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.connection?.client === client { self.playlistCreationTask = nil }
            }
            do {
                let (id, url) = try await self.preparePlaylist(using: client, accountID: accountID)
                try Task.checkCancellation()
                guard self.connection?.client === client else { return }
                self.playlistPreferences[accountID] = ["id": id, "ready": "true"]
                self.playlistURL = url
            } catch {
                guard !Task.isCancelled, self.connection?.client === client else { return }
                if (error as? SpotifyPlayerConnection.Failure) == .reauthorizationRequired {
                    self.disconnect(captureError: error.localizedDescription)
                } else {
                    self.status = error.localizedDescription
                }
            }
        }
    }

    func cancelSignIn() {
        signInTask?.cancel()
    }

    func shutdown() {
        stopConnectionWork()
    }

    private func stopConnectionWork() {
        cancelSignIn()
        cancelPlaylistCreation()
        cancelPendingSaves()
        pendingConnection?.invalidate()
        pendingConnection = nil
        signInTask = nil
        connection?.client.invalidate()
    }

    func disconnect() {
        disconnect(captureError: nil)
    }

    private func disconnect(captureError: String?) {
        defaults.set(true, forKey: Self.disconnectPendingKey)
        let interruptedEvent = latestCaptureEvent
        stopConnectionWork()
        connection = nil
        autosave = false
        playlistURL = nil
        recentBops = []
        status = nil
        clearSavedSpotifyData()
        do {
            try SpotifyKeychain.deletePlayerSession()
            defaults.removeObject(forKey: Self.disconnectPendingKey)
            needsKeychainCleanup = false
        } catch {
            needsKeychainCleanup = true
            status = error.localizedDescription
        }
        if status == nil { status = captureError }
        if let interruptedEvent {
            onBopUpdate?(interruptedEvent, .result(status ?? "Spotify disconnected"))
        }
    }

    private func clearSavedSpotifyData() {
        defaults.removeObject(forKey: Self.playlistsKey)
        defaults.removeObject(forKey: Self.autosaveKey)
        defaults.removeObject(forKey: Self.recentHistoryKey)
    }

    func setAutosave(_ enabled: Bool) {
        guard let connection, !enabled || playlistURL != nil else { return }
        autosave = enabled
        defaults.set(enabled ? connection.accountID : nil, forKey: Self.autosaveKey)
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

    func captureBop(at detectedAt: Date, event: Int) {
        guard autosave, playlistURL != nil, let connection else { return }
        let client = connection.client
        let accountID = connection.accountID

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
                let track = try await client.playing(detectedAt: detectedAt)
                try Task.checkCancellation()
                guard let self, self.isCurrent(client) else { return }
                if let track {
                    if event == self.latestCaptureEvent { self.onBopUpdate?(event, .trackCaptured(track)) }
                    self.recordBop(track, detectedAt: detectedAt, accountID: accountID)
                    self.enqueue(PendingTrack(uri: track.uri, event: event))
                } else {
                    self.publishBopResult("No active Spotify track captured", event: event)
                }
            } catch {
                if !Task.isCancelled, let self, self.isCurrent(client) {
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
              let connection, let playlistID = playlistPreferences[connection.accountID]?["id"] else { return }
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
                let result = try await connection.client.save(trackURI: track.uri, playlistID: playlistID)
                try Task.checkCancellation()
                guard self.isCurrent(connection.client) else { return }
                let message = result == .saved ? "Saved to Bop playlist" : "Already in Bop playlist"
                self.publishBopResult(message, event: self.writingTrack?.event ?? track.event)
            } catch SpotifyPlayerConnection.Failure.playlistMissing {
                if !Task.isCancelled, self.isCurrent(connection.client) {
                    self.forgetMissingPlaylist(accountID: connection.accountID, id: playlistID)
                }
            } catch {
                if !Task.isCancelled, self.isCurrent(connection.client) {
                    self.reportCaptureError(error, event: self.writingTrack?.event ?? track.event)
                }
            }
        }
    }

    private func isCurrent(_ client: SpotifyPlayerConnection) -> Bool {
        autosave && playlistURL != nil && connection?.client === client
    }

    private var playlistPreferences: [String: [String: String]] {
        get { defaults.dictionary(forKey: Self.playlistsKey) as? [String: [String: String]] ?? [:] }
        set { defaults.set(newValue, forKey: Self.playlistsKey) }
    }

    private func preparePlaylist(using client: SpotifyPlayerConnection, accountID: String) async throws -> (String, URL) {
        try Task.checkCancellation()
        if let id = playlistPreferences[accountID]?["id"], let url = SpotifyPlayerConnection.playlistURL(for: id) {
            do {
                try await client.validatePlaylist(id)
                return (id, url)
            } catch SpotifyPlayerConnection.Failure.playlistMissing {
                try Task.checkCancellation()
                playlistPreferences.removeValue(forKey: accountID)
            }
        }
        let id = try await client.createPlaylist()
        try Task.checkCancellation()
        guard let url = SpotifyPlayerConnection.playlistURL(for: id) else {
            throw SpotifyPlayerConnection.Failure.playlistUnavailable
        }
        // Keep the ID if verification is interrupted, so retrying can check the same playlist.
        playlistPreferences[accountID] = ["id": id]
        try await client.validatePlaylist(id)
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
        let message = "Spotify couldn’t find the Bop playlist. Create it again to resume saving."
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
        if let failure = error as? SpotifyPlayerConnection.Failure,
           failure == .reauthorizationRequired {
            disconnect(captureError: error.localizedDescription)
        } else {
            publishBopResult(error.localizedDescription, event: event)
        }
    }
}
