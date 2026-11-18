import AVFoundation
import SwiftUI

struct PracticeBeatButton: View {
    @State private var player: AVAudioPlayer?
    @State private var isPlaying = false
    @State private var isUnavailable = false

    var body: some View {
        Button(action: toggleBeat) {
            Label(
                isUnavailable ? "Beat unavailable" : isPlaying ? "Pause beat" : "Play beat",
                systemImage: isPlaying ? "pause.fill" : "play.fill"
            )
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(isUnavailable)
        .onDisappear {
            player?.stop()
            player = nil
            isPlaying = false
        }
    }

    private func toggleBeat() {
        if isPlaying {
            player?.pause()
            isPlaying = false
            return
        }

        if player == nil {
            guard let url = Bundle.main.url(forResource: "PracticeBeat", withExtension: "mp3"),
                  let newPlayer = try? AVAudioPlayer(contentsOf: url) else {
                isUnavailable = true
                return
            }

            newPlayer.numberOfLoops = -1
            player = newPlayer
        }

        isPlaying = player?.play() == true
        isUnavailable = !isPlaying
    }
}
