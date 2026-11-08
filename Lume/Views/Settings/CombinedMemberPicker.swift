//
//  CombinedMemberPicker.swift
//  Lume
//

import SwiftUI

/// Picks one Combined member, for the settings screens that manage a single
/// member at a time. `includesCombined` leads with an entry for the whole
/// selection, which picks `nil`.
struct CombinedMemberPicker: View {
    let members: [Playlist]
    @Binding var selection: UUID?
    var includesCombined = false

    var body: some View {
        #if os(tvOS)
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    if includesCombined {
                        segment(PlaylistSelectionStore.combinedTitle, id: nil)
                    }
                    ForEach(members, id: \.id) { member in
                        segment(member.name, id: member.id)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
            .focusSection()
        #else
            Picker("Playlist", selection: $selection) {
                if includesCombined {
                    Text(verbatim: PlaylistSelectionStore.combinedTitle).tag(UUID?.none)
                }
                ForEach(members, id: \.id) { member in
                    Text(verbatim: member.name).tag(Optional(member.id))
                }
            }
        #endif
    }

    #if os(tvOS)
        private func segment(_ title: String, id: UUID?) -> some View {
            let isPicked = id == selection
            return Button {
                selection = id
            } label: {
                Text(verbatim: title)
                    .lineLimit(1)
            }
            .buttonStyle(TVSettingsActionButtonStyle(prominent: isPicked))
            .accessibilityAddTraits(isPicked ? .isSelected : [])
        }
    #endif
}
