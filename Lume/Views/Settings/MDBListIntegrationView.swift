//
//  MDBListIntegrationView.swift
//  Lume
//
//  The iOS/macOS MDBList integration screen (the tvOS surface is
//  `TVMDBListIntegrationView`). Drives the OAuth device flow: shows the
//  activation code with a one-tap link to MDBList's device page, polls in the
//  background, and surfaces the connected account with import and disconnect
//  actions.
//

#if !os(tvOS)

    import SwiftData
    import SwiftUI

    struct MDBListIntegrationView: View {
        @State private var mdblist = MDBListService.shared
        /// MDBList sync is a Premium feature.
        @State private var premium = PremiumManager.shared
        @State private var showPaywall = false
        @Environment(\.openURL) private var openURL
        @Environment(\.modelContext) private var modelContext

        var body: some View {
            List {
                if mdblist.isConnected {
                    connectedSection
                } else if let code = mdblist.pendingCode {
                    deviceCodeSection(code)
                } else {
                    connectSection
                }
            }
            .platformNavigationTitle("MDBList")
            .paywall(isPresented: $showPaywall, highlight: .watchSync)
            .onDisappear {
                // Stop polling if the user backs out mid-connect.
                if !mdblist.isConnected {
                    mdblist.cancelConnect()
                }
            }
        }

        // MARK: - Connect

        private var connectSection: some View {
            Section {
                Button {
                    if premium.isPremium {
                        mdblist.connect(into: modelContext)
                    } else {
                        showPaywall = true
                    }
                } label: {
                    Label("Connect MDBList Account", systemImage: premium.isPremium ? "link" : "crown")
                }
                .disabled(mdblist.isConnecting)
            } header: {
                Text("MDBList")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Sync the movies and episodes you watch to MDBList, and surface your MDBList watchlist on Home.")
                    if let error = mdblist.connectionError {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }
            }
        }

        // MARK: - Device code

        private func deviceCodeSection(_ code: MDBListDeviceCode) -> some View {
            Section {
                VStack(spacing: 16) {
                    Text("Enter this code at \(MDBListSyncClient.displayURL(for: code))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Text(code.userCode)
                        .font(.system(size: 40, weight: .bold, design: .monospaced))
                        .tracking(4)
                        .textSelection(.enabled)

                    if let url = MDBListSyncClient.activationURL(for: code) {
                        Button {
                            openURL(url)
                        } label: {
                            Label("Open MDBList", systemImage: "safari")
                        }
                        .buttonStyle(.borderedProminent)

                        QRCodeView(string: url.absoluteString)
                            .frame(width: 160, height: 160)
                            .padding(.top, 4)
                    }

                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Waiting for authorization…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)

                    Button("Cancel", role: .cancel) {
                        mdblist.cancelConnect()
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
        }

        // MARK: - Connected

        private var connectedSection: some View {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Connected")
                        if let username = mdblist.username {
                            Text("@\(username)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }

                Button {
                    Task { await mdblist.importWatched(into: modelContext) }
                } label: {
                    HStack {
                        Label("Import Watched from MDBList", systemImage: "arrow.down.circle")
                        if mdblist.isImporting {
                            Spacer()
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }
                .disabled(mdblist.isImporting)

                Button(role: .destructive) {
                    Task { await mdblist.disconnect() }
                } label: {
                    Label("Disconnect", systemImage: "link.badge.plus")
                }
            } header: {
                Text("MDBList")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Watched movies and episodes sync to your MDBList history. Import marks titles you've already watched on MDBList as watched here.")
                    if let summary = mdblist.lastImport {
                        importStatus(summary)
                    }
                }
            }
        }

        @ViewBuilder
        private func importStatus(_ summary: MDBListImportSummary) -> some View {
            if summary.failed {
                Text("Couldn't import from MDBList. Please try again.")
                    .foregroundStyle(.red)
            } else if summary.markedNothing {
                Text("Your watched history is already up to date.")
                    .foregroundStyle(.green)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Imported \(summary.moviesMarked) movie\(summary.moviesMarked == 1 ? "" : "s") and \(summary.episodesMarked) episode\(summary.episodesMarked == 1 ? "" : "s").")
                    if summary.showsQueued > 0 {
                        Text("\(summary.showsQueued) show\(summary.showsQueued == 1 ? "" : "s") will be marked the first time you open them.")
                    }
                }
                .foregroundStyle(.green)
            }
        }
    }

#endif
