//
//  ContentManagementView.swift
//  Lume
//
//  Lets the user hide and reorder the categories of the active playlist, and
//  drill into a live category to manage its individual channels. Preferences
//  live on the `Category` / `LiveStream` models (`isHidden`, `customOrder`), so
//  they're inherently per-playlist and survive re-syncs.
//
//  This view never wraps itself in a NavigationStack — it is always presented
//  inside an existing one (pushed from Settings on iOS/macOS, shown in the
//  Settings detail pane on tvOS), and relies on that ambient stack for the
//  drill-down into channel management.
//

import SwiftData
import SwiftUI

struct ContentManagementView: View {
    @Query private var playlists: [Playlist]
    @AppStorage(PlaylistSelectionStore.key) private var selectedPlaylistID: String = ""

    @State private var selectedType: CategoryType = .live

    /// Every category across all playlists; scoped and sorted in-memory. Category
    /// counts are small (tens–low hundreds per playlist), so an in-memory pass is
    /// simpler than re-parameterising a `@Query` on the picker selection.
    @Query private var allCategories: [Category]

    var body: some View {
        Group {
            if activePlaylist != nil {
                content
            } else {
                ContentUnavailableView(
                    "No Playlist",
                    systemImage: "square.stack.3d.up.slash",
                    description: Text("Add a playlist to manage its content.")
                )
            }
        }
        .navigationDestination(for: Category.self) { category in
            ChannelManagementView(category: category)
        }
    }

    // MARK: - Scoping

    private var activePlaylist: Playlist? {
        playlists.active(for: selectedPlaylistID)
    }

    /// Categories of the selected type for the active playlist, in effective
    /// order (user order if set, else the synced playlist order).
    private var categories: [Category] {
        guard let playlistId = activePlaylist?.id else { return [] }
        let prefix = "\(playlistId.uuidString)-"
        return allCategories
            .filter { $0.typeRaw == selectedType.rawValue && $0.id.hasPrefix(prefix) }
            .sorted { lhs, rhs in
                (lhs.customOrder ?? lhs.sortOrder, lhs.name) < (rhs.customOrder ?? rhs.sortOrder, rhs.name)
            }
    }

    // MARK: - Mutations

    private func move(from source: IndexSet, to destination: Int) {
        ContentOrganizer.reorder(categories, from: source, to: destination)
    }

    private func resetCurrentType() {
        ContentOrganizer.resetOrder(categories)
        ContentOrganizer.showAll(categories)
    }

    // MARK: - Platform bodies

    #if os(tvOS)
        private var content: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    Text("Content")
                        .font(.system(size: 34, weight: .bold))
                        .padding(.horizontal, TVSettingsMetrics.rowHPadding)

                    if let name = activePlaylist?.name {
                        Text(name)
                            .font(.system(size: 22))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                    }

                    tvTypePicker

                    tvCategoryList
                }
                .frame(maxWidth: TVSettingsMetrics.contentMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 48)
                .padding(.vertical, 72)
            }
            .tvSettingsBackground()
        }

        private var tvTypePicker: some View {
            HStack(spacing: 12) {
                ForEach(CategoryType.allCases) { type in
                    Button {
                        selectedType = type
                    } label: {
                        Text(type.label)
                    }
                    .buttonStyle(TVSettingsActionButtonStyle(prominent: selectedType == type))
                }
            }
            .focusSection()
            .padding(.bottom, 4)
        }

        @ViewBuilder
        private var tvCategoryList: some View {
            HStack {
                TVSettingsSectionLabel("Categories")
                Spacer()
                Button("Reset") { resetCurrentType() }
                    .buttonStyle(TVSettingsActionButtonStyle())
            }

            if categories.isEmpty {
                Text("Nothing to manage yet. Sync this playlist first.")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 6) {
                    ForEach(Array(categories.enumerated()), id: \.element.id) { index, category in
                        TVContentManageRow(
                            title: category.name,
                            isHidden: category.isHidden,
                            isFirst: index == 0,
                            isLast: index == categories.count - 1,
                            showsDrillIn: selectedType == .live,
                            drillValue: category,
                            onToggleHidden: { category.isHidden.toggle() },
                            onMoveUp: { ContentOrganizer.move(categories, at: index, by: -1) },
                            onMoveDown: { ContentOrganizer.move(categories, at: index, by: 1) }
                        )
                    }
                }
                .focusSection()
            }
        }
    #else
        private var content: some View {
            List {
                Section {
                    Picker("Type", selection: $selectedType) {
                        ForEach(CategoryType.allCases) { type in
                            Text(type.label).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                    .listRowBackground(Color.clear)
                }

                Section {
                    if categories.isEmpty {
                        Text("Nothing to manage yet. Sync this playlist first.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(categories) { category in
                            ContentManageRow(
                                title: category.name,
                                isHidden: category.isHidden,
                                drillInValue: selectedType == .live ? category : nil,
                                onToggleHidden: { category.isHidden.toggle() }
                            )
                        }
                        .onMove(perform: move)
                    }
                } header: {
                    Text("Categories")
                } footer: {
                    Text(footerText)
                }
            }
            #if os(macOS)
            .listStyle(.inset(alternatesRowBackgrounds: true))
            #endif
            .platformNavigationTitle("Content")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
                .toolbar {
                    #if os(iOS)
                        ToolbarItem(placement: .topBarTrailing) {
                            EditButton()
                        }
                    #endif
                    ToolbarItem(placement: .automatic) {
                        Button("Reset", role: .destructive) { resetCurrentType() }
                            .disabled(categories.isEmpty)
                    }
                }
        }

        private var footerText: String {
            switch selectedType {
            case .live:
                "Hide categories to remove them from Live TV, or drag to reorder. Tap a category to manage its channels. Reset restores the playlist's order and shows everything."
            default:
                "Hide categories to remove them from \(selectedType.label), or drag to reorder. Reset restores the playlist's order and shows everything."
            }
        }
    #endif
}

// MARK: - iOS / macOS row

#if !os(tvOS)
    /// One reorderable category row: a leading hide toggle, the name, and an
    /// optional trailing link into channel management (live only). Hiding and
    /// reordering are deliberately separate modes — reorder happens in edit mode
    /// (drag handles), hiding in normal mode — which sidesteps the edit-mode /
    /// in-row-control interaction traps.
    private struct ContentManageRow: View {
        let title: String
        let isHidden: Bool
        let drillInValue: Category?
        let onToggleHidden: () -> Void

        var body: some View {
            HStack(spacing: 12) {
                Button(action: onToggleHidden) {
                    Image(systemName: isHidden ? "eye.slash" : "eye")
                        .foregroundStyle(isHidden ? Color.secondary : Color.accentColor)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(isHidden ? "Show \(title)" : "Hide \(title)")

                Text(title)
                    .foregroundStyle(isHidden ? .secondary : .primary)

                Spacer()

                if let drillInValue {
                    NavigationLink(value: drillInValue) {
                        Text("Channels")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }
#endif

// MARK: - tvOS row

#if os(tvOS)
    /// A focus-friendly management row for tvOS. There is no drag reorder on
    /// tvOS, so ordering uses explicit up/down buttons; each control is its own
    /// focusable target laid out left-to-right.
    struct TVContentManageRow: View {
        let title: String
        let isHidden: Bool
        let isFirst: Bool
        let isLast: Bool
        let showsDrillIn: Bool
        let drillValue: Category
        let onToggleHidden: () -> Void
        let onMoveUp: () -> Void
        let onMoveDown: () -> Void

        var body: some View {
            HStack(spacing: 14) {
                Button(action: onMoveUp) {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(TVContentIconButtonStyle())
                .disabled(isFirst)

                Button(action: onMoveDown) {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(TVContentIconButtonStyle())
                .disabled(isLast)

                Button(action: onToggleHidden) {
                    Image(systemName: isHidden ? "eye.slash" : "eye")
                }
                .buttonStyle(TVContentIconButtonStyle())

                Text(title)
                    .font(.system(size: TVSettingsMetrics.rowFontSize))
                    .foregroundStyle(isHidden ? .secondary : .primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if showsDrillIn {
                    NavigationLink(value: drillValue) {
                        HStack(spacing: 10) {
                            Text("Channels")
                            Image(systemName: "chevron.right")
                        }
                    }
                    .buttonStyle(TVContentActionButtonStyle())
                }
            }
            .padding(.horizontal, TVSettingsMetrics.rowHPadding)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: TVSettingsMetrics.rowCornerRadius, style: .continuous)
                    .fill(Color.white.opacity(0.04))
            )
        }
    }

    /// Compact square icon button used for the per-row tvOS controls.
    struct TVContentIconButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            StyleBody(configuration: configuration)
        }

        struct StyleBody: View {
            let configuration: ButtonStyleConfiguration
            @Environment(\.isFocused) private var isFocused
            @Environment(\.isEnabled) private var isEnabled

            var body: some View {
                configuration.label
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(isFocused ? .black : .white)
                    .opacity(isEnabled ? 1 : 0.25)
                    .frame(width: 56, height: 56)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(isFocused ? AnyShapeStyle(Color.white.opacity(0.95)) : AnyShapeStyle(Color.white.opacity(0.08)))
                    )
                    .animation(.easeOut(duration: 0.15), value: isFocused)
            }
        }
    }

    /// Pill action button (e.g. "Channels") for tvOS rows.
    struct TVContentActionButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            StyleBody(configuration: configuration)
        }

        struct StyleBody: View {
            let configuration: ButtonStyleConfiguration
            @Environment(\.isFocused) private var isFocused

            var body: some View {
                configuration.label
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(isFocused ? .black : .white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(isFocused ? AnyShapeStyle(Color.white.opacity(0.95)) : AnyShapeStyle(Color.white.opacity(0.08)))
                    )
                    .animation(.easeOut(duration: 0.15), value: isFocused)
            }
        }
    }
#endif

#Preview("Content Management") {
    NavigationStack {
        ContentManagementView()
    }
    .modelContainer(previewContainer())
}
