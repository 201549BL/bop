import SwiftUI

struct SpotifySettingsView: View {
    let spotify: SpotifyIntegration

    @State private var showsDetails = false
    @State private var confirmsDisconnect = false
    @State private var confirmsRestart = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            BopSettingsGroup {
                providerRow
                if spotify.isEnabled && (showsDetails || !spotify.isConnected) {
                    Divider()
                    details
                }
            }

            if let connectionNote {
                footnote(connectionNote)
            }

            if let status = spotify.status {
                footnote(status)
            }
        }
        .alert("Disconnect Spotify?", isPresented: $confirmsDisconnect) {
            Button("Cancel", role: .cancel) {}
            Button("Disconnect", role: .destructive) { spotify.disconnect() }
        } message: {
            Text("Bop stops saving songs and clears your recent bops and saved playlist details from this Mac. Your playlist stays in Spotify.")
        }
        .alert("Restart Spotify?", isPresented: $confirmsRestart) {
            Button("Cancel", role: .cancel) {}
            Button("Restart") { spotify.restartSpotify() }
        } message: {
            Text("Spotify quits and opens again, so your music stops briefly.")
        }
        .onChange(of: spotify.isConnected, initial: true) { _, connected in
            showsDetails = connected && spotify.playlistURL == nil
        }
        .onChange(of: spotify.playlistURL) { previousURL, playlistURL in
            if previousURL != nil && playlistURL == nil && spotify.isConnected { showsDetails = true }
        }
    }

    @ViewBuilder private var providerRow: some View {
        if spotify.isConnected {
            Button {
                showsDetails.toggle()
            } label: {
                BopSettingsRow {
                    providerLabel
                } control: {
                    HStack(spacing: 6) {
                        Text("Details")
                        Image(systemName: showsDetails ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Spotify details, \(connectionStatus)"))
            .accessibilityValue(showsDetails ? "Expanded" : "Collapsed")
            .help(showsDetails ? "Hide Spotify details" : "Show Spotify details")
        } else {
            BopSettingsRow {
                providerLabel
            } control: {
                switch spotify.connection {
                case .off:
                    Button("Connect…") { spotify.connect() }
                        .buttonStyle(.borderedProminent)
                        .accessibilityLabel("Connect Spotify")
                        .keyboardShortcut(.defaultAction)
                case .connecting:
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Connecting to Spotify")
                case .spotifyNotRunning:
                    Button("Open Spotify") { spotify.connect() }
                case .needsRestart:
                    Button("Restart Spotify…") { confirmsRestart = true }
                        .buttonStyle(.borderedProminent)
                case .failed:
                    Button("Try Again") { spotify.connect() }
                case .connected:
                    EmptyView()
                }
            }
        }
    }

    private var providerLabel: some View {
        HStack(spacing: 12) {
            Image("SpotifyIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 24, height: 24)
                .frame(width: 40, height: 40)
                .background(.black, in: .rect(cornerRadius: 9))
                .accessibilityHidden(true)

            BopSettingsLabel("Spotify", detail: connectionStatus)
        }
    }

    private var connectionStatus: String {
        switch spotify.connection {
        case .off: "Not connected"
        case .connecting: "Connecting…"
        case .spotifyNotRunning: "Spotify isn’t open"
        case .needsRestart: "Spotify needs a restart"
        case .failed: "Couldn’t connect"
        case .connected:
            if spotify.isCreatingPlaylist && !showsDetails { "Connected · Creating playlist…" }
            else if spotify.playlistURL == nil { "Connected" }
            else { spotify.autosave ? "Connected · Autosave on" : "Connected · Saving paused" }
        }
    }

    private var connectionNote: String? {
        switch spotify.connection {
        case .off:
            "Bop works with the Spotify app on this Mac and saves the songs you bop to in a private playlist."
        case .spotifyNotRunning:
            "Bop saves songs while Spotify is open."
        case .needsRestart:
            "Spotify is open without the local connection Bop uses. Restart it from here so Bop can save songs."
        case .failed(let message):
            message
        case .connecting, .connected:
            nil
        }
    }

    private func playlistLink(_ url: URL) -> some View {
        Link(destination: url) {
            let arrow = Text(Image(systemName: "arrow.up.right"))
                .font(.caption2.weight(.semibold))
            Text("playlist \(arrow)")
                .foregroundStyle(Color(nsColor: .linkColor))
        }
        .accessibilityLabel("Open playlist in Spotify")
    }

    @ViewBuilder private var details: some View {
        if let playlistURL = spotify.playlistURL {
            BopSettingsRow {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("Autosave to")
                        .accessibilityHidden(true)
                    playlistLink(playlistURL)
                }
                .fontWeight(.medium)
            } control: {
                Toggle("Autosave to playlist", isOn: Binding(
                    get: { spotify.autosave },
                    set: { spotify.setAutosave($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }
        } else if spotify.isConnected {
            BopSettingsRow {
                BopSettingsLabel("Bop! playlist")
            } control: {
                if spotify.isCreatingPlaylist {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityHidden(true)
                        Text("Creating playlist…")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Button("Create playlist", action: spotify.createPlaylist)
                        .buttonStyle(.borderedProminent)
                }
            }
        }

        Button("Disconnect Spotify…") { confirmsDisconnect = true }
            .buttonStyle(.bordered)
            .padding(.horizontal, 11)
            .padding(.top, 4)
            .padding(.bottom, 12)
    }

    private func footnote(_ content: String) -> some View {
        Text(content)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
