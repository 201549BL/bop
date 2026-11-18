# Bop

Bop is a macOS menu bar app that uses your AirPods to detect when you nod to music and can save those songs to a Spotify playlist.

[Download for Mac](https://github.com/201549BL/bop/releases/download/v0.1.0/Bop-0.1.0-macOS.zip) · [Homepage and demo](https://201549bl.github.io/bop/)

Requires macOS 14 or later and AirPods with motion support.

## Get started

1. Unzip the download and move **Bop.app** to **Applications**.
2. Open Bop, follow the AirPods setup, and allow motion access when macOS asks.
3. Use **BOP!** in the menu bar to start or pause listening.

For optional song saving, connect your Spotify Premium account in **Settings → Music**, choose **Create playlist**, and turn on **Autosave to playlist**. New playlists are named **Bop!**.

AirPods motion is processed on your Mac. [Privacy notice](https://201549bl.github.io/bop/privacy.html)

## Build from source

Open `Bop.xcodeproj` in Xcode, select the **Bop** scheme and **My Mac**, then run. Use `swift test` to test the detector. [Development guide](DEVELOPMENT.md)

[MIT License](LICENSE)
