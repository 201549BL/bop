import AppKit
import BopCore
import Foundation

/// Controls the Spotify desktop app through its Chrome DevTools port on 127.0.0.1.
@MainActor
final class SpotifyDesktop {
    /// The same port spotr uses, so both tools share one Spotify launch.
    nonisolated static let port = 9222
    private static let bundleIdentifier = "com.spotify.client"
    private nonisolated static let playlistName = "Bop!"
    private nonisolated static let managedPlaylistNames: Set<String> = [playlistName, "Bop"]
    private nonisolated static let playlistDescription = "Songs you bopped to with Bop. [Bop Spotify Player]"
    private nonisolated static let playlistPrefix = "spotify:playlist:"

    private static let agentSource: String = {
        guard let url = Bundle.main.url(forResource: "SpotifyAgent", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            preconditionFailure("SpotifyAgent.js is missing from the app bundle")
        }
        return source
    }()

    enum SaveResult { case saved, alreadySaved }

    struct Capture {
        let accountID: String
        let track: SpotifyBoppedTrack?
    }

    enum Failure: Error, Equatable, LocalizedError {
        case notInstalled, notRunning, missingDebugPort, launchFailed, quitFailed, loading
        case changed, rejected, timedOut
        case playlistUnavailable, playlistMissing

        var errorDescription: String? {
            switch self {
            case .notInstalled: "Install the Spotify app to save bops."
            case .notRunning: "Open Spotify to save bops."
            case .missingDebugPort: "Restart Spotify from Bop’s settings to save bops."
            case .launchFailed: "Bop couldn’t open Spotify."
            case .quitFailed: "Spotify didn’t quit. Quit Spotify, then try again."
            case .loading: "Spotify is still starting. Make sure you’re signed in, then try again."
            case .changed: "Spotify changed something Bop relies on. Check for a Bop update."
            case .rejected: "Spotify couldn’t complete the request."
            case .timedOut: "Spotify took too long to respond."
            case .playlistUnavailable: "Bop couldn’t verify that it can write to your playlist."
            case .playlistMissing: "Spotify couldn’t find your playlist."
            }
        }
    }

    static func playlistURL(for id: String) -> URL? {
        guard SpotifyBoppedTrack.isSpotifyID(id) else { return nil }
        return URL(string: "https://open.spotify.com/playlist/\(id)")
    }

    private static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }

    // MARK: Connecting

    /// The signed-in account of a Spotify that already has its debugging port open.
    func accountID() async throws -> String {
        let user: PageResult<User> = try await evaluate(#"return agent.dispatch("UserAPI", "getUser", [])"#)
        return try user.get().username
    }

    /// Opens Spotify with its debugging port when it isn't running. A Spotify already running
    /// without the port is left alone, since only the user should decide to interrupt playback.
    func launch() async throws -> String {
        do {
            return try await accountID()
        } catch Failure.notRunning {
            try await open()
            return try await waitUntilReady()
        }
    }

    /// Quits Spotify gracefully, then opens it again with the debugging port.
    func restart() async throws -> String {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier) {
            app.terminate()
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while Self.isRunning {
            guard ContinuousClock.now < deadline else { throw Failure.quitFailed }
            try await Task.sleep(for: .milliseconds(250))
        }
        try await open()
        return try await waitUntilReady()
    }

    private func open() async throws {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleIdentifier) else {
            throw Failure.notInstalled
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["--remote-debugging-port=\(Self.port)"]
        configuration.activates = false
        do {
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        } catch {
            throw Failure.launchFailed
        }
    }

    private func waitUntilReady() async throws -> String {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while true {
            do {
                return try await accountID()
            } catch let failure as Failure where [.notRunning, .missingDebugPort, .loading, .timedOut].contains(failure) {
                guard ContinuousClock.now < deadline else { throw failure }
                try await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    // MARK: Playback

    func playing(detectedAt: Date) async throws -> Capture? {
        let initialAge = Date().timeIntervalSince(detectedAt)
        guard (0..<SpotifyPlayback.bopWindow).contains(initialAge) else { return nil }
        let reply: PlaybackReply = try await evaluate("""
            const [state, privateSession, user] = await Promise.all([
              agent.dispatch("PlayerAPI", "getState", []),
              agent.privateSession(),
              agent.dispatch("UserAPI", "getUser", []),
            ])
            return { state, privateSession, user }
            """, timeout: .seconds(SpotifyPlayback.bopWindow - initialAge))
        let playback = try reply.state.get().playback(isPrivateSession: reply.privateSession.get())
        return Capture(
            accountID: try reply.user.get().username,
            track: playback.boppedTrack(detectedAt: detectedAt, now: Date())
        )
    }

    // MARK: Playlist

    /// The playlist Bop made earlier in the user's library, if there is exactly one.
    func managedPlaylist() async throws -> String? {
        let rootlist: PageResult<Playlist> = try await evaluate(#"return agent.dispatch("RootlistAPI", "getContents", [])"#)
        let managed = try rootlist.get().playlists.filter(\.isManaged).compactMap(\.id)
        guard managed.count <= 1 else { throw Failure.playlistUnavailable }
        return managed.first
    }

    /// Finds the playlist Bop made earlier, or makes a private one.
    func createPlaylist() async throws -> String {
        if let existing = try await managedPlaylist() { return existing }

        let created: PageResult<String?> = try await evaluate("""
            return agent.dispatch("RootlistAPI", "createPlaylist", [\(Self.literal(Self.playlistName)), { before: "start" }, {}])
            """)
        guard let uri = try created.get(), let id = Self.playlistID(fromURI: uri) else { throw Failure.rejected }
        // The description comes first, so a retry after a failed step finds this playlist instead of making another.
        let steps: [PageResult<Discarded?>] = try await evaluate("""
            const uri = \(Self.literal(uri))
            const steps = [await agent.dispatch("PlaylistAPI", "updateDetails", [uri, { description: \(Self.literal(Self.playlistDescription)) }])]
            if (steps[0].ok) steps.push(await agent.dispatch("PlaylistPermissionsAPI", "setBasePermission", [uri, "BLOCKED"]))
            if (steps.at(-1).ok) steps.push(await agent.dispatch("RootlistAPI", "setPublishedState", [uri, false]))
            return steps
            """, timeout: .seconds(15))
        for step in steps { _ = try step.get() }
        return id
    }

    func validatePlaylist(_ id: String) async throws {
        try await requireWritablePlaylist(id)
    }

    func save(trackURI: String, playlistID: String) async throws -> SaveResult {
        guard trackURI.hasPrefix(SpotifyBoppedTrack.uriPrefix),
              SpotifyBoppedTrack.isSpotifyID(trackURI.dropFirst(SpotifyBoppedTrack.uriPrefix.count)) else {
            throw Failure.rejected
        }
        try await requireWritablePlaylist(playlistID)
        let uri = Self.literal(Self.playlistPrefix + playlistID)

        var offset = 0
        while true {
            let page: PageResult<Contents> = try await evaluate("""
                return agent.dispatch("PlaylistAPI", "getContents", [\(uri), { offset: \(offset), limit: 100 }])
                """)
            let contents = try page.get()
            if contents.items.contains(where: { $0.uri == trackURI }) { return .alreadySaved }
            offset += contents.items.count
            if contents.items.isEmpty || offset >= contents.totalLength { break }
        }

        let added: PageResult<Discarded?> = try await evaluate("""
            return agent.dispatch("PlaylistAPI", "add", [\(uri), [\(Self.literal(trackURI))], { after: "end" }, {}])
            """, timeout: .seconds(10))
        _ = try added.get()
        return .saved
    }

    private func requireWritablePlaylist(_ id: String) async throws {
        guard SpotifyBoppedTrack.isSpotifyID(id) else { throw Failure.playlistUnavailable }
        let uri = Self.literal(Self.playlistPrefix + id)
        // Spotify never answers a metadata request for a playlist that doesn't exist, so check the
        // library first. A playlist the user removed from their library counts as missing.
        let reply: PlaylistReply = try await evaluate("""
            const contains = await agent.dispatch("RootlistAPI", "contains", [[\(uri)]])
            if (!contains.ok || contains.value?.[0] !== true) return { contains }
            return { contains, metadata: await agent.dispatch("PlaylistAPI", "getMetadata", [\(uri)]) }
            """)
        guard try reply.contains.get() == [true], let metadata = reply.metadata else { throw Failure.playlistMissing }
        let playlist = try metadata.get()
        // The user may rename, share, or open up the playlist later. Bop only needs to own it.
        guard playlist.id == id, playlist.isOwnedBySelf == true else { throw Failure.playlistUnavailable }
    }

    private nonisolated static func playlistID(fromURI uri: String) -> String? {
        guard uri.hasPrefix(playlistPrefix) else { return nil }
        let id = String(uri.dropFirst(playlistPrefix.count))
        return SpotifyBoppedTrack.isSpotifyID(id) ? id : nil
    }

    private static func literal(_ value: String) -> String {
        String(decoding: try! JSONEncoder().encode(value), as: UTF8.self)
    }

    // MARK: DevTools transport

    /// Runs `body` as an async function in Spotify's page with `agent` in scope, and decodes what it returns.
    private func evaluate<Value: Decodable>(_ body: String, timeout: Duration = .seconds(5)) async throws -> Value {
        let expression = "(async () => { const agent = (\(Self.agentSource))(); \(body) })()"
        let frame: Data
        do {
            frame = try await Self.run(expression, timeout: timeout)
        } catch DevToolsError.portClosed {
            throw Self.isRunning ? Failure.missingDebugPort : Failure.notRunning
        }
        guard let reply = try? JSONDecoder().decode(EvaluateReply<Value>.self, from: frame),
              let value = reply.result?.result?.value else { throw Failure.changed }
        return value
    }

    private enum DevToolsError: Error { case portClosed }

    private nonisolated static func run(_ expression: String, timeout: Duration) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { try await exchange(expression) }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw Failure.timedOut
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    /// Sends one `Runtime.evaluate` and returns Chromium's reply frame.
    private nonisolated static func exchange(_ expression: String) async throws -> Data {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }

        let list = URLRequest(
            url: URL(string: "http://127.0.0.1:\(port)/json/list")!,
            cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 2
        )
        let targets: [Target]
        do {
            let (data, _) = try await session.data(for: list)
            targets = try JSONDecoder().decode([Target].self, from: data)
        } catch {
            try Task.checkCancellation()
            throw DevToolsError.portClosed
        }
        // Chromium lists the page with the host Bop asked for. Rebuild the address anyway so the
        // socket can only ever reach this Mac's loopback port.
        guard let page = targets.first(where: { $0.type == "page" && $0.url.contains("xpui") }),
              var endpoint = URLComponents(string: page.webSocketDebuggerUrl), endpoint.scheme == "ws" else {
            throw Failure.loading
        }
        endpoint.host = "127.0.0.1"
        endpoint.port = port
        guard let socketURL = endpoint.url else { throw Failure.loading }

        let socket = session.webSocketTask(with: socketURL)
        socket.maximumMessageSize = 8 * 1024 * 1024
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }

        let request = EvaluateRequest(params: .init(expression: expression))
        do {
            // Chromium closes the socket on binary frames, so send text.
            try await socket.send(.string(String(decoding: JSONEncoder().encode(request), as: UTF8.self)))
            // Chromium may send other frames first, so read until the reply to this request.
            while true {
                let frame: Data
                switch try await socket.receive() {
                case .data(let data): frame = data
                case .string(let text): frame = Data(text.utf8)
                @unknown default: continue
                }
                if (try? JSONDecoder().decode(FrameID.self, from: frame))?.id == request.id { return frame }
            }
        } catch {
            try Task.checkCancellation()
            throw Failure.rejected
        }
    }

    // MARK: Wire formats

    private struct Target: Decodable {
        let type: String
        let url: String
        let webSocketDebuggerUrl: String
    }

    private struct EvaluateRequest: Encodable {
        struct Params: Encodable {
            let expression: String
            let awaitPromise = true
            let returnByValue = true
        }

        let id = 1
        let method = "Runtime.evaluate"
        let params: Params
    }

    private struct FrameID: Decodable {
        let id: Int?
    }

    /// A page exception leaves `value` out, which Bop treats like any other unexpected shape.
    private struct EvaluateReply<Value: Decodable>: Decodable {
        struct Outcome: Decodable {
            struct Remote: Decodable { let value: Value? }

            let result: Remote?
        }

        let result: Outcome?
    }

    /// What the page agent's calls resolve to.
    private enum PageResult<Value: Decodable>: Decodable {
        case success(Value)
        case failure(kind: String)

        private enum CodingKeys: String, CodingKey { case ok, value, kind }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if try container.decode(Bool.self, forKey: .ok) {
                self = .success(try container.decode(Value.self, forKey: .value))
            } else {
                self = .failure(kind: try container.decode(String.self, forKey: .kind))
            }
        }

        func get() throws -> Value {
            switch self {
            case .success(let value): return value
            case .failure(kind: "NotReady"): throw Failure.loading
            case .failure(kind: "Rejected"): throw Failure.rejected
            case .failure: throw Failure.changed
            }
        }
    }

    private struct Discarded: Decodable {
        init(from decoder: any Decoder) throws {}
    }

    private struct User: Decodable {
        let username: String
    }

    private struct PlaybackReply: Decodable {
        let state: PageResult<PlayerState>
        let privateSession: PageResult<Bool>
        let user: PageResult<User>
    }

    private struct PlayerState: Decodable {
        struct Item: Decodable {
            struct Artist: Decodable { let name: String? }

            let uri: String
            let type: String
            let name: String?
            let artists: [Artist]?
            let isLocal: Bool?
        }

        let timestamp: Double
        let positionAsOfTimestamp: Double
        let isPaused: Bool
        let item: Item?

        func playback(isPrivateSession: Bool) -> SpotifyPlayback {
            SpotifyPlayback(
                timestamp: Date(timeIntervalSince1970: timestamp / 1000),
                positionAsOfTimestamp: positionAsOfTimestamp / 1000,
                isPaused: isPaused,
                isPrivateSession: isPrivateSession,
                item: item.map {
                    SpotifyPlayback.Item(
                        uri: $0.uri, type: $0.type, name: $0.name,
                        artists: $0.artists?.compactMap(\.name) ?? [], isLocal: $0.isLocal ?? false
                    )
                }
            )
        }
    }

    private struct PlaylistReply: Decodable {
        let contains: PageResult<[Bool]>
        let metadata: PageResult<Playlist>?
    }

    /// A rootlist entry or playlist metadata. Folders, and the rootlist itself, nest entries under `items`.
    private struct Playlist: Decodable {
        let type: String
        let uri: String?
        let name: String?
        let description: String?
        let isOwnedBySelf: Bool?
        let items: [Playlist]?

        var id: String? { uri.flatMap(SpotifyDesktop.playlistID(fromURI:)) }

        var playlists: [Playlist] {
            (items ?? []).flatMap { $0.type == "folder" ? $0.playlists : $0.type == "playlist" ? [$0] : [] }
        }

        var isManaged: Bool {
            isOwnedBySelf == true && SpotifyDesktop.managedPlaylistNames.contains(name ?? "")
                && description == SpotifyDesktop.playlistDescription
        }
    }

    private struct Contents: Decodable {
        struct Item: Decodable { let uri: String? }

        let items: [Item]
        let totalLength: Int
    }
}
