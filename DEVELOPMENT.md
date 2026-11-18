# Developing Bop

Use Xcode with Swift 6. Open `Bop.xcodeproj` and run the **Bop** scheme on **My Mac**. Run `swift test` for detector tests. After changing `project.yml` or adding app source files, regenerate the project with `xcodegen generate`.

## Build with Spotify support

Install Rust and Cargo, then run these commands from the repository root.

```sh
bash Tools/SpotifyPlayer/build.sh --native
xcodebuild -scheme Bop build BOP_BUNDLE_SPOTIFY_PLAYER=YES
```

For a universal build, install the Rust targets `aarch64-apple-darwin` and `x86_64-apple-darwin`, then use `--stage` in place of `--native`. The build pins spotify-player v0.25.2 with the upstream callback fix, omits integrated audio streaming, and uses upstream's shared Spotify client ID and rate limits. [Upstream callback fix](https://github.com/aome510/spotify-player/pull/1115)

To keep Keychain approval across Debug builds, add a local `Config/LocalSigning.xcconfig` with `CODE_SIGN_STYLE = Manual`, your `DEVELOPMENT_TEAM`, and `BOP_DEBUG_CODE_SIGN_IDENTITY` set to your Apple Development certificate fingerprint from `security find-identity -v -p codesigning`. Git ignores this file. macOS may ask you to approve the existing Spotify Keychain item the first time you change signing identities.

## Verify with AirPods and Spotify

1. Complete AirPods setup, play a Spotify track, and confirm the menu bar cue appears when you nod in rhythm with Bop's windows closed.
2. Connect a Spotify account that's new to Bop, create the **Bop!** playlist, and turn on autosave. Bop twice to one track and once to a second track. Verify that both tracks appear once. Relaunch Bop and confirm **Open Playlist** opens the same playlist.
3. Verify paused playback, a Spotify Private Session, demo and recording replays, and AirPods setup practice leave the playlist unchanged.
4. Disconnect Spotify in Bop and verify that Recent Bops and the local playlist link disappear and further bops leave the Spotify playlist unchanged.

## Inspect motion

Open **Motion Graphs** under **Settings → General → Advanced** to inspect four seconds of live data or record up to 20 seconds. Use **Replay** and **Compare** to see how the same recording responds to different axes, sensitivity settings, and rotation detectors. Collect normal movement such as typing or walking as well as intentional bops when tuning thresholds. The onboarding practice beat was synthesized for Bop without external samples. [Detector research](docs/bop-detection-research.md)

## Preview and release

Serve the static site from `docs/` on a free local port. The example uses port 4300.

```sh
python3 -m http.server 4300 --bind 127.0.0.1 --directory docs
```

To preview the download locally, place `Bop-0.1.0-macOS.zip` in `docs/downloads/`. Git ignores the local archive.

GitHub Pages serves `main` from `/docs`. Tag the source used to build the signed and notarized app, then attach the distribution ZIP to that GitHub Release. Verify the landing page downloads the versioned release asset and the privacy notice opens.
