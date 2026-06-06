//
//  ChannelManagementView.swift
//  Lume
//
//  Hide and reorder the individual channels of a single live category. Reached
//  by drilling into a live category from ContentManagementView. Like that
//  screen, it relies on the ambient NavigationStack and never creates its own.
//

import SwiftData
import SwiftUI

struct ChannelManagementView: View {
    let category: Category

    /// All channels in this category — hidden ones included, so they can be
    /// un-hidden. Ordered by the Content Management convention (`customOrder`
    /// first, then the provider order).
    @Query private var streams: [LiveStream]

    init(category: Category) {
        self.category = category
        let categoryId = category.id
        _streams = Query(
            filter: #Predicate<LiveStream> { $0.categoryId == categoryId },
            sort: [
                SortDescriptor(\LiveStream.customOrder),
                SortDescriptor(\LiveStream.num),
                SortDescriptor(\LiveStream.name)
            ]
        )
    }

    private func move(from source: IndexSet, to destination: Int) {
        ContentOrganizer.reorder(streams, from: source, to: destination)
    }

    private func reset() {
        ContentOrganizer.resetOrder(streams)
        ContentOrganizer.showAll(streams)
    }

    // MARK: - Platform bodies

    #if os(tvOS)
        /// True while a channel is lifted for placement — disables Reset so it
        /// can't steal focus mid-move.
        @State private var isReordering = false

        var body: some View {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        Text(category.name)
                            .font(.system(size: 34, weight: .bold))
                            .padding(.horizontal, TVSettingsMetrics.rowHPadding)

                        HStack {
                            TVSettingsSectionLabel("Channels")
                            Spacer()
                            Button("Reset") { reset() }
                                .buttonStyle(TVSettingsActionButtonStyle())
                                .disabled(streams.isEmpty || isReordering)
                        }

                        if isReordering {
                            Text("Move up or down to position, then select to place. Press Menu to cancel.")
                                .font(.system(size: 20))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                        }

                        if streams.isEmpty {
                            Text("This category has no channels.")
                                .font(.system(size: 22))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                        } else {
                            TVReorderableContentList(
                                items: streams,
                                title: { $0.name },
                                isHidden: { $0.isHidden },
                                onToggleHidden: { $0.isHidden.toggle() },
                                onCommitOrder: { ContentOrganizer.commitOrder($0) },
                                isReordering: $isReordering,
                                scrollProxy: proxy
                            )
                        }
                    }
                    .frame(maxWidth: TVSettingsMetrics.contentMaxWidth, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 48)
                    .padding(.vertical, 72)
                }
            }
            .tvSettingsBackground()
        }
    #else
        var body: some View {
            List {
                Section {
                    if streams.isEmpty {
                        Text("This category has no channels.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(streams) { stream in
                            ChannelManageRow(
                                title: stream.name,
                                iconURL: URL(string: stream.streamIcon ?? ""),
                                isHidden: stream.isHidden,
                                onToggleHidden: { stream.isHidden.toggle() }
                            )
                        }
                        .onMove(perform: move)
                    }
                } footer: {
                    Text("Hide channels to remove them from this category, or drag to reorder. Reset restores the provider's order and shows everything.")
                }
            }
            #if os(macOS)
            .listStyle(.inset(alternatesRowBackgrounds: true))
            #endif
            .navigationTitle(category.name)
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
                        Button("Reset", role: .destructive) { reset() }
                            .disabled(streams.isEmpty)
                    }
                }
        }
    #endif
}

// MARK: - iOS / macOS row

#if !os(tvOS)
    private struct ChannelManageRow: View {
        let title: String
        let iconURL: URL?
        let isHidden: Bool
        let onToggleHidden: () -> Void

        var body: some View {
            HStack(spacing: 12) {
                Button(action: onToggleHidden) {
                    Image(systemName: isHidden ? "eye.slash" : "eye")
                        .foregroundStyle(isHidden ? Color.secondary : Color.accentColor)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(isHidden ? "Show \(title)" : "Hide \(title)")

                CachedAsyncImage(url: iconURL, maxPixelSize: 44) { phase in
                    switch phase {
                    case let .success(image):
                        image.resizable().aspectRatio(contentMode: .fit)
                    default:
                        Rectangle()
                            .fill(Color.gray.opacity(0.2))
                            .overlay {
                                Image(systemName: "antenna.radiowaves.left.and.right")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                    }
                }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                Text(title)
                    .foregroundStyle(isHidden ? .secondary : .primary)
                    .lineLimit(1)

                Spacer()
            }
        }
    }
#endif
