//
//  TVSeriesDetailView+Sources.swift
//  Lume
//
//  Which copy of a grouped series the tvOS screen shows and plays. The source
//  is picked once per series: its seasons and episodes come from that copy
//  only, and every episode plays through the playlist that owns it. Resume
//  reopens the copy last watched; Play follows the source picker's skip rules;
//  a long press on Play always asks; unfavoriting clears every copy.
//

#if os(tvOS)

    import SwiftUI

    extension TVSeriesDetailView: TitleGroupSeriesDetail {
        // MARK: - Source switcher

        /// Which copy's seasons and episodes the screen shows. Picked once per
        /// series; episodes are never merged across copies.
        var sourceSwitcher: some View {
            Button {
                isSwitchingSource = true
                showSourcePicker(
                    preselected: sourceOptions.first { $0.rowID == shown.id },
                    remembered: VODSourcePreferences.rememberedRowID(.series, groupKey: groupKey, among: sourceOptions.map(\.rowID))
                )
            } label: {
                Label("Source: \(currentSourceLabel)", systemImage: "square.stack")
                    .font(.system(size: 24, weight: .semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 28)
            }
            .buttonStyle(TVGlassButtonStyle())
            .focused($focus, equals: .source)
        }

        /// Shows `option`'s seasons and episodes, without playing.
        private func switchSource(to option: VODSourceOption) {
            guard let row = row(withID: option.rowID) else { return }
            show(row)
            Task { await loadEpisodesIfNeeded() }
        }

        // MARK: - Picker

        func pickedSource(_ option: VODSourceOption) {
            if isSwitchingSource {
                switchSource(to: option)
            } else {
                pendingPick = option
            }
        }

        /// The picker closed: play its pick, or hand focus back to the control
        /// that opened it.
        func sourcePickerDidClose() {
            let returnFocus: FocusTarget = isSwitchingSource ? .source : .play
            isSwitchingSource = false
            guard let option = pendingPick else {
                Task { @MainActor in focus = returnFocus }
                return
            }
            pendingPick = nil
            Task { await play(option) }
        }
    }

#endif
