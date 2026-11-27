import SwiftUI
#if !os(tvOS)
    import UniformTypeIdentifiers

    struct StalkerProfileImportButton: View {
        var onReview: (StalkerPrivateProfile) -> Void
        @State private var choosing = false
        @State private var reviewing = false
        @State private var failed = false
        @State private var staged: StalkerPrivateProfile?
        @State private var reveal = false

        var body: some View {
            Button("Import private Stalker profile…") { choosing = true }
                .fileImporter(isPresented: $choosing, allowedContentTypes: [.json]) { result in
                    do {
                        let url = try result.get()
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        let handle = try FileHandle(forReadingFrom: url)
                        defer { try? handle.close() }
                        let data = try handle.read(upToCount: 65537) ?? Data()
                        staged = try StalkerPrivateProfile.decode(data)
                        reveal = false
                        reviewing = true
                    } catch {
                        staged = nil
                        failed = true
                    }
                }
                .alert("Profile import failed", isPresented: $failed) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text("Choose one valid household JSON profile. Conflicting aliases, unknown fields and unsupported versions are rejected.")
                }
                .sheet(isPresented: $reviewing, onDismiss: { staged = nil }, content: {
                    if let staged { review(staged) }
                })
        }

        private func review(_ profile: StalkerPrivateProfile) -> some View {
            NavigationStack {
                Form {
                    Section {
                        LabeledContent("Name", value: profile.displayName)
                        LabeledContent("Portal URL", value: reveal ? profile.portalURL : "••••••••")
                        LabeledContent("MAC Address", value: reveal ? profile.mac : "••••••••")
                        reviewValue("Existing protocol serial number", value: profile.identity.serialNumber)
                        reviewValue("Existing device ID 1", value: profile.identity.deviceId1)
                        reviewValue("Existing device ID 2", value: profile.identity.deviceId2)
                        reviewValue("Existing signature 1", value: profile.identity.signature1)
                        reviewValue("Existing signature 2", value: profile.identity.signature2)
                        Toggle("Reveal private values", isOn: $reveal)
                    } footer: {
                        Text("""
                        Review before applying. This replaces the form's account fields, never merges accounts, \
                        and makes no network request. Save separately to authenticate. Advanced values remain device-local.
                        """)
                    }
                    Button("Use reviewed profile") {
                        onReview(profile)
                        reviewing = false
                    }
                }
                .privacySensitive()
                .navigationTitle("Review private profile")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { reviewing = false }
                    }
                }
            }
        }

        private func reviewValue(_ title: LocalizedStringKey, value: String?) -> some View {
            LabeledContent(title) {
                if let value {
                    if value.isEmpty {
                        Text("Explicitly empty")
                    } else {
                        Text(reveal ? value : "••••••••")
                    }
                } else {
                    Text("Omitted")
                }
            }
        }
    }
#endif
