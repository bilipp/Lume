//
//  TVCategoryRail.swift
//  Lume
//
//  The tvOS Live TV category sidebar: the shared glass rail listing the
//  virtual collections and the provider's categories, beside the channel list
//  or guide.
//

#if os(tvOS)
    import SwiftUI

    /// The Live TV categories as a `TVSidebarRail`: the virtual collections,
    /// the Recordings entry, then the provider's categories.
    struct TVCategoryRail: View {
        /// One untitled group for a single Live TV playlist; with two or more
        /// Combined members, the virtual collections above a titled group per
        /// member.
        let groups: [LiveTVSectionGroup]
        @Binding var selectedSection: LiveTVSection?
        /// Fired when the user activates (clicks) a category.
        var onCategoryActivated: () -> Void = {}
        /// The Recordings entry, below the virtual collections and above the
        /// first category; nil hides it.
        var recordings: TVCategoryRailRecordingsEntry?
        /// Told whether focus is inside the rail, for the tab-bar entry catcher.
        @Environment(TVLiveTVFocusRegions.self) private var focusRegions: TVLiveTVFocusRegions?

        var body: some View {
            TVSidebarRail(items: items, selectedID: selectedID) { isFocused in
                if let focusRegions, focusRegions.railFocused != isFocused {
                    focusRegions.railFocused = isFocused
                }
            }
        }

        /// Visual order is focus order: Favorites and Recently Watched
        /// (whichever exist), Recordings, then the provider's categories —
        /// each Combined member's under its name when there are headers.
        /// Headers are plain text, never focusable, so up/down hops straight
        /// from one member's last category to the next one's first.
        private var items: [TVSidebarRailItem] {
            var items = (groups.first?.sections ?? []).prefix(while: \.isVirtual).map { categoryItem($0) }
            if let recordings {
                items.append(TVSidebarRailItem(
                    id: TVCategoryRailRecordingsEntry.id,
                    title: Text("Recordings"),
                    icon: recordings.isLocked ? "crown" : "recordingtape",
                    action: recordings.onActivate
                ))
            }
            for group in groups {
                let categories = group.sections.drop(while: \.isVirtual)
                items += categories.enumerated().map { index, section in
                    categoryItem(section, header: index == 0 ? group.title : nil)
                }
            }
            return items
        }

        /// The row that reads as selected: Recordings while its library shows,
        /// else the selected category.
        private var selectedID: String? {
            recordings?.isSelected == true ? TVCategoryRailRecordingsEntry.id : selectedSection?.id
        }

        private func categoryItem(_ section: LiveTVSection, header: String? = nil) -> TVSidebarRailItem {
            TVSidebarRailItem(id: section.id, title: section.titleText, icon: section.icon, header: header) {
                selectedSection = section
                onCategoryActivated()
            }
        }
    }

    /// The Recordings row under the virtual collections, shown while a
    /// recording server is paired and Settings › Live TV lists it in the rail.
    /// Locked (no Lume Pro) it carries the crown.
    struct TVCategoryRailRecordingsEntry {
        static let id = "lume.liveSection.recordings"

        let isSelected: Bool
        let isLocked: Bool
        let onActivate: () -> Void
    }
#endif
