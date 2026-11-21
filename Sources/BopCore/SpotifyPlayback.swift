import Foundation

public struct SpotifyBoppedTrack: Codable, Equatable, Sendable {
    public static let uriPrefix = "spotify:track:"

    public let uri: String
    public let title: String?
    public let artist: String?

    public init(uri: String, title: String?, artist: String?) {
        self.uri = uri
        self.title = title
        self.artist = artist
    }

    public var url: URL? {
        guard uri.hasPrefix(Self.uriPrefix) else { return nil }
        let id = uri.dropFirst(Self.uriPrefix.count)
        guard Self.isSpotifyID(id) else { return nil }
        return URL(string: "https://open.spotify.com/track/\(id)")
    }

    public static func isSpotifyID(_ id: some StringProtocol) -> Bool {
        (1...64).contains(id.utf8.count) && id.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
        }
    }
}

/// What the Spotify app reported about playback at one moment.
public struct SpotifyPlayback: Equatable, Sendable {
    public struct Item: Equatable, Sendable {
        public let uri: String
        public let type: String
        public let name: String?
        public let artists: [String]
        public let isLocal: Bool

        public init(uri: String, type: String, name: String?, artists: [String], isLocal: Bool) {
            self.uri = uri
            self.type = type
            self.name = name
            self.artists = artists
            self.isLocal = isLocal
        }
    }

    /// When Spotify last changed the play state, such as starting, seeking, or skipping.
    public let timestamp: Date
    public let positionAsOfTimestamp: TimeInterval
    public let isPaused: Bool
    public let isPrivateSession: Bool
    public let item: Item?

    public init(
        timestamp: Date, positionAsOfTimestamp: TimeInterval, isPaused: Bool, isPrivateSession: Bool, item: Item?
    ) {
        self.timestamp = timestamp
        self.positionAsOfTimestamp = positionAsOfTimestamp
        self.isPaused = isPaused
        self.isPrivateSession = isPrivateSession
        self.item = item
    }

    public static let bopWindow: TimeInterval = 3

    /// The track a bop at `detectedAt` belongs to, judged from playback read at `now`.
    /// A read that arrives after the bop window, or that can't prove the track was already playing
    /// when the bop happened, captures nothing.
    public func boppedTrack(detectedAt: Date, now: Date) -> SpotifyBoppedTrack? {
        let age = now.timeIntervalSince(detectedAt)
        guard (0...Self.bopWindow).contains(age), !isPaused, !isPrivateSession,
              let item, item.type == "track", !item.isLocal, item.uri.hasPrefix(SpotifyBoppedTrack.uriPrefix),
              SpotifyBoppedTrack.isSpotifyID(item.uri.dropFirst(SpotifyBoppedTrack.uriPrefix.count)),
              timestamp <= detectedAt,
              positionAsOfTimestamp + now.timeIntervalSince(timestamp) >= age else { return nil }
        let artists = item.artists.compactMap(Self.nonempty)
        return SpotifyBoppedTrack(
            uri: item.uri,
            title: Self.nonempty(item.name),
            artist: artists.isEmpty ? nil : artists.joined(separator: ", ")
        )
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let name = value?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        return name
    }
}
