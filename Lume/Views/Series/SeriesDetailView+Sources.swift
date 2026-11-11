//
//  SeriesDetailView+Sources.swift
//  Lume
//
//  Which copy of a grouped series the screen shows and plays. The source is
//  picked once per series: its seasons and episodes come from that copy only,
//  and every episode plays through the playlist that owns it. Resume reopens
//  the copy last watched; Play follows the source picker's skip rules;
//  unfavoriting clears every copy.
//

import SwiftUI

extension SeriesDetailView: TitleGroupSeriesDetail {
    // MARK: - Play and source controls

    var actions: some View {
        let isPlayable = !sourceOptions.isEmpty || (nextEpisode != nil && seriesPlaylist != nil)
        return VStack(alignment: .leading, spacing: 12) {
            PrimaryPlayButton(
                title: playTitle,
                isEnabled: isPlayable,
                chooseSource: sourceOptions.isEmpty ? nil : { playNext(forcePicker: true) },
                action: { playNext() }
            )
            .missingPlaylistNotice(!isPlayable)

            if sourceOptions.count > 1 {
                sourceMenu
            }
        }
    }

    /// Which copy's seasons and episodes the screen shows. Picked once per
    /// series; episodes are never merged across copies.
    var sourceMenu: some View {
        Menu {
            ForEach(sourceOptions) { option in
                Button {
                    switchSource(to: option)
                } label: {
                    if option.rowID == shown.id {
                        Label(option.summaryLabel, systemImage: "checkmark")
                    } else {
                        Text(verbatim: option.summaryLabel)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "square.stack")
                    .font(.caption.weight(.semibold))
                Text("Source: \(currentSourceLabel)")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.quaternary, in: Capsule())
            .sourceMenuHoverEffect()
        }
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .sourceMenuStyle()
    }

    // MARK: - Switching

    /// Shows `option`'s seasons and episodes, without playing.
    func switchSource(to option: VODSourceOption) {
        VODSourcePreferences.remember(rowID: option.rowID, .series, groupKey: groupKey)
        guard let row = row(withID: option.rowID) else { return }
        show(row)
        Task { await loadEpisodesIfNeeded() }
    }

    // MARK: - Playback

    /// A pick waits for the sheet's `onDismiss`: a cover presented while the
    /// sheet is still animating out is torn down and presented again by UIKit.
    func playPendingPick() {
        guard let option = pendingPick else { return }
        pendingPick = nil
        Task { await play(option) }
    }
}

private extension View {
    /// Without it a macOS pull-down keeps its own bezel around the capsule.
    @ViewBuilder
    func sourceMenuStyle() -> some View {
        #if os(macOS)
            menuStyle(.button)
        #else
            self
        #endif
    }

    @ViewBuilder
    func sourceMenuHoverEffect() -> some View {
        #if os(iOS) || os(visionOS)
            contentShape(.hoverEffect, Capsule())
                .hoverEffect(.highlight)
        #else
            self
        #endif
    }
}
