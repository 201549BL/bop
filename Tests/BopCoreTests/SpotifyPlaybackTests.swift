import BopCore
import Foundation
import XCTest

final class SpotifyPlaybackTests: XCTestCase {
    private let bop = Date(timeIntervalSince1970: 1_000)
    private let track = SpotifyPlayback.Item(
        uri: "spotify:track:1yzeBgkPa9EqnIRjDdXJTe", type: "track", name: " The Rust Belt ",
        artists: ["Patrik Andrén", "", "Johan Söderqvist"], isLocal: false
    )

    func testCapturesTrackPlayingWhenBopHappened() {
        let playback = playing(startedAt: bop.addingTimeInterval(-20), position: 5)
        XCTAssertEqual(
            playback.boppedTrack(detectedAt: bop, now: bop.addingTimeInterval(0.4)),
            SpotifyBoppedTrack(
                uri: "spotify:track:1yzeBgkPa9EqnIRjDdXJTe", title: "The Rust Belt",
                artist: "Patrik Andrén, Johan Söderqvist"
            )
        )
    }

    func testReadsOutsideTheBopWindowCaptureNothing() {
        let playback = playing(startedAt: bop.addingTimeInterval(-20), position: 5)
        XCTAssertEqual(playback.boppedTrack(detectedAt: bop, now: bop.addingTimeInterval(3))?.title, "The Rust Belt")
        XCTAssertNil(playback.boppedTrack(detectedAt: bop, now: bop.addingTimeInterval(3.01)))
        XCTAssertNil(playback.boppedTrack(detectedAt: bop, now: bop.addingTimeInterval(-0.01)))
    }

    func testPausedOrPrivatePlaybackCapturesNothing() {
        let start = bop.addingTimeInterval(-20)
        XCTAssertNil(playing(startedAt: start, position: 5, isPaused: true).boppedTrack(detectedAt: bop, now: bop))
        XCTAssertNil(playing(startedAt: start, position: 5, isPrivateSession: true).boppedTrack(detectedAt: bop, now: bop))
    }

    func testOnlySpotifyTracksAreCaptured() {
        let start = bop.addingTimeInterval(-20)
        let cases: [(SpotifyPlayback.Item?, String?)] = [
            (track, "spotify:track:1yzeBgkPa9EqnIRjDdXJTe"),
            (nil, nil),
            (item(uri: "spotify:episode:4rOoJ6Egrf8K2IrywzwOMk", type: "episode"), nil),
            (item(uri: "spotify:local:Artist:Album:Song:180", type: "track", isLocal: true), nil),
            (item(uri: "spotify:track:1yzeBgkPa9EqnIRjDdXJTe", type: "track", isLocal: true), nil),
            (item(uri: "spotify:track:not-an-id", type: "track"), nil),
            (item(uri: "spotify:ad:1yzeBgkPa9EqnIRjDdXJTe", type: "track"), nil),
        ]
        for (item, expected) in cases {
            let playback = SpotifyPlayback(
                timestamp: start, positionAsOfTimestamp: 5, isPaused: false, isPrivateSession: false, item: item
            )
            XCTAssertEqual(playback.boppedTrack(detectedAt: bop, now: bop)?.uri, expected, "\(String(describing: item))")
        }
    }

    func testPlaybackThatChangedAfterTheBopCapturesNothing() {
        let seekedAfterBop = playing(startedAt: bop.addingTimeInterval(0.2), position: 60)
        XCTAssertNil(seekedAfterBop.boppedTrack(detectedAt: bop, now: bop.addingTimeInterval(1)))

        let changedAtBop = playing(startedAt: bop, position: 0)
        XCTAssertEqual(changedAtBop.boppedTrack(detectedAt: bop, now: bop.addingTimeInterval(1))?.title, "The Rust Belt")
    }

    func testPositionBeforeTheTrackStartAtBopTimeCapturesNothing() {
        let lateStart = playing(startedAt: bop.addingTimeInterval(-1), position: -1.5)
        XCTAssertNil(lateStart.boppedTrack(detectedAt: bop, now: bop.addingTimeInterval(1)))

        let onTime = playing(startedAt: bop.addingTimeInterval(-1), position: -0.5)
        XCTAssertEqual(onTime.boppedTrack(detectedAt: bop, now: bop.addingTimeInterval(1))?.title, "The Rust Belt")
    }

    func testMissingNamesBecomeNil() {
        let unnamed = SpotifyPlayback(
            timestamp: bop.addingTimeInterval(-20), positionAsOfTimestamp: 5, isPaused: false, isPrivateSession: false,
            item: item(uri: "spotify:track:1yzeBgkPa9EqnIRjDdXJTe", type: "track", artists: [" "])
        )
        XCTAssertEqual(
            unnamed.boppedTrack(detectedAt: bop, now: bop),
            SpotifyBoppedTrack(uri: "spotify:track:1yzeBgkPa9EqnIRjDdXJTe", title: nil, artist: nil)
        )
    }

    func testTrackURL() {
        XCTAssertEqual(
            SpotifyBoppedTrack(uri: "spotify:track:1yzeBgkPa9EqnIRjDdXJTe", title: nil, artist: nil).url,
            URL(string: "https://open.spotify.com/track/1yzeBgkPa9EqnIRjDdXJTe")
        )
        XCTAssertNil(SpotifyBoppedTrack(uri: "spotify:episode:4rOoJ6Egrf8K2IrywzwOMk", title: nil, artist: nil).url)
    }

    private func playing(
        startedAt timestamp: Date, position: TimeInterval, isPaused: Bool = false, isPrivateSession: Bool = false
    ) -> SpotifyPlayback {
        SpotifyPlayback(
            timestamp: timestamp, positionAsOfTimestamp: position, isPaused: isPaused,
            isPrivateSession: isPrivateSession, item: track
        )
    }

    private func item(uri: String, type: String, artists: [String] = [], isLocal: Bool = false) -> SpotifyPlayback.Item {
        SpotifyPlayback.Item(uri: uri, type: type, name: nil, artists: artists, isLocal: isLocal)
    }
}
