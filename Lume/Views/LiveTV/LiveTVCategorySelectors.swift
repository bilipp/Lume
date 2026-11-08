//
//  LiveTVCategorySelectors.swift
//  Lume
//
//  How the viewer picks which collection of live channels to browse: the macOS
//  sidebar list and the iOS button-plus-searchable-sheet. Split out of
//  `LiveTVView` to keep that file focused on cross-platform composition (and
//  inside the project's file-length cap).
//

import SwiftData
import SwiftUI

// MARK: - Category Sidebar

struct CategorySidebar: View {
    let groups: [LiveTVSectionGroup]
    @Binding var selectedSection: LiveTVSection?

    var body: some View {
        List {
            ForEach(groups) { group in
                LiveTVSectionGroupSection(group: group) { section in
                    row(section)
                }
            }
        }
        #if !os(tvOS)
        .listStyle(.sidebar)
        #endif
    }

    private func row(_ section: LiveTVSection) -> some View {
        let isSelected = selectedSection?.id == section.id
        return Button {
            selectedSection = section
        } label: {
            HStack(spacing: 8) {
                if let icon = section.icon {
                    Image(systemName: icon)
                        .font(.subheadline)
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                }
                section.titleText
                    .font(.headline)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            isSelected
                ? Color.accentColor.opacity(0.15)
                : Color.clear
        )
    }
}

// MARK: - Group section

/// One rail group as a `List` section. Only a titled group — a member's
/// categories in Combined with two or more Live TV members — gets a header, so
/// a single-playlist rail renders as the flat list it always was.
struct LiveTVSectionGroupSection<Row: View>: View {
    let group: LiveTVSectionGroup
    /// Renders the title as the section's first row instead of its header. A
    /// `.plain` list pins headers with no background on iOS 26, so a pinned
    /// title draws over the rows scrolling under it.
    var titleAsRow = false
    @ViewBuilder let row: (LiveTVSection) -> Row

    var body: some View {
        if let title = group.title, titleAsRow {
            Section {
                Text(verbatim: title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                #if !os(tvOS)
                    .listRowSeparator(.hidden)
                #endif
                ForEach(group.sections, content: row)
            }
        } else if let title = group.title {
            Section {
                ForEach(group.sections, content: row)
            } header: {
                Text(verbatim: title)
                    .accessibilityAddTraits(.isHeader)
            }
        } else {
            Section {
                ForEach(group.sections, content: row)
            }
        }
    }
}

// MARK: - iOS Category Bar

#if os(iOS)
    /// iOS category selector. A horizontal pill strip is unscannable once a
    /// playlist syncs hundreds of categories, so the current section is shown as a
    /// single button that opens a searchable list of every section instead.
    struct CategoryBar: View {
        let groups: [LiveTVSectionGroup]
        @Binding var selectedSection: LiveTVSection?

        @State private var showingPicker = false

        /// The section the button reflects — the user's selection, or the first
        /// available one if that selection has since disappeared (mirrors
        /// `displayedSection(in:)`).
        private var currentSection: LiveTVSection? {
            let sections = groups.allSections
            guard let selectedSection else { return sections.first }
            return sections.first { $0.id == selectedSection.id } ?? sections.first
        }

        /// The current category's playlist, when another member has a category
        /// of the same name — the bar shows one title, so "Sports" alone could
        /// be either.
        private func disambiguation(for section: LiveTVSection?) -> String? {
            guard groups.hasHeaders, let section, !section.isVirtual,
                  let group = groups.first(where: { $0.sections.contains { $0.id == section.id } }),
                  let title = group.title else { return nil }
            let name = section.title
            let collides = groups.contains { other in
                other.id != group.id && other.sections.contains { $0.title == name }
            }
            return collides ? title : nil
        }

        var body: some View {
            Button {
                showingPicker = true
            } label: {
                HStack(spacing: 8) {
                    if let icon = currentSection?.icon {
                        Image(systemName: icon)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    (currentSection?.titleText ?? Text("Select a Category"))
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let playlistName = disambiguation(for: currentSection) {
                        Text(verbatim: playlistName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(.bar)
            .sheet(isPresented: $showingPicker) {
                CategoryPickerSheet(groups: groups, selectedSection: $selectedSection)
            }

            Divider()
        }
    }

    /// Searchable list of every Live TV section. Type to filter hundreds of
    /// synced categories down to a handful; the virtual collections stay pinned
    /// at the top while the search field is empty.
    private struct CategoryPickerSheet: View {
        let groups: [LiveTVSectionGroup]
        @Binding var selectedSection: LiveTVSection?

        @Environment(\.dismiss) private var dismiss
        @State private var query = ""

        /// Each group narrowed to the matching sections; a group left empty is
        /// dropped along with its header.
        private var filteredGroups: [LiveTVSectionGroup] {
            let trimmed = query.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return groups }
            return groups.compactMap { group in
                let matches = group.sections.filter { $0.title.localizedCaseInsensitiveContains(trimmed) }
                return matches.isEmpty ? nil : LiveTVSectionGroup(id: group.id, title: group.title, sections: matches)
            }
        }

        var body: some View {
            let visibleGroups = filteredGroups
            NavigationStack {
                List {
                    ForEach(visibleGroups) { group in
                        LiveTVSectionGroupSection(group: group, titleAsRow: true) { section in
                            row(section)
                        }
                    }
                }
                .listStyle(.plain)
                .overlay {
                    if visibleGroups.isEmpty {
                        ContentUnavailableView.search(text: query)
                    }
                }
                .searchable(text: $query, prompt: "Search categories")
                .navigationTitle("Categories")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
        }

        private func row(_ section: LiveTVSection) -> some View {
            let isSelected = selectedSection?.id == section.id
            return Button {
                selectedSection = section
                dismiss()
            } label: {
                HStack(spacing: 12) {
                    if let icon = section.icon {
                        Image(systemName: icon)
                            .foregroundStyle(.secondary)
                    }
                    section.titleText
                        .foregroundStyle(.primary)
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark")
                            .fontWeight(.semibold)
                            .foregroundStyle(.tint)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
#endif
