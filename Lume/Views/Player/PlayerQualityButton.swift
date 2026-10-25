//
//  PlayerQualityButton.swift
//  Lume
//
//  The in-player Quality menu shared by the KSPlayer, VLCKit, AVPlayer and
//  LumeEngine overlays on iOS, macOS and visionOS. Shown only while the
//  playing live channel has another quality in its playlist; the host
//  resolves the variants (`PlayerQualityVariantsHost`), so the body only reads
//  them.
//

import SwiftUI

struct PlayerQualityButton: View {
    var onResetHideTimer: () -> Void

    @Environment(\.playerQualitySwitcher) private var switcher

    var body: some View {
        if let switcher, switcher.offersSwitching {
            Menu {
                PlayerQualityMenuItems(switcher: switcher, onResetHideTimer: onResetHideTimer)
            } label: {
                Image(systemName: "sparkles.tv")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .menuIndicator(.hidden)
            .trackMenuAccessibility(
                "Quality", selected: switcher.variants.first { $0.id == switcher.currentID }?.tag, fallback: "Standard"
            )
            .help("Quality")
        }
    }
}

/// The Quality menu's entries, shared by this button and the tvOS overlay's.
struct PlayerQualityMenuItems: View {
    let switcher: PlayerQualitySwitcher
    var onResetHideTimer: () -> Void

    var body: some View {
        ForEach(switcher.variants) { variant in
            let isCurrent = variant.id == switcher.currentID
            Button {
                switcher.select(variant)
                onResetHideTimer()
            } label: {
                playerCheckmarkLabel(tagText(variant.tag), verbatimSubtitle: variant.name, checked: isCurrent)
            }
            .accessibilityAddTraits(isCurrent ? .isSelected : [])
        }
        .holdsPlayerControls()
    }

    /// Provider quality tags ("4K", "FHD", "ᴴᴰ") are shown as written; only an
    /// untagged sibling gets a localized title.
    private func tagText(_ tag: String?) -> Text {
        if let tag { Text(verbatim: tag) } else { Text("Standard") }
    }
}
