# Bop

Bop is a macOS menu bar app that detects rhythmic head motion using compatible AirPods. It can save songs you bop to in a Spotify playlist.

Download `Bop-0.1.0-macOS.zip`, unzip it, and drag **Bop.app** into **Applications**. Bop runs on macOS 14 or later. [GitHub Releases](https://github.com/201549BL/bop/releases)

To build from source, open `Bop.xcodeproj` in Xcode, select the **Bop** scheme and **My Mac**, then run.

On first launch, choose **Get Started**, put on your AirPods, and click **Connect AirPods**. Allow motion access if macOS asks. The tutorial shows you how to bop, then you can practice with the bobblehead and a beat or skip to the menu bar preview. Choose **Open Settings** to finish setup and keep listening. You can choose **Set Up Later** from either of the first two screens. Setup follows the macOS appearance. The practice beat was synthesized for Bop without external samples.

Use **BOP!** in the macOS menu bar to start or pause listening. Open **Recent Bops** to revisit up to five songs captured with Spotify autosave and see the last bop result. A green dot shows when Bop is listening. When Bop detects a bop, the wordmark jumps and a brief cue shows the detection. When autosave is on, the cue opens with the Spotify logo and shows the track title and artist as soon as they’re available. It also shows the save result if it arrives while the cue is visible. With Reduce Motion enabled, the wordmark uses an underline. Bop keeps listening when you close its windows or switch apps. Open **Settings… → General** to repeat AirPods setup, adjust **Bop sensitivity**, or turn off the cue. Higher sensitivity detects smaller head movements.

Open **Motion Graphs** under **Settings… → General → Advanced** to see the latest four seconds of rotation, orientation, and vertical acceleration. Each graph marks cycles and bops and keeps its own count. The default rotation detector looks for a nod that moves away and returns, then checks whether another nod forms a rhythm. Orientation and vertical acceleration use three cycles at roughly even intervals.

- **Play Demo** replays simulated motion through the same detector used for live samples.
- **Listen to AirPods** starts a live session. Wear your connected AirPods and allow motion access if macOS asks.
- The **Detector** picker switches between the nod-first detector and **Autocorrelation** for the rotation graph and live feedback.
- **Sensitivity** is adjustable per graph while listening or stopped. Each detector defaults to **1×**. The rotation slider shares the **Bop sensitivity** setting in General.
- The **Vertical acceleration** graph shows the current stroke start and end thresholds in g. The dashed outer lines mark where a stroke can start, and the dotted inner lines mark where it can end. A cycle needs two sustained strokes in opposite directions.
- **Record** captures up to 20 seconds of rotation, orientation, acceleration, and gravity in memory. Stop listening, then select **Replay** to run the clip through the detectors.
- To test a sensitivity setting on the same motion, move the slider and select **Replay** again. **Compare** shows when both rotation detectors fired on the same replay or demo. It also shows the orientation, vertical acceleration, and combined results. **Combined** accepts detections from a single signal, including acceleration alone. It can also pick up weaker acceleration and head rotation that repeat at a shared rhythm.
- **Rotation axis** defaults to **Auto**. The graph shows separate signed **X**, **Y**, and **Z** traces on a shared scale, and Auto detection uses all three axes together. While stopped, choose an axis to show and detect motion on that axis. Recordings keep all three axes so you can replay the same clip with different settings.

For a quick comparison, capture separate clips of subtle tilts, small bounces, and normal motion such as typing or walking. Detections in the normal-motion clip help show which settings pick up movement you didn't intend as a bop.

## Save bops to Spotify

Choose **Set Up Music…** from the Bop menu to open **Settings… → Music**, then choose **Connect…** next to Spotify under **Integrations**. Complete Spotify’s approvals in your browser with the same Spotify Premium account. If you used an earlier Bop preview, connect again to approve the regular player’s permissions.

Open Spotify’s details and choose **Create playlist** to set up your **Bop** playlist. Once it’s ready, turn on **Autosave to playlist** to save songs when you bop. Choose **Open Bop Playlist** from the menu bar to view it in Spotify. Bop keeps using the same playlist after you reopen the app.

Bop asks Spotify to keep the playlist off your profile and out of search. Anyone with the link can still open it unless you make it private in Spotify. Bop saves each song once per playlist and checks the connected account’s active playback after a new live bop. Playback could be on another device. [Privacy notice](https://201549bl.github.io/bop/privacy.html)

To build with Spotify support, install Rust and Cargo, then run `bash Tools/SpotifyPlayer/build.sh --native` followed by `xcodebuild -scheme Bop build BOP_BUNDLE_SPOTIFY_PLAYER=YES`. For a universal build, install the Rust targets `aarch64-apple-darwin` and `x86_64-apple-darwin` and use `--stage`. Bop builds spotify-player v0.25.2 with the [upstream ncspot callback fix](https://github.com/aome510/spotify-player/pull/1115) and omits integrated audio streaming. The preview uses upstream’s shared Spotify client ID and shares its rate limits.

To keep Keychain approval across Debug rebuilds, use the same Apple Development signing certificate. Set `CODE_SIGN_STYLE = Manual`, `DEVELOPMENT_TEAM` to your team ID, and `BOP_DEBUG_CODE_SIGN_IDENTITY` to the certificate fingerprint from `security find-identity -v -p codesigning` in `Config/LocalSigning.xcconfig`. Git ignores this optional file. After switching from ad hoc signing, macOS may ask you to approve Bop’s Spotify Keychain item once.

### Verify with AirPods and Spotify

1. Connect an account without a **Bop** playlist. Choose **Create playlist**, turn on **Autosave to playlist**, and play a Spotify song. Close the Bop windows and nod until the menu bar cue appears. Check that the playlist contains the song and is absent from your public profile.
2. Pause your nodding, then bop to the same song again and confirm it appears once. Play a second song, bop again, and check that the same playlist now contains both songs. Relaunch Bop, choose **Start Listening**, and repeat with a third song to check that it still uses the same playlist.
3. Pause Spotify and confirm a new bop leaves the playlist unchanged. Resume playback in a Spotify Private Session and repeat. Then turn off Private Session and try a demo, a recording replay, and AirPods setup practice. Confirm those leave the playlist unchanged too.
4. Disconnect Spotify in Bop. Check that Recent Bops and the playlist link disappear locally. Confirm a live bop leaves the Spotify playlist unchanged.

`Sources/BopCore` contains the detector and motion types. `Sources/BopApp` contains the Core Motion adapter, session state, and app interface. The Spotify integration lives in `Sources/BopApp/Integrations/Spotify`, and its bundled helper lives in `Tools/SpotifyPlayer`. Run the automated Swift tests with `swift test`. Regenerate the checked-in Xcode project with `xcodegen generate`.

## Landing page

The static site lives in `docs/`. To preview it locally, run this from the repository root and open [localhost:4300](http://127.0.0.1:4300/). To test the download locally, copy `Bop-0.1.0-macOS.zip` into `docs/downloads/`. Git ignores the local copy.

```sh
python3 -m http.server 4300 --bind 127.0.0.1 --directory docs
```

In the GitHub repository, open **Settings → Pages**, choose **Deploy from a branch**, and select **`main`** and **`/docs`**. [GitHub Pages setup](https://docs.github.com/en/pages/getting-started-with-github-pages/configuring-a-publishing-source-for-your-github-pages-site)

## First release

Tag the source used for the signed, notarized build as `v0.1.0`. Attach `Bop-0.1.0-macOS.zip` to that GitHub Release. Open the published Pages site and verify that **Download for Mac** serves the release asset and **Privacy** opens the notice.
