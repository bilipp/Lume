//
//  TVSwitchRows.swift
//  Lume
//
//  The playlist and profile rows shared by every tvOS switch surface (the
//  Settings Playlists/Profiles panes and the quick-switch overlay). They draw the
//  row itself only — the Settings panes compose their pencil affordance alongside
//  one, so a surface that must not offer editing simply leaves it out.
//

#if os(tvOS)

    import SwiftUI

    /// A full-width playlist row: name over server URL, with a checkmark on the
    /// active one. Full width matters for focus — a narrow target won't catch
    /// "down" from a full-width section above it.
    struct TVPlaylistSwitchRow: View {
        let playlist: Playlist
        let isActive: Bool
        /// Whether the playlist is in the resolved scope, for its sync state. In
        /// Combined every member is, while no row carries the checkmark.
        let isInScope: Bool
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(playlist.name)
                        Text(playlist.displayURL)
                            .font(.system(size: TVSettingsMetrics.secondaryFontSize))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                    PlaylistSyncAccessory(state: playlist.syncState(isActive: isInScope), size: 26)
                    if isActive {
                        TVSwitchRowCheckmark()
                    }
                }
            }
            .buttonStyle(TVSettingsRowButtonStyle())
            .modifier(TVSwitchRowActiveState(isActive: isActive))
        }
    }

    /// The Combined entry atop a playlist column: its members over the title,
    /// a checkmark while it is in effect, and the plain crown while it is
    /// locked behind Lume Pro. Never disabled — a locked or unconfigured
    /// Combined still takes the press and opens the paywall or Settings.
    struct TVCombinedSwitchRow: View {
        let memberNames: [String]
        let isActive: Bool
        let isLocked: Bool
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(PlaylistSelectionStore.combinedTitle)
                        subtitle
                            .font(.system(size: TVSettingsMetrics.secondaryFontSize))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                    if isLocked {
                        TVSwitchRowGlyph(systemName: "crown", label: Text("Lume Pro"))
                    }
                    if isActive {
                        TVSwitchRowCheckmark()
                    }
                }
            }
            .buttonStyle(TVSettingsRowButtonStyle())
            .modifier(TVSwitchRowActiveState(isActive: isActive))
        }

        private var subtitle: Text {
            if memberNames.count >= 2 {
                return Text(verbatim: memberNames.formatted(.list(type: .and)))
            }
            return Text(
                "Choose playlists to combine in Settings",
                comment: "Subtitle of the Combined row in the tvOS quick-switch modal while fewer than two playlists are combined"
            )
        }
    }

    /// A full-width profile row: avatar and name, with a checkmark on the active
    /// one.
    struct TVProfileSwitchRow: View {
        let profile: UserProfile
        let isActive: Bool
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                HStack(spacing: 16) {
                    ProfileAvatarView(profile: profile, size: 44)
                    Text(profile.name)
                    Spacer(minLength: 0)
                    if isActive {
                        TVSwitchRowCheckmark()
                    }
                }
            }
            .buttonStyle(TVSettingsRowButtonStyle())
            .modifier(TVSwitchRowActiveState(isActive: isActive))
        }
    }

    /// Announces the active row as selected. The checkmark alone is invisible to
    /// VoiceOver as state — it reads as another glyph in the label — so it is
    /// hidden and the state is carried by the value and the trait instead.
    private struct TVSwitchRowActiveState: ViewModifier {
        let isActive: Bool

        func body(content: Content) -> some View {
            if isActive {
                content
                    .accessibilityValue(
                        Text(
                            "Active",
                            comment: "Accessibility value on the playlist or profile row that is currently in use"
                        )
                    )
                    .accessibilityAddTraits(.isSelected)
            } else {
                content
            }
        }
    }

    /// The active marker.
    private struct TVSwitchRowCheckmark: View {
        var body: some View {
            TVSwitchRowGlyph(systemName: "checkmark")
        }
    }

    /// A trailing row glyph. Follows the row's focus treatment the way
    /// `TVSettingsRowButtonStyle` does — a white glyph would vanish into the
    /// focused row's near-white fill. Always explicit, never `.accentColor`:
    /// that resolves to white on tvOS. Without a label it is decoration,
    /// hidden from VoiceOver.
    private struct TVSwitchRowGlyph: View {
        let systemName: String
        var label: Text?
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            let glyph = Image(systemName: systemName)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(isFocused ? .black : .white)
            if let label {
                glyph.accessibilityLabel(label)
            } else {
                glyph.accessibilityHidden(true)
            }
        }
    }

#endif
