//
//  SettingsView+Language.swift
//  Lume
//
//  The preferred audio language list (iOS, macOS, visionOS). Split out of
//  SettingsView, which is already at the file-length limit.
//
//  The list ships EMPTY, which means "no preference" and behaves exactly as
//  Lume did before the setting existed.
//

import SwiftUI

#if !os(tvOS)

    // MARK: - Settings row

    extension SettingsView {
        var preferredAudioLanguageRow: some View {
            NavigationLink {
                PreferredLanguageListView()
            } label: {
                PreferredLanguageRowLabel(codes: PreferredLanguageList.decode(preferredAudioLanguagesRaw))
            }
        }
    }

    // MARK: - Row label

    private struct PreferredLanguageRowLabel: View {
        let codes: [String]

        var body: some View {
            HStack {
                Text("Audio Languages")
                Spacer()
                Group {
                    if codes.isEmpty {
                        Text("Automatic")
                    } else {
                        Text(verbatim: codes.map { TrackLanguageMatcher.displayName(for: $0) }.joined(separator: ", "))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            }
        }
    }

    // MARK: - Ordered list

    /// Drag-to-reorder list of preferred audio languages, most-preferred first.
    /// Empty is the shipped default and means Lume leaves the stream's own
    /// track selection alone.
    struct PreferredLanguageListView: View {
        @AppStorage(PlayerSettings.Language.preferredAudioLanguagesKey)
        private var raw = PlayerSettings.Language.preferredAudioLanguagesDefault
        @State private var isAddingLanguage = false

        private var codes: [String] {
            PreferredLanguageList.decode(raw)
        }

        var body: some View {
            List {
                Section {
                    if codes.isEmpty {
                        Text("No Preferred Languages")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(codes, id: \.self) { code in
                            let language = PreferredLanguage(code: code)
                            PreferredLanguageRow(language: language)
                                .macRemoveButton(named: language.name) { remove(code) }
                                // macOS never enters edit mode (see
                                // `alwaysReorderable`), so `onDelete` alone
                                // leaves its rows unremovable.
                                .contextMenu {
                                    Button(role: .destructive) {
                                        remove(code)
                                    } label: {
                                        Label(
                                            "Remove \(language.name)",
                                            systemImage: "trash"
                                        )
                                    }
                                }
                        }
                        .onMove(perform: move)
                        .onDelete(perform: delete)
                    }
                } footer: {
                    // swiftlint:disable:next line_length
                    Text("Lume selects the first of these languages the stream offers as an audio track. Drag to reorder. When the audio that plays is in none of them and the stream carries a forced subtitle track, that track is turned on. Applied the next time playback starts.")
                }
            }
            .platformNavigationTitle("Audio Languages")
            // The list is held in edit mode so rows are always draggable, and a
            // row inside an editing List takes no taps — hence the toolbar
            // button rather than an "Add Language" row.
            .alwaysReorderable()
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isAddingLanguage = true
                    } label: {
                        Label("Add Language", systemImage: "plus")
                    }
                }
            }
            .navigationDestination(isPresented: $isAddingLanguage) {
                AddPreferredLanguageView(selected: codes, onAdd: add)
            }
        }

        private func move(from offsets: IndexSet, to destination: Int) {
            var list = codes
            list.move(fromOffsets: offsets, toOffset: destination)
            raw = PreferredLanguageList.encode(list)
        }

        private func remove(_ code: String) {
            raw = PreferredLanguageList.encode(codes.filter { $0 != code })
        }

        private func delete(at offsets: IndexSet) {
            var list = codes
            list.remove(atOffsets: offsets)
            raw = PreferredLanguageList.encode(list)
        }

        private func add(_ code: String) {
            raw = PreferredLanguageList.encode(codes + [code])
        }
    }

    // MARK: - Add picker

    /// The curated shortlist up front, the viewer's own device languages on top
    /// of it, and every ISO language behind the search field. Sourced from
    /// `Locale` alone — see `PreferredLanguageCatalog`.
    struct AddPreferredLanguageView: View {
        let selected: [String]
        let onAdd: (String) -> Void

        @Environment(\.dismiss) private var dismiss
        @State private var searchText = ""

        private var results: [PreferredLanguage] {
            PreferredLanguageCatalog.available(PreferredLanguageCatalog.search(searchText), excluding: selected)
        }

        var body: some View {
            let matches = results
            return List {
                if searchText.isEmpty {
                    let addable = PreferredLanguageCatalog.addable(excluding: selected)
                    if !addable.suggested.isEmpty {
                        Section {
                            rows(addable.suggested)
                        } header: {
                            Text("Suggested")
                        }
                    }

                    Section {
                        rows(addable.common)
                    } header: {
                        Text("Common Languages")
                    } footer: {
                        Text("Search to find any other language.")
                    }
                } else if matches.isEmpty {
                    Text("No Languages Found")
                        .foregroundStyle(.secondary)
                } else {
                    rows(matches)
                }
            }
            .platformNavigationTitle("Add Language")
            .searchable(text: $searchText, prompt: "Search languages")
        }

        private func rows(_ languages: [PreferredLanguage]) -> some View {
            ForEach(languages) { language in
                Button {
                    onAdd(language.code)
                    dismiss()
                } label: {
                    PreferredLanguageRow(language: language)
                        // `.plain` shrinks a List button's hit area to the text
                        // itself; without this the gap between name and code
                        // takes no tap.
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Shared row

    private struct PreferredLanguageRow: View {
        let language: PreferredLanguage

        var body: some View {
            HStack {
                Text(verbatim: language.name)
                Spacer()
                Text(verbatim: language.code.uppercased())
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Platform helpers

    private extension View {
        /// Keeps the list permanently in edit mode so rows are always
        /// draggable — no Edit button to enter reorder mode first. Written as a
        /// modifier rather than an inline `#if` in the chain: SwiftFormat
        /// reindents adjacent `#if` blocks there and has broken the build.
        ///
        /// macOS is deliberately absent: it has no `EditMode`, and an AppKit
        /// `List` makes `onMove` rows draggable on its own, so the footer's
        /// "Drag to reorder" holds there without this.
        func alwaysReorderable() -> some View {
            #if os(iOS) || os(visionOS)
                environment(\.editMode, .constant(.active))
            #else
                self
            #endif
        }

        /// macOS gets neither the edit-mode delete badge (`alwaysReorderable`
        /// excludes it) nor a swipe, so without this the context menu is the
        /// only way to remove a language and nothing on screen says so.
        func macRemoveButton(named name: String, remove: @escaping () -> Void) -> some View {
            #if os(macOS)
                HStack(spacing: 8) {
                    self
                    Button(action: remove) {
                        Image(systemName: "minus.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Remove \(name)")
                }
            #else
                self
            #endif
        }
    }

    #Preview {
        NavigationStack {
            PreferredLanguageListView()
        }
    }

#endif
