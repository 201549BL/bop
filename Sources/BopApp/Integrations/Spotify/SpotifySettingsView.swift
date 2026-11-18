import SwiftUI

struct SpotifySettingsView: View {
    let spotify: SpotifyIntegration

    @State private var showsDetails = false
    @State private var confirmsDisconnect = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            BopSettingsGroup {
                providerRow
                if spotify.isConnected && showsDetails {
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
            Text("Bop stops saving songs and clears the sign-in, recent bops, and saved playlist details from this Mac. Your playlist stays in Spotify.")
        }
        .onChange(of: spotify.isConnected, initial: true) { _, connected in
            showsDetails = connected && spotify.playlistURL == nil
        }
        .onChange(of: spotify.playlistURL) { previousURL, playlistURL in
            if previousURL != nil && playlistURL == nil && spotify.isConnected { showsDetails = true }
        }
        .onDisappear {
            spotify.cancelSignIn()
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
                if spotify.needsKeychainCleanup {
                    Button("Finish Disconnecting") { spotify.disconnect() }
                        .accessibilityLabel("Finish disconnecting Spotify")
                } else if spotify.isConnecting {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityHidden(true)
                        Button("Cancel") { spotify.cancelSignIn() }
                            .accessibilityLabel("Cancel Spotify sign-in")
                            .keyboardShortcut(.cancelAction)
                    }
                } else if SpotifyPlayerConnection.isAvailable {
                    Button("Connect…") { spotify.connect() }
                        .buttonStyle(.borderedProminent)
                        .accessibilityLabel("Connect Spotify")
                        .keyboardShortcut(.defaultAction)
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
        if spotify.needsKeychainCleanup { return "Disconnect needs attention" }
        if spotify.isConnecting { return "Waiting for browser approval" }
        if spotify.isConnected {
            if spotify.isCreatingPlaylist && !showsDetails { return "Connected · Creating playlist…" }
            if spotify.playlistURL == nil { return "Connected" }
            return spotify.autosave ? "Connected · Autosave on" : "Connected · Saving paused"
        }
        if !SpotifyPlayerConnection.isAvailable { return "Unavailable in this build" }
        return "Not connected"
    }

    private var connectionNote: String? {
        if spotify.isConnecting {
            return "Complete both approvals in your browser using the same Spotify Premium account."
        }
        if !spotify.isConnected && !spotify.needsKeychainCleanup && SpotifyPlayerConnection.isAvailable {
            return "Connect with Spotify Premium to start saving songs. Anyone with the playlist link can open it."
        }
        return nil
    }

    private func playlistLink(_ url: URL) -> some View {
        Link(destination: url) {
            let arrow = Text(Image(systemName: "arrow.up.right"))
                .font(.caption2.weight(.semibold))
            Text("playlist \(arrow)")
                .foregroundStyle(Color(nsColor: .linkColor))
        }
        .accessibilityLabel("Open Bop playlist in Spotify")
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
        } else {
            BopSettingsRow {
                BopSettingsLabel("Bop playlist")
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
