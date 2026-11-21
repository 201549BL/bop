# Bop

Bop is a macOS menu bar app that uses your AirPods to detect when you nod to music and can save those songs to a Spotify playlist.

[Download for Mac](https://github.com/201549BL/bop/releases/download/v0.2.0/Bop-0.2.0-macOS.zip) · [Homepage and demo](https://201549bl.github.io/bop/)

Requires macOS 14 or later and AirPods with motion support. Song saving also needs the Spotify app for Mac.

## Get started

1. Unzip the download and move **Bop.app** to **Applications**.
2. Open Bop, follow the AirPods setup, and allow motion access when macOS asks.
3. Use **BOP!** in the menu bar to start or pause listening.

For optional song saving, sign in to the Spotify app, choose **Connect…** under Spotify in Bop's settings. Bop finds the playlist it made before, or creates one, and starts saving songs. You can pause saving with **Autosave to playlist**. New playlists are named **Bop!** and start out private. You can share them in Spotify later. Bop opens Spotify with a local connection it uses to read what's playing. If Spotify is already open without it, Bop offers to restart Spotify, which stops your music briefly.

AirPods motion is processed on your Mac. [Privacy notice](https://201549bl.github.io/bop/privacy.html)

## Build from source

Open `Bop.xcodeproj` in Xcode, select the **Bop** scheme and **My Mac**, then run. Use `swift test` to test the detector. [Development guide](DEVELOPMENT.md)

[MIT License](LICENSE)
