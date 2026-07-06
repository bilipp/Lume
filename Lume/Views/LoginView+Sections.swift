//
//  LoginView+Sections.swift
//  Lume
//
//  The per-source form sections of the iOS/macOS add-playlist form, one per
//  `PlaylistSourceType`. Split out of LoginView.swift to keep that file within
//  the lint size caps.
//

import SwiftUI

#if !os(tvOS)
    extension LoginView {
        var xtreamSection: some View {
            Section {
                TextField("e.g. My IPTV", text: $name)
                    .textContentType(.name)

                TextField("e.g. http://example.com:8080", text: $serverURL)
                #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                #endif
                    .autocorrectionDisabled()
                    .textContentType(.URL)

                TextField("Username", text: $username)
                #if os(iOS)
                    .textInputAutocapitalization(.never)
                #endif
                    .autocorrectionDisabled()
                    .textContentType(.username)

                SecureField("Password", text: $password)
                    .textContentType(.password)
            } header: {
                Text("Server Connection")
            } footer: {
                Text("Your credentials are stored locally on this device.")
            }
        }

        var m3uSection: some View {
            Section {
                TextField("e.g. My IPTV", text: $name)
                    .textContentType(.name)

                TextField("e.g. http://example.com/playlist.m3u", text: $m3uURL)
                #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                #endif
                    .autocorrectionDisabled()
                    .textContentType(.URL)

                Button("Choose Local File…") { showFileImporter = true }

                TextField("EPG URL (optional)", text: $epgURL)
                #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                #endif
                    .autocorrectionDisabled()
                    .textContentType(.URL)
            } header: {
                Text("M3U Playlist")
            } footer: {
                Text("Enter the playlist URL or choose a local m3u/m3u8 file. The EPG URL is read from the playlist when left empty.")
            }
        }

        var stalkerSection: some View {
            Section {
                TextField("e.g. My IPTV", text: $name)
                    .textContentType(.name)

                TextField("e.g. http://example.com:8080/c/", text: $portalURL)
                #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                #endif
                    .autocorrectionDisabled()
                    .textContentType(.URL)

                HStack {
                    TextField("MAC Address", text: $macAddress)
                    #if os(iOS)
                        .textInputAutocapitalization(.characters)
                    #endif
                        .autocorrectionDisabled()
                    Button {
                        macAddress = StalkerMAC.generate()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Generate a new MAC address")
                }

                TextField("Username (optional)", text: $username)
                #if os(iOS)
                    .textInputAutocapitalization(.never)
                #endif
                    .autocorrectionDisabled()
                    .textContentType(.username)

                SecureField("Password (optional)", text: $password)
                    .textContentType(.password)
            } header: {
                Text("Stalker Portal")
            } footer: {
                Text("Enter the portal URL and the MAC address your provider authorized. Most portals need only the portal URL and MAC.")
            }
        }

        var stremioSection: some View {
            Section {
                TextField("e.g. My Addon", text: $name)
                    .textContentType(.name)

                TextField("e.g. https://v3-cinemeta.strem.io/manifest.json", text: $stremioURL)
                #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                #endif
                    .autocorrectionDisabled()
                    .textContentType(.URL)
            } header: {
                Text("Stremio Addon")
            } footer: {
                Text("Enter the addon's manifest URL or a stremio:// install link. The addon's catalogs appear alongside your other playlists; the name is taken from the addon when left empty.")
            }
        }
    }
#endif
