//
//  DebugSettingsView.swift
//  Lume
//
//  End-user diagnostics: describe the problem, then email or share a report
//  built by `DebugLogExporter` from the always-on `DiagnosticJournal`. Nothing
//  has to be switched on beforehand — the journal already holds the history —
//  so the screen works right after a failure, including from the add-playlist
//  form on first launch, where Settings isn't reachable yet (`DiagnosticsSheet`).
//
//  "Detailed Logging" only adds the verbose debug-level lines; the report is
//  useful without it.
//
//  iOS gets a native Mail composer (falling back to the share sheet when Mail
//  isn't set up); macOS uses ShareLink plus a mailto link. Apple TV can neither
//  attach a file nor compose mail — it has its own screen, `TVDiagnosticsView`.
//

import OSLog
import SwiftData
import SwiftUI
#if os(iOS)
    import MessageUI
#endif

// MARK: - Report assembly

/// Builds the exporter with everything the report needs from the environment.
/// Shared by every diagnostics surface so they all send the same report.
@MainActor
enum DiagnosticsReport {
    static func exporter(
        container: ModelContainer?,
        cloudSync: CloudSyncCoordinator?,
        origin: String?,
        visibleProblem: String?,
        userNote: String? = nil
    ) -> DebugLogExporter {
        let metadata = DebugLogExporter.currentMetadata(
            cloudSync: cloudSync,
            origin: origin,
            visibleProblem: visibleProblem,
            userNote: userNote
        )
        return DebugLogExporter(metadata: metadata, container: container)
    }

    /// The `mailto:` a phone opens from the Apple TV QR code: support address,
    /// subject, and the compact summary as the body.
    nonisolated static func mailtoLink(summary: String, appVersion: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#")
        let subject = "Lume Diagnostics — \(appVersion)"
        let encodedSubject = subject.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        let encodedBody = summary.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return "mailto:\(SupportInfo.email)?subject=\(encodedSubject)&body=\(encodedBody)"
    }
}

#if !os(tvOS)

    // MARK: - Standalone sheet

    /// The diagnostics screen on its own, for places that can't reach Settings —
    /// the add-playlist form before any playlist exists.
    struct DiagnosticsSheet: View {
        var origin: String?
        var visibleProblem: String?
        @Environment(\.dismiss) private var dismiss

        var body: some View {
            NavigationStack {
                DebugSettingsView(origin: origin, visibleProblem: visibleProblem)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { dismiss() }
                        }
                    }
            }
            #if os(macOS)
            .frame(minWidth: 460, idealWidth: 520, minHeight: 520, idealHeight: 620)
            #endif
        }
    }

    // MARK: - iOS / macOS screen

    struct DebugSettingsView: View {
        var origin: String?
        var visibleProblem: String?

        @Environment(\.modelContext) private var modelContext
        @Environment(CloudSyncCoordinator.self) private var cloudSync: CloudSyncCoordinator?
        @AppStorage(DebugLogSettings.enabledKey) private var detailedLogging = false
        @State private var note = ""
        @State private var isPreparing = false
        @State private var errorMessage: String?
        @State private var shareItem: ExportedLog?
        @State private var confirmClear = false
        #if os(iOS)
            @State private var mailItem: ExportedLog?
        #elseif os(macOS)
            @State private var preparedURL: URL?
        #endif

        var body: some View {
            List {
                if let visibleProblem, !visibleProblem.isEmpty {
                    Section("Problem") {
                        Label(visibleProblem, systemImage: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                            .font(.callout)
                    }
                }

                Section {
                    TextField("What were you doing when it went wrong?", text: $note, axis: .vertical)
                        .lineLimit(3 ... 6)
                } header: {
                    Text("Description (optional)")
                } footer: {
                    Text("A sentence or two helps a lot. It's added to the top of the report.")
                }

                submitSection

                Section {
                    NavigationLink {
                        DebugLogViewerView(makeExporter: makeExporter)
                    } label: {
                        Label("View Report", systemImage: "doc.text.magnifyingglass")
                    }
                } footer: {
                    // swiftlint:disable:next line_length
                    Text("See exactly what will be sent. The report lists your device, app settings, playlist types and sync state, and recent app activity — never playlist names, server addresses, usernames or passwords.")
                }

                Section {
                    Toggle("Detailed Logging", isOn: $detailedLogging)
                        .onChange(of: detailedLogging) { _, isOn in
                            if isOn { DebugLogSettings.markEnabled(at: Date()) }
                        }
                } footer: {
                    Text("Diagnostics are always recorded on this device. Detailed logging adds verbose entries — turn it on only when asked to, reproduce the problem, then send the report.")
                }

                Section {
                    Button("Clear Diagnostic Data", role: .destructive) {
                        confirmClear = true
                    }
                } footer: {
                    Text("The diagnostic log stays on your device until you send it, and removes its oldest entries on its own.")
                }
            }
            .platformNavigationTitle("Diagnostics")
            .alert("Couldn't Prepare the Report", isPresented: errorAlertBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .confirmationDialog("Clear the diagnostic log?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear", role: .destructive) {
                    DiagnosticJournal.shared.clear()
                    #if os(macOS)
                        preparedURL = nil
                    #endif
                }
            }
            #if os(iOS)
            .sheet(item: $mailItem) { item in
                MailComposeView(
                    recipient: SupportInfo.email,
                    subject: String(localized: "Lume Diagnostics — \(SupportInfo.appVersion)"),
                    body: mailBody,
                    attachmentURL: item.url
                )
                .ignoresSafeArea()
            }
            #endif
            .sheet(item: $shareItem) { item in
                shareSheet(for: item.url)
            }
        }

        private var mailBody: String {
            let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
            let intro = trimmed.isEmpty ? String(localized: "Describe the problem here.") : trimmed
            return intro + "\n\n" + String(localized: "The diagnostic report is attached.") + "\n"
        }

        private var submitSection: some View {
            Section {
                #if os(iOS)
                    Button {
                        Task { await prepareThenEmail() }
                    } label: {
                        actionLabel("Email Report to Developer", systemImage: "envelope")
                    }
                    .disabled(isPreparing)

                    Button {
                        Task { await prepare { shareItem = $0 } }
                    } label: {
                        actionLabel("Share Report…", systemImage: "square.and.arrow.up")
                    }
                    .disabled(isPreparing)
                #elseif os(macOS)
                    if let preparedURL {
                        ShareLink(item: preparedURL) {
                            Label("Share Report…", systemImage: "square.and.arrow.up")
                        }
                    }
                    Button {
                        Task { await prepare { preparedURL = $0.url } }
                    } label: {
                        actionLabel(preparedURL == nil ? "Prepare Report" : "Refresh Report", systemImage: "arrow.clockwise")
                    }
                    .disabled(isPreparing)

                    if let url = SupportInfo.emailURL {
                        Link(destination: url) {
                            Label("Email the Developer", systemImage: "envelope")
                        }
                    }
                #endif
            } header: {
                Text("Send")
            } footer: {
                #if os(macOS)
                    Text("Prepare the report, then share it or attach it to an email to \(SupportInfo.email).")
                #else
                    Text("Reports go to \(SupportInfo.email).")
                #endif
            }
        }

        private func actionLabel(_ title: LocalizedStringKey, systemImage: String) -> some View {
            HStack {
                Label(title, systemImage: systemImage)
                if isPreparing {
                    Spacer()
                    ProgressView()
                }
            }
        }

        private var errorAlertBinding: Binding<Bool> {
            Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        }

        // MARK: Preparation

        private func makeExporter() -> DebugLogExporter {
            DiagnosticsReport.exporter(
                container: modelContext.container,
                cloudSync: cloudSync,
                origin: origin,
                visibleProblem: visibleProblem,
                userNote: note
            )
        }

        /// Writes the report off the main actor, then hands the URL to `assign`.
        private func prepare(_ assign: (ExportedLog) -> Void) async {
            isPreparing = true
            defer { isPreparing = false }
            let exporter = makeExporter()
            Logger.app.notice("Diagnostic report prepared (from \(origin ?? "Settings"))")
            do {
                let url = try await exporter.writeReport()
                assign(ExportedLog(url: url))
            } catch {
                errorMessage = error.localizedDescription
            }
        }

        #if os(iOS)
            private func prepareThenEmail() async {
                guard MFMailComposeViewController.canSendMail() else {
                    // No Mail account — fall back to the share sheet.
                    await prepare { shareItem = $0 }
                    return
                }
                await prepare { mailItem = $0 }
            }
        #endif

        @ViewBuilder
        private func shareSheet(for url: URL) -> some View {
            #if os(iOS)
                ActivityView(items: [url]).ignoresSafeArea()
            #else
                EmptyView()
            #endif
        }
    }

    // MARK: - Report viewer

    /// A read-only, monospaced preview of the report the user is about to send,
    /// so they can see exactly what leaves the device.
    struct DebugLogViewerView: View {
        let makeExporter: () -> DebugLogExporter
        @State private var text = ""
        @State private var isLoading = true

        var body: some View {
            ScrollView {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                } else {
                    Text(text)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            }
            .platformNavigationTitle("Report")
            .task {
                let exporter = makeExporter()
                text = await exporter.makeReport()
                isLoading = false
            }
        }
    }

    /// The exported file, wrapped so it can drive a `.sheet(item:)`.
    struct ExportedLog: Identifiable {
        let id = UUID()
        let url: URL
    }

#endif

// MARK: - iOS system-UI wrappers

#if os(iOS)

    /// Presents the system Mail composer pre-filled with the support address and
    /// the diagnostic report attached.
    struct MailComposeView: UIViewControllerRepresentable {
        let recipient: String
        let subject: String
        let body: String
        let attachmentURL: URL
        @Environment(\.dismiss) private var dismiss

        func makeUIViewController(context: Context) -> MFMailComposeViewController {
            let controller = MFMailComposeViewController()
            controller.mailComposeDelegate = context.coordinator
            controller.setToRecipients([recipient])
            controller.setSubject(subject)
            controller.setMessageBody(body, isHTML: false)
            if let data = try? Data(contentsOf: attachmentURL) {
                controller.addAttachmentData(data, mimeType: "text/plain", fileName: attachmentURL.lastPathComponent)
            }
            return controller
        }

        func updateUIViewController(_: MFMailComposeViewController, context _: Context) {}

        func makeCoordinator() -> Coordinator {
            Coordinator(dismiss: dismiss)
        }

        final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
            private let dismiss: DismissAction

            init(dismiss: DismissAction) {
                self.dismiss = dismiss
            }

            func mailComposeController(
                _: MFMailComposeViewController,
                didFinishWith _: MFMailComposeResult,
                error _: Error?
            ) {
                dismiss()
            }
        }
    }

    /// Thin wrapper over `UIActivityViewController` for the share-sheet fallback.
    struct ActivityView: UIViewControllerRepresentable {
        let items: [Any]

        func makeUIViewController(context _: Context) -> UIActivityViewController {
            UIActivityViewController(activityItems: items, applicationActivities: nil)
        }

        func updateUIViewController(_: UIActivityViewController, context _: Context) {}
    }

#endif
