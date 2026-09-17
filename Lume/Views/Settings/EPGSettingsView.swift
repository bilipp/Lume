//
//  EPGSettingsView.swift
//  Lume
//
//  Manages standalone EPG (TV guide) sources: add/remove custom XMLTV feeds,
//  set how often the guide refreshes, and trigger a manual refresh. Sources
//  created automatically for a playlist are listed here too — they can be
//  enabled/disabled but not edited or deleted (they're managed by the playlist).
//

import SwiftData
import SwiftUI

struct EPGSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \EPGSource.addedAt) private var sources: [EPGSource]
    @State private var epgSync = EPGSyncService.shared
    @AppStorage(SyncFrequency.epgStorageKey) private var freqRaw = SyncFrequency.epgDefaultValue.rawValue

    @State private var showingAdd = false
    #if os(tvOS)
        @State private var addName = ""
        @State private var addURL = ""
    #endif

    private var frequency: Binding<SyncFrequency> {
        Binding(
            get: { SyncFrequency.resolveEPG(freqRaw) },
            set: { freqRaw = $0.rawValue }
        )
    }

    var body: some View {
        #if os(tvOS)
            tvBody
        #else
            formBody
        #endif
    }

    // MARK: - Actions

    private func addSource(name: String, url: String) {
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = EPGSource(
            name: trimmedName.isEmpty ? String(localized: "Custom Guide") : trimmedName,
            url: trimmedURL
        )
        modelContext.insert(source)
        try? modelContext.save()
    }

    private func delete(_ source: EPGSource) {
        modelContext.delete(source)
        try? modelContext.save()
    }
}

// MARK: - iOS / macOS

#if !os(tvOS)

    private extension EPGSettingsView {
        var formBody: some View {
            Form {
                sourcesSection
                refreshSection
            }
            #if os(macOS)
            .formStyle(.grouped)
            #endif
            .navigationTitle("TV Guide")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
                .sheet(isPresented: $showingAdd) {
                    AddEPGSourceView { name, url in addSource(name: name, url: url) }
                }
        }

        var sourcesSection: some View {
            Section {
                if sources.isEmpty {
                    Text("No EPG sources yet. Adding a playlist sets one up automatically, or add a custom XMLTV feed below.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sources) { source in
                        sourceRow(source)
                    }
                }

                Button {
                    showingAdd = true
                } label: {
                    Label("Add EPG Source", systemImage: "plus")
                }
            } header: {
                Text("Sources")
            } footer: {
                Text("Guide data is matched to channels across all your playlists.")
            }
        }

        /// One source row, with a delete affordance only when the source is
        /// deletable at all. Playlist-linked sources are regenerated from their
        /// playlist on every reconcile, so offering to delete one would just
        /// show it coming back.
        ///
        /// Manual sources carry three, because no single one covers every
        /// platform: swipe is the iOS idiom but does nothing on macOS (AppKit
        /// list rows have no swipe gesture), which left a custom XMLTV feed
        /// added on a Mac with no way to remove it at all. macOS gets a visible
        /// trash button — a context menu alone is about as discoverable as the
        /// swipe was — and the context menu comes along for both platforms.
        @ViewBuilder
        func sourceRow(_ source: EPGSource) -> some View {
            if source.isManual {
                EPGSourceRow(source: source, onDelete: { delete(source) })
                    .swipeActions(edge: .trailing) {
                        Button("Delete", role: .destructive) { delete(source) }
                    }
                    .contextMenu {
                        Button("Delete", role: .destructive) { delete(source) }
                    }
            } else {
                EPGSourceRow(source: source)
            }
        }

        var refreshSection: some View {
            Section {
                Picker("Refresh", selection: frequency) {
                    ForEach(SyncFrequency.allCases) { frequency in
                        Text(frequency.label).tag(frequency)
                    }
                }
                .pickerStyle(.menu)

                Button {
                    epgSync.syncNow()
                } label: {
                    HStack {
                        Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                        if epgSync.isSyncing {
                            Spacer()
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }
                .disabled(epgSync.isSyncing || sources.isEmpty)
            } header: {
                Text("Automatic Refresh")
            } footer: {
                Text("The TV guide refreshes automatically in the background at this interval.")
            }
        }
    }

    private struct EPGSourceRow: View {
        @Bindable var source: EPGSource
        /// Non-nil only for deletable (manual) sources. Drives the macOS trash
        /// button; the swipe action and context menu are applied by the caller.
        var onDelete: (() -> Void)?

        var body: some View {
            #if os(macOS)
                HStack(spacing: 12) {
                    toggle
                    if let onDelete {
                        Button(role: .destructive, action: onDelete) {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.red)
                        .help("Delete this guide source")
                        .accessibilityLabel(Text("Delete \(source.name)"))
                    }
                }
            #else
                toggle
            #endif
        }

        private var toggle: some View {
            Toggle(isOn: $source.isEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.name)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }

        private var subtitle: String {
            if source.syncStatus == .error {
                return String(localized: "Last refresh failed")
            }
            if let last = source.lastSyncDate {
                return last.formatted(.relative(presentation: .named))
            }
            return source.isManual ? source.url : String(localized: "From playlist")
        }
    }

    /// A small sheet to add a manual XMLTV source.
    private struct AddEPGSourceView: View {
        @Environment(\.dismiss) private var dismiss
        @State private var name = ""
        @State private var url = ""
        let onAdd: (String, String) -> Void

        var body: some View {
            NavigationStack {
                Form {
                    Section("Source") {
                        TextField("Name", text: $name)
                        TextField("XMLTV URL", text: $url)
                        #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                        #endif
                            .autocorrectionDisabled()
                            .textContentType(.URL)
                    }
                }
                #if os(macOS)
                .formStyle(.grouped)
                .frame(minWidth: 420, minHeight: 220)
                #endif
                .navigationTitle("Add EPG Source")
                #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                #endif
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Add") {
                                onAdd(name, url)
                                dismiss()
                            }
                            .disabled(url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { dismiss() }
                        }
                    }
            }
        }
    }

#endif

// MARK: - tvOS

#if os(tvOS)

    private extension EPGSettingsView {
        /// Rendered inline inside the Settings detail pane (the enclosing pane
        /// supplies the ScrollView, background and width framing).
        var tvBody: some View {
            VStack(alignment: .leading, spacing: 36) {
                tvSourcesSection
                tvAddSection
                tvRefreshSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        var tvSourcesSection: some View {
            VStack(alignment: .leading, spacing: 8) {
                TVSettingsSectionLabel("EPG Sources")

                if sources.isEmpty {
                    Text("No EPG sources yet. Adding a playlist sets one up automatically.")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    VStack(spacing: 2) {
                        ForEach(sources) { source in
                            tvSourceRow(source)
                        }
                    }
                }
            }
        }

        func tvSourceRow(_ source: EPGSource) -> some View {
            HStack(spacing: 16) {
                Button {
                    source.isEnabled.toggle()
                    try? modelContext.save()
                } label: {
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.name)
                            Text(tvSubtitle(source))
                                .font(.system(size: 20))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                        Text(source.isEnabled ? "On" : "Off")
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(TVSettingsRowButtonStyle())

                if source.isManual {
                    Button {
                        delete(source)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(TVContentIconButtonStyle())
                    .accessibilityLabel("Delete \(source.name)")
                }
            }
        }

        func tvSubtitle(_ source: EPGSource) -> String {
            if source.syncStatus == .error {
                return String(localized: "Last refresh failed")
            }
            if let last = source.lastSyncDate {
                return last.formatted(.relative(presentation: .named))
            }
            return source.isManual ? source.url : String(localized: "From playlist")
        }

        var tvAddSection: some View {
            VStack(alignment: .leading, spacing: 8) {
                TVSettingsSectionLabel("Add Custom Source")

                if showingAdd {
                    VStack(spacing: 18) {
                        TVSettingsField(title: "Name", placeholder: "Name", text: $addName, contentType: .name)
                        TVSettingsField(title: "XMLTV URL", placeholder: "XMLTV URL", text: $addURL, contentType: .URL)
                    }
                    VStack(spacing: 2) {
                        Button("Add Source") {
                            addSource(name: addName, url: addURL)
                            addName = ""
                            addURL = ""
                            showingAdd = false
                        }
                        .buttonStyle(TVSettingsRowButtonStyle())
                        .disabled(addURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        Button("Cancel") { showingAdd = false }
                            .buttonStyle(TVSettingsRowButtonStyle())
                    }
                } else {
                    Button {
                        showingAdd = true
                    } label: {
                        HStack(spacing: 16) {
                            Image(systemName: "plus")
                                .font(.system(size: 22, weight: .medium))
                            Text("Add EPG Source")
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(TVSettingsRowButtonStyle())
                }
            }
        }

        var tvRefreshSection: some View {
            VStack(alignment: .leading, spacing: 8) {
                TVSettingsSectionLabel("Automatic Refresh")

                VStack(spacing: 2) {
                    ForEach(SyncFrequency.allCases) { option in
                        Button {
                            frequency.wrappedValue = option
                        } label: {
                            HStack(spacing: 16) {
                                Text(option.label)
                                Spacer(minLength: 0)
                                if frequency.wrappedValue == option {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 24, weight: .semibold))
                                }
                            }
                        }
                        .buttonStyle(TVSettingsRowButtonStyle())
                    }

                    Button {
                        epgSync.syncNow()
                    } label: {
                        HStack(spacing: 16) {
                            Text("Sync Now")
                            Spacer(minLength: 0)
                            if epgSync.isSyncing {
                                ProgressView()
                            }
                        }
                    }
                    .buttonStyle(TVSettingsRowButtonStyle())
                    .disabled(epgSync.isSyncing || sources.isEmpty)
                }

                Text("The TV guide refreshes automatically in the background at this interval.")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                    .padding(.top, 6)
            }
        }
    }

#endif
