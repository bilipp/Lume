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

    /// True while a category is lifted for placement on tvOS — used to disable
    /// the type picker and Reset so they can't steal focus mid-move.
    @State private var isReordering = false

    /// Every category across all playlists; scoped and sorted in-memory. Category
    /// counts are small (tens–low hundreds per playlist), so an in-memory pass is
    /// simpler than re-parameterising a `@Query` on the picker selection.
    @Query private var allCategories: [Category]

    #if !os(tvOS)
        /// Drives the drill-in to channel management. Owned here (not by a List
        /// row's NavigationLink) so the push survives the List reloading its rows.
        @State private var selectedCategory: Category?
        /// Drives the drill-in to favorites reordering, same rationale as above.
        @State private var favoritesRoute: FavoriteChannelsRoute?
    #endif

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
        #if os(tvOS)
        // tvOS pushes via NavigationLink(value:) from TVReorderableContentList.
        .navigationDestination(for: Category.self) { category in
            ChannelManagementView(category: category)
        }
        .navigationDestination(for: FavoriteChannelsRoute.self) { _ in
            FavoriteChannelManagementView()
        }
        #else
                // iOS/macOS drives the drill-in from view-owned @State rather than a
                // value-based NavigationLink inside the List row. A row link's push is
                // cleared when the List reloads its ForEach — and it reloads on the
                // SwiftData change notification fired by ChannelManagementView's first
                // @Query fetch — so the channel list would flash up and pop straight
                // back. An item-binding push survives that reload.
        .navigationDestination(item: $selectedCategory) { category in
                    ChannelManagementView(category: category)
                }
                .navigationDestination(item: $favoritesRoute) { _ in
                    FavoriteChannelManagementView()
                }
        #endif
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

    /// Drill-in provider for the reorderable list: only live categories expose a
    /// channels link. Written as a function (not a ternary) so the closure type
    /// is unambiguous.
    private var categoryDrill: ((Category) -> Category)? {
        guard selectedType == .live else { return nil }
        return { $0 }
    }

    // MARK: - Platform bodies

    #if os(tvOS)
        private var content: some View {
            ScrollViewReader { proxy in
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

                        if selectedType == .live, !isReordering {
                            NavigationLink(value: FavoriteChannelsRoute()) {
                                HStack(spacing: 14) {
                                    Image(systemName: "heart.fill")
                                    Text("Favorites")
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                }
                            }
                            .buttonStyle(TVContentActionButtonStyle())
                            .focusSection()
                        }

                        tvCategoryList(proxy: proxy)
                    }
                    .frame(maxWidth: TVSettingsMetrics.detailMaxWidth, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 48)
                    .padding(.vertical, 72)
                }
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
            .disabled(isReordering)
        }

        @ViewBuilder
        private func tvCategoryList(proxy: ScrollViewProxy) -> some View {
            HStack {
                TVSettingsSectionLabel("Categories")
                Spacer()
                Button("Reset") { resetCurrentType() }
                    .buttonStyle(TVSettingsActionButtonStyle())
                    .disabled(isReordering)
            }

            if isReordering {
                Text("Move up or down to position, then select to place. Press Menu to cancel.")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, TVSettingsMetrics.rowHPadding)
            }

            if categories.isEmpty {
                Text("Nothing to manage yet. Sync this playlist first.")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                    .padding(.vertical, 8)
            } else {
                TVReorderableContentList(
                    items: categories,
                    title: { $0.name },
                    isHidden: { $0.isHidden },
                    drillValue: categoryDrill,
                    onToggleHidden: { $0.isHidden.toggle() },
                    onCommitOrder: { ContentOrganizer.commitOrder($0) },
                    isReordering: $isReordering,
                    scrollProxy: proxy
                )
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

                if selectedType == .live {
                    Section {
                        Button {
                            favoritesRoute = FavoriteChannelsRoute()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "heart.fill")
                                    .foregroundStyle(.red)
                                Text("Favorites")
                                    .foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    } footer: {
                        Text("Reorder the channels in your Favorites category.")
                    }
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
                                onToggleHidden: { category.isHidden.toggle() },
                                onDrillIn: { selectedCategory = $0 }
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
        let onDrillIn: (Category) -> Void

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
                    Button {
                        onDrillIn(drillInValue)
                    } label: {
                        HStack(spacing: 4) {
                            Text("Channels")
                                .font(.callout)
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .fontWeight(.semibold)
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
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
