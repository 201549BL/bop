# Developing Bop

Use Xcode with Swift 6. Open `Bop.xcodeproj` and run the **Bop** scheme on **My Mac**. Run `swift test` for detector tests. After changing `project.yml` or adding app source files, regenerate the project with `xcodegen generate`.

## How Spotify support works

Bop talks to the Spotify app for Mac over the Chrome DevTools Protocol on `127.0.0.1:9222`, the same port spotr uses, so both can share one Spotify launch. `SpotifyDesktop` lists the pages at `/json/list`, opens the `xpui` page's WebSocket, and runs `Sources/BopApp/Resources/SpotifyAgent.js` with one `Runtime.evaluate` per request. The script finds Spotify's internal API registry through React and calls methods such as `PlayerAPI.getState` and `PlaylistAPI.add`. These APIs are private and can change with any Spotify update. A missing API or method surfaces as "Spotify changed something Bop relies on."

To use Spotify while developing, quit Spotify and let Bop open it, or start it yourself with `open -a Spotify --args --remote-debugging-port=9222`. The capture rules live in `SpotifyPlayback` in BopCore, which `swift test` covers.

To sign Debug builds with your own certificate, add a local `Config/LocalSigning.xcconfig` with `CODE_SIGN_STYLE = Manual`, your `DEVELOPMENT_TEAM`, and `BOP_DEBUG_CODE_SIGN_IDENTITY` set to your Apple Development certificate fingerprint from `security find-identity -v -p codesigning`. Git ignores this file.

## Verify with AirPods and Spotify

1. Complete AirPods setup, play a Spotify track, and confirm the menu bar cue appears when you nod in rhythm with Bop's windows closed.
2. With Spotify closed, choose **Connect…** and confirm Bop opens Spotify. Quit Spotify, open it normally, and confirm Bop offers **Restart Spotify…** and that Spotify reopens after you confirm. With an account new to Bop, confirm that connecting creates the **Bop!** playlist, that Spotify shows it as private, and that autosave is on. Disconnect and connect again, and confirm Bop finds the same playlist. Bop twice to one track and once to a second track. Verify that both tracks appear once. Relaunch Bop and confirm **Open Playlist** opens the same playlist.
3. Verify paused playback, a Spotify Private Session, demo and recording replays, and AirPods setup practice leave the playlist unchanged.
4. Quit Spotify and bop. Verify the cue says to open Spotify. Relaunch Bop with Spotify closed and confirm it doesn't open Spotify.
5. Disconnect Spotify in Bop and verify that Recent Bops and the local playlist link disappear and further bops leave the Spotify playlist unchanged.

## Inspect motion

Open **Motion Graphs** under **Settings → General → Advanced** to inspect four seconds of live data or record up to 20 seconds. Use **Replay** and **Compare** to see how the same recording responds to different axes, sensitivity settings, and rotation detectors. Collect normal movement such as typing or walking as well as intentional bops when tuning thresholds. The onboarding practice beat was synthesized for Bop without external samples. [Detector research](docs/bop-detection-research.md)

## Preview and release

Serve the static site from `docs/` on a free local port. The example uses port 4300.

```sh
python3 -m http.server 4300 --bind 127.0.0.1 --directory docs
```

To preview the download locally, place `Bop-0.2.0-macOS.zip` in `docs/downloads/`. Git ignores the local archive.

GitHub Pages serves `main` from `/docs`. Tag the source used to build the signed and notarized app, then attach the distribution ZIP to that GitHub Release. Verify the landing page downloads the versioned release asset and the privacy notice opens.
