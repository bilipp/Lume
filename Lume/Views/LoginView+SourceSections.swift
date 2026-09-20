//
//  LoginView+SourceSections.swift
//  Lume
//
//  The iOS/macOS source sections of the add-playlist form, split out of
//  LoginView to keep that type within the project's body-length limit. They
//  take what they render as bindings — like `MediaServerLoginSection` — so the
//  form state stays in `LoginView`.
//
//  The tvOS form has no `Section` chrome and builds its fields inline in
//  `LoginView`, so it stays there.
//

import SwiftUI

#if !os(tvOS)
    /// The Xtream fields of the add-playlist form.
    struct XtreamLoginSection: View {
        @Binding var name: String
        @Binding var serverURL: String
        @Binding var username: String
        @Binding var password: String

        var body: some View {
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
    }

    /// The m3u fields of the add-playlist form, plus the Xtream-login hint
    /// shown when the URL is really an Xtream `get.php` endpoint.
    struct M3ULoginSection: View {
        @Binding var name: String
        @Binding var m3uURL: String
        @Binding var epgURL: String
        @Binding var showFileImporter: Bool
        var xtreamHint: XtreamCredentialsHint?
        var isLoading: Bool
        var onAddAsXtream: (XtreamCredentialsHint) -> Void

        var body: some View {
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

            if let xtreamHint {
                Section {
                    XtreamLoginHint(isLoading: isLoading) { onAddAsXtream(xtreamHint) }
                }
            }
        }
    }

    /// The Stalker portal fields of the add-playlist form.
    struct StalkerLoginSection: View {
        @Binding var name: String
        @Binding var portalURL: String
        @Binding var macAddress: String
        @Binding var username: String
        @Binding var password: String

        var body: some View {
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
    }
#endif
