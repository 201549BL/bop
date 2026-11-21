import BopCore
import Darwin
import Foundation

@MainActor
final class SpotifyPlayerConnection {
    private static let playlistName = "Bop!"
    private static let managedPlaylistNames: Set<String> = [playlistName, "Bop"]
    private static let playlistDescription = "Songs you bopped to with Bop. [Bop Spotify Player]"

    private static var helperURL: URL {
        Bundle.main.bundleURL.appending(path: "Contents/Helpers/spotify_player")
    }

    static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: helperURL.path)
    }

    private var storedSession: SpotifyKeychain.PlayerSession?
    private var isValid = true
    private var invocations: [UUID: Invocation] = [:]

    func connect() async throws -> String {
        // The stock player's first launch caches both credentials. Its authenticate subcommand
        // requests the playback credential but does not save it for later CLI commands.
        guard case let .signIn(session) = try await run(.signIn, timeout: .seconds(240)) else {
            throw Failure.authenticationFailed
        }
        let profile: Profile = try await spotifyGet("me", signInToken: session.token)
        try Task.checkCancellation()
        guard isValid else { throw CancellationError() }
        guard profile.id == session.accountID else {
            throw Failure.accountMismatch
        }
        try SpotifyKeychain.savePlayerSession(session)
        storedSession = session
        return session.accountID
    }

    func restore() throws -> String? {
        guard let session = try SpotifyKeychain.loadPlayerSession(), session.credentials != nil,
              let filename = session.tokenFilename, Self.isTokenFilename(filename),
              !session.accountID.isEmpty else { return nil }
        storedSession = session
        return session.accountID
    }

    private func persistRefresh(from invocation: Invocation) throws {
        guard let original = invocation.sessionAtLaunch, let storedSession,
              let filename = original.tokenFilename else { throw Failure.reauthorizationRequired }
        let refreshed = try Self.readOutput(invocation.cache.directory.appending(path: filename))
        let credentials = try Self.readOutput(invocation.cache.credentialsFile)
        guard refreshed != original.token || credentials != original.credentials else { return }
        let previous = try Self.decode(Token.self, from: original.token)
        let updated = try Self.decode(Token.self, from: refreshed)
        guard updated.refreshToken == previous.refreshToken,
              try Self.decode(Credentials.self, from: credentials).username == storedSession.accountID else {
            throw Failure.reauthorizationRequired
        }

        // A helper that used an older snapshot must not overwrite a refresh already saved by another helper.
        let token = storedSession.token == original.token ? refreshed : storedSession.token
        let nextCredentials = storedSession.credentials == original.credentials ? credentials : storedSession.credentials
        guard token != storedSession.token || nextCredentials != storedSession.credentials else { return }
        let next = SpotifyKeychain.PlayerSession(
            accountID: storedSession.accountID, token: token,
            tokenFilename: filename, credentials: nextCredentials
        )
        try SpotifyKeychain.savePlayerSession(next)
        self.storedSession = next
    }

    func playing(detectedAt: Date) async throws -> SpotifyBoppedTrack? {
        let initialAge = Date().timeIntervalSince(detectedAt)
        guard (0..<3).contains(initialAge) else { return nil }
        guard case let .output(output) = try await run(.playing, timeout: .seconds(3 - initialAge)) else {
            throw HelperError.invalidResponse
        }
        let response = try Self.decode(PlayingResponse?.self, from: output)
        let age = Date().timeIntervalSince(detectedAt)
        guard (0...3).contains(age), let response,
              response.isPlaying == true, response.device?.isPrivateSession == false,
              response.currentlyPlayingType == "track", let track = response.item,
              track.type == "track", track.isLocal == false, let id = track.id,
              let timestamp = response.timestamp,
              Double(timestamp) / 1000 <= detectedAt.timeIntervalSince1970,
              let progress = response.progressMilliseconds, Double(progress) / 1000 >= age else { return nil }
        let prefix = SpotifyBoppedTrack.uriPrefix
        let rawID = id.hasPrefix(prefix) ? id.dropFirst(prefix.count) : id[...]
        guard Self.isSpotifyID(rawID) else { return nil }
        let artists = track.artists?.compactMap { Self.nonemptyName($0.name) } ?? []
        return SpotifyBoppedTrack(
            uri: "\(prefix)\(rawID)",
            title: Self.nonemptyName(track.name),
            artist: artists.isEmpty ? nil : artists.joined(separator: ", ")
        )
    }

    func createPlaylist() async throws -> String {
        if let existing = try await withRefreshedPlaylistAccess({ try await findManagedPlaylist() }) {
            return existing
        }

        guard case let .output(output) = try await run(.create) else { throw HelperError.invalidResponse }
        let message = String(decoding: output, as: UTF8.self)
        guard let match = message.firstMatch(of: /with id '(?:spotify:playlist:)?([a-zA-Z0-9]{1,64})' was created\./) else {
            throw HelperError.invalidResponse
        }
        return String(match.1)
    }

    func validatePlaylist(_ id: String) async throws {
        try await withRefreshedPlaylistAccess { try await requireWritablePlaylist(id) }
    }

    private func withRefreshedPlaylistAccess<Result>(_ operation: () async throws -> Result) async throws -> Result {
        do {
            return try await operation()
        } catch Failure.reauthorizationRequired {
            // The helper refreshes access before listing playlists, even when playback is idle.
            _ = try await run(.refreshPlaylistAccess)
            return try await operation()
        }
    }

    private func findManagedPlaylist() async throws -> String? {
        var offset = 0
        var existing: String?
        while true {
            let page: Page<Playlist> = try await spotifyGet("me/playlists", offset: offset)
            for candidate in page.items where Self.managedPlaylistNames.contains(candidate.name)
                && candidate.owner.id == storedSession?.accountID && Self.isSpotifyID(candidate.id) {
                let details: Playlist
                do {
                    details = try await playlist(candidate.id)
                } catch Failure.playlistMissing {
                    continue
                }
                if isManaged(details) {
                    guard existing == nil else { throw Failure.playlistUnavailable }
                    existing = candidate.id
                }
            }
            if page.next == nil { break }
            guard !page.items.isEmpty else { throw HelperError.invalidResponse }
            offset += page.items.count
        }
        return existing
    }

    static func playlistURL(for id: String) -> URL? {
        guard isSpotifyID(id) else { return nil }
        return URL(string: "https://open.spotify.com/playlist/\(id)")
    }

    func save(trackURI: String, playlistID: String) async throws -> SaveResult {
        let prefix = SpotifyBoppedTrack.uriPrefix
        let id = trackURI.dropFirst(prefix.count)
        guard trackURI.hasPrefix(prefix), Self.isSpotifyID(id), Self.isSpotifyID(playlistID) else {
            throw HelperError.invalidResponse
        }
        try await requireWritablePlaylist(playlistID)

        var offset = 0
        while true {
            let page: Page<PlaylistItem> = try await spotifyGet(
                "playlists/\(playlistID)/items", fields: "next,items(item(uri),track(uri))", offset: offset
            )
            if page.items.contains(where: { $0.item?.uri == trackURI || $0.track?.uri == trackURI }) {
                return .alreadySaved
            }
            if page.next == nil { break }
            guard !page.items.isEmpty else { throw HelperError.invalidResponse }
            offset += page.items.count
        }

        _ = try await run(.save, arguments: [playlistID, "--track-id", String(id)])
        return .saved
    }

    private func requireWritablePlaylist(_ id: String) async throws {
        guard Self.isSpotifyID(id) else { throw Failure.playlistUnavailable }
        let details = try await playlist(id)
        // A playlist keeps its verified ID after the user changes its name or description.
        guard details.id == id, details.owner.id == storedSession?.accountID, details.collaborative == false else {
            throw Failure.playlistUnavailable
        }
        guard details.isPublic == false else { throw Failure.playlistVisible }
    }

    private func isManaged(_ playlist: Playlist) -> Bool {
        playlist.owner.id == storedSession?.accountID
            && Self.managedPlaylistNames.contains(playlist.name)
            && playlist.description == Self.playlistDescription
    }

    private func playlist(_ id: String) async throws -> Playlist {
        do {
            return try await spotifyGet(
                "playlists/\(id)", fields: "id,name,description,owner(id),public,collaborative"
            )
        } catch Failure.notFound {
            throw Failure.playlistMissing
        }
    }

    // The stock CLI omits playlist visibility. Use the same sign-in for the reads
    // that check visibility, ownership, and duplicates before the CLI adds a track.
    private func spotifyGet<Response: Decodable>(
        _ path: String, fields: String? = nil, offset: Int? = nil, signInToken: Data? = nil
    ) async throws -> Response {
        guard let tokenData = signInToken ?? storedSession?.token else { throw Failure.reauthorizationRequired }
        let token = try Self.decode(Token.self, from: tokenData)
        var url = URLComponents(string: "https://api.spotify.com/v1/\(path)")!
        var query: [URLQueryItem] = []
        if let fields { query.append(URLQueryItem(name: "fields", value: fields)) }
        if let offset {
            query += [URLQueryItem(name: "limit", value: "50"), URLQueryItem(name: "offset", value: String(offset))]
        }
        url.queryItems = query.isEmpty ? nil : query
        guard let endpoint = url.url else { throw HelperError.invalidResponse }
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw HelperError.invalidResponse }
        switch response.statusCode {
        case 200: return try Self.decode(Response.self, from: data)
        case 401: throw Failure.reauthorizationRequired
        case 404: throw Failure.notFound
        case 429: throw Failure.rateLimited
        default: throw Failure.commandFailed
        }
    }

    func invalidate() {
        guard isValid else { return }
        isValid = false
        // Wait for helpers to exit before removing the files they can write.
        let active = invocations
        for invocation in active.values {
            invocation.failure = CancellationError()
            if invocation.process.isRunning {
                kill(invocation.process.processIdentifier, SIGKILL)
            }
        }
        for (id, invocation) in active {
            invocation.process.waitUntilExit()
            finish(id, status: invocation.process.terminationStatus)
        }
        storedSession = nil
    }

    private func run(
        _ command: Command,
        arguments: [String] = [],
        timeout: Duration = .seconds(30)
    ) async throws -> InvocationResult {
        let id = UUID()
        let deadline = ContinuousClock.now.advanced(by: timeout)
        let result: InvocationResult = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            guard isValid else { throw CancellationError() }
            guard Self.isAvailable else { throw HelperError.unavailable }
            guard command == .signIn || storedSession != nil else { throw Failure.reauthorizationRequired }
            return try await withCheckedThrowingContinuation { continuation in
                start(id, command: command, arguments: arguments, deadline: deadline, continuation: continuation)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.stop(id, with: CancellationError()) }
        }
        try Task.checkCancellation()
        guard isValid else { throw CancellationError() }
        return result
    }

    private func start(
        _ id: UUID, command: Command, arguments: [String], deadline: ContinuousClock.Instant,
        continuation: CheckedContinuation<InvocationResult, any Error>
    ) {
        // The helper rewrites credentials in place. Give each process its own copy.
        let cache = HelperCache(id: id)
        let session = command == .signIn ? nil : storedSession
        do {
            try cache.prepare(with: session)
            let handle = try FileHandle(forWritingTo: cache.output)
            defer { try? handle.close() }
            let errorHandle = try FileHandle(forWritingTo: cache.errors)
            defer { try? errorHandle.close() }

            let process = Process()
            process.executableURL = Self.helperURL
            process.arguments = [
                "--config-folder", cache.directory.appending(path: "config").path,
                "--cache-folder", cache.directory.path,
                "--config-override", "client_port=\(try Self.availableClientPort())",
                "--config-override", "enable_streaming=Never",
                "--config-override", "enable_media_control=false",
            ] + command.arguments + arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = handle
            process.standardError = errorHandle
            process.terminationHandler = { [weak self] process in
                let status = process.terminationStatus
                Task { @MainActor [weak self] in self?.finish(id, status: status) }
            }

            try process.run()
            let invocation = Invocation(
                command: command, process: process, cache: cache, sessionAtLaunch: session,
                continuation: continuation
            )
            invocations[id] = invocation
            invocation.timeoutTask = Task { [weak self] in
                do {
                    if command == .signIn {
                        while ContinuousClock.now < deadline {
                            guard let self else { return }
                            if process.isRunning, let signIn = try? cache.readSignIn() {
                                self.invocations[id]?.signIn = signIn
                                self.stop(id, with: nil)
                                return
                            }
                            try await Task.sleep(for: .milliseconds(150))
                        }
                    } else {
                        try await ContinuousClock().sleep(until: deadline)
                    }
                    self?.stop(id, with: HelperError.timedOut(command))
                } catch {
                    return
                }
            }
        } catch {
            cache.remove()
            continuation.resume(throwing: HelperError.couldNotStart)
        }
    }

    private func stop(_ id: UUID, with error: (any Error)?) {
        guard let invocation = invocations[id], invocation.killTask == nil else { return }
        invocation.failure = error
        invocation.timeoutTask?.cancel()
        if invocation.process.isRunning { invocation.process.terminate() }
        invocation.killTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(500))
                guard let process = self?.invocations[id]?.process, process.isRunning else { return }
                kill(process.processIdentifier, SIGKILL)
            } catch {
                return
            }
        }
    }

    private func finish(_ id: UUID, status: Int32) {
        guard let invocation = invocations.removeValue(forKey: id) else { return }
        invocation.timeoutTask?.cancel()
        invocation.killTask?.cancel()
        defer { invocation.cache.remove() }
        if let error = invocation.failure {
            invocation.continuation.resume(throwing: error)
        } else if invocation.command == .signIn {
            // Without a terminal the player may exit on its own after saving the credentials.
            if let signIn = invocation.signIn ?? (try? invocation.cache.readSignIn()) {
                invocation.continuation.resume(returning: .signIn(signIn))
            } else {
                invocation.continuation.resume(throwing: Failure.authenticationFailed)
            }
        } else if status != 0 {
            let data = try? Self.readOutput(invocation.cache.errors)
            let message = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let failure: any Error
            if message.contains("401 Unauthorized") || message.contains("No cached credentials found") {
                failure = Failure.reauthorizationRequired
            } else if message.contains("429 Too Many Requests") {
                failure = Failure.rateLimited
            } else {
                failure = HelperError.commandFailed(invocation.command)
            }
            invocation.continuation.resume(throwing: failure)
        } else {
            do {
                try persistRefresh(from: invocation)
                let data = invocation.command == .refreshPlaylistAccess
                    ? Data()
                    : try Self.readOutput(invocation.cache.output, limit: 256 * 1024)
                invocation.continuation.resume(returning: .output(data))
            } catch {
                invocation.continuation.resume(throwing: error)
            }
        }
    }

    private static func readOutput(_ url: URL, limit: Int = 16 * 1024) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else {
            throw HelperError.invalidResponse
        }
        return data
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw HelperError.invalidResponse
        }
    }

    private static func isTokenFilename(_ name: String) -> Bool {
        let suffix = "_token.json"
        return name.hasSuffix(suffix) && isSpotifyID(name.dropLast(suffix.count))
    }

    // The stock CLI will otherwise look for any player on its default local port.
    private static func availableClientPort() throws -> UInt16 {
        let socket = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        guard socket >= 0 else { throw HelperError.couldNotStart }
        defer { Darwin.close(socket) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(socket, $0, length) }
        }
        guard bound == 0 else { throw HelperError.couldNotStart }
        let loaded = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socket, $0, &length) }
        }
        guard loaded == 0 else { throw HelperError.couldNotStart }
        return UInt16(bigEndian: address.sin_port)
    }

    private static func nonemptyName(_ value: String?) -> String? {
        guard let name = value?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        return name
    }

    private static func isSpotifyID(_ id: some StringProtocol) -> Bool {
        (1...64).contains(id.utf8.count) && id.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
        }
    }

    private enum Command {
        case signIn, playing, refreshPlaylistAccess, create, save

        @MainActor var arguments: [String] {
            switch self {
            case .signIn: []
            case .playing: ["get", "key", "playback"]
            case .refreshPlaylistAccess: ["playlist", "list"]
            case .create: ["playlist", "new", SpotifyPlayerConnection.playlistName, SpotifyPlayerConnection.playlistDescription]
            case .save: ["playlist", "edit", "add"]
            }
        }

        var action: String {
            switch self {
            case .signIn: "connect to Spotify"
            case .playing: "read Spotify playback"
            case .refreshPlaylistAccess: "refresh Spotify playlist access"
            case .create: "set up the Bop! playlist"
            case .save: "save the track to your playlist"
            }
        }
    }

    private enum HelperError: LocalizedError {
        case unavailable, couldNotStart, timedOut(Command), commandFailed(Command), invalidResponse

        var errorDescription: String? {
            switch self {
            case .unavailable: "Spotify support isn’t installed in this build."
            case .couldNotStart: "Bop couldn’t open the Spotify helper."
            case .timedOut(let command): "Bop timed out while trying to \(command.action)."
            case .commandFailed(let command): "Bop couldn’t \(command.action)."
            case .invalidResponse: "Spotify returned an unexpected response."
            }
        }
    }

    private enum InvocationResult {
        case signIn(SpotifyKeychain.PlayerSession)
        case output(Data)
    }

    @MainActor
    private struct HelperCache {
        let directory: URL
        var credentialsFile: URL { directory.appending(path: "credentials.json") }
        var output: URL { directory.appending(path: "stdout") }
        var errors: URL { directory.appending(path: "stderr") }

        init(id: UUID) {
            directory = FileManager.default.temporaryDirectory
                .appending(path: "bop-spotify-player-\(id.uuidString)", directoryHint: .isDirectory)
        }

        func prepare(with session: SpotifyKeychain.PlayerSession?) throws {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
            )
            if let session, let filename = session.tokenFilename, let credentials = session.credentials {
                try writePrivateFile(session.token, to: directory.appending(path: filename))
                try writePrivateFile(credentials, to: credentialsFile)
            }
            try writePrivateFile(nil, to: output)
            try writePrivateFile(nil, to: errors)
        }

        func readSignIn() throws -> SpotifyKeychain.PlayerSession {
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            let tokenFiles = files.filter { SpotifyPlayerConnection.isTokenFilename($0.lastPathComponent) }
            guard tokenFiles.count == 1, let tokenFile = tokenFiles.first else { throw Failure.authenticationFailed }
            let token = try SpotifyPlayerConnection.readOutput(tokenFile)
            _ = try SpotifyPlayerConnection.decode(Token.self, from: token)
            let credentials = try SpotifyPlayerConnection.readOutput(credentialsFile)
            let user = try SpotifyPlayerConnection.decode(Credentials.self, from: credentials)
            guard !user.username.isEmpty else { throw Failure.authenticationFailed }
            return SpotifyKeychain.PlayerSession(
                accountID: user.username, token: token, tokenFilename: tokenFile.lastPathComponent,
                credentials: credentials
            )
        }

        func remove() {
            try? FileManager.default.removeItem(at: directory)
        }

        private func writePrivateFile(_ data: Data?, to url: URL) throws {
            guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                throw HelperError.couldNotStart
            }
        }
    }

    @MainActor
    private final class Invocation {
        let command: Command
        let process: Process
        let cache: HelperCache
        let sessionAtLaunch: SpotifyKeychain.PlayerSession?
        let continuation: CheckedContinuation<InvocationResult, any Error>
        var signIn: SpotifyKeychain.PlayerSession?
        var failure: (any Error)?
        var timeoutTask: Task<Void, Never>?
        var killTask: Task<Void, Never>?

        init(
            command: Command, process: Process, cache: HelperCache, sessionAtLaunch: SpotifyKeychain.PlayerSession?,
            continuation: CheckedContinuation<InvocationResult, any Error>
        ) {
            self.command = command
            self.process = process
            self.cache = cache
            self.sessionAtLaunch = sessionAtLaunch
            self.continuation = continuation
        }
    }

    private struct Profile: Decodable { let id: String }
    private struct Credentials: Decodable { let username: String }
    private struct Token: Decodable {
        let accessToken: String
        let refreshToken: String

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
        }
    }
    private struct Playlist: Decodable {
        let id: String
        let name: String
        let owner: Profile
        let description: String?
        let collaborative: Bool?
        let isPublic: Bool?

        enum CodingKeys: String, CodingKey {
            case id, name, owner, description, collaborative
            case isPublic = "public"
        }
    }
    private struct Page<Item: Decodable>: Decodable {
        let items: [Item]
        let next: String?
    }
    private struct PlaylistItem: Decodable {
        struct Track: Decodable { let uri: String? }
        let item: Track?
        let track: Track?
    }
    private struct PlayingResponse: Decodable {
        struct Device: Decodable {
            let isPrivateSession: Bool?
            enum CodingKeys: String, CodingKey { case isPrivateSession = "is_private_session" }
        }

        struct Item: Decodable {
            struct Artist: Decodable { let name: String? }

            let type: String?
            let id: String?
            let name: String?
            let artists: [Artist]?
            let isLocal: Bool?
            enum CodingKeys: String, CodingKey { case type, id, name, artists, isLocal = "is_local" }
        }

        let device: Device?
        let isPlaying: Bool?
        let currentlyPlayingType: String?
        let progressMilliseconds: Int?
        let timestamp: Int?
        let item: Item?

        enum CodingKeys: String, CodingKey {
            case device, timestamp, item
            case isPlaying = "is_playing"
            case currentlyPlayingType = "currently_playing_type"
            case progressMilliseconds = "progress_ms"
        }
    }
    enum SaveResult { case saved, alreadySaved }

    enum Failure: String, LocalizedError {
        case reauthorizationRequired, authenticationFailed, accountMismatch, rateLimited
        case playlistUnavailable, playlistMissing, playlistVisible, commandFailed, notFound

        var errorDescription: String? {
            switch self {
            case .reauthorizationRequired: "Reconnect Spotify to resume saving bops."
            case .authenticationFailed: "Spotify sign-in didn’t finish. Try connecting again."
            case .accountMismatch: "Use the same Spotify account on both approval screens."
            case .rateLimited: "Spotify is receiving too many requests. Try again later."
            case .playlistUnavailable: "Bop couldn’t verify that it can write to your playlist."
            case .playlistMissing: "Spotify couldn’t find your playlist."
            case .playlistVisible: "Spotify didn’t confirm that your playlist is hidden. Check its visibility in Spotify, then try again."
            case .commandFailed: "Spotify couldn’t complete the request."
            case .notFound: "Spotify couldn’t find the requested information."
            }
        }
    }
}
