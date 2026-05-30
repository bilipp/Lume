//
//  SortMenu.swift
//  Lume
//
//  Toolbar menu that lets the user pick category and content sort options.
//  Used on the Live TV, Movies, and Series main views.
//

import SwiftUI

struct SortMenu: View {
    @Binding var categorySortRaw: String
    @Binding var contentSortRaw: String

    var body: some View {
        Menu {
            Section("Categories") {
                ForEach(CategorySortOption.allCases) { option in
                    Button {
                        categorySortRaw = option.rawValue
                    } label: {
                        Label(option.label, systemImage: option.icon)
                        if option.rawValue == categorySortRaw {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }

            Section("Content") {
                ForEach(ContentSortOption.allCases) { option in
                    Button {
                        contentSortRaw = option.rawValue
                    } label: {
                        Label(option.label, systemImage: option.icon)
                        if option.rawValue == contentSortRaw {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle")
        }
    }
}

// MARK: - Content-Only Sort Menu

struct ContentSortMenu: View {
    @Binding var sortRaw: String

    var body: some View {
        Menu {
            Section("Sort By") {
                ForEach(ContentSortOption.allCases) { option in
                    Button {
                        sortRaw = option.rawValue
                    } label: {
                        Label(option.label, systemImage: option.icon)
                        if option.rawValue == sortRaw {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle")
        }
    }
}

#Preview("Full Sort Menu") {
    SortMenu(
        categorySortRaw: .constant(CategorySortOption.playlist.rawValue),
        contentSortRaw: .constant(ContentSortOption.playlist.rawValue)
    )
}

#Preview("Content Only") {
    ContentSortMenu(sortRaw: .constant(ContentSortOption.playlist.rawValue))
}
