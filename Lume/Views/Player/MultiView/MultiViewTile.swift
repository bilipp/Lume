//
//  MultiViewTile.swift
//  Lume
//
//  One cell of the Multi-View grid: the tile's stream plus its chrome (channel
//  name, an indicator for the tile carrying the audio, and the change/remove
//  actions). An empty tile is a button that opens the channel picker.
//
//  Interaction differs by input, not by feature: with a pointer or touch the
//  tile is tapped to take the audio and carries a "…" menu, while on tvOS the
//  tile itself is the focusable button and the same actions hang off a long
//  press — a focusable control nested inside a focusable button would be
//  unreachable with the remote.
//

import SwiftUI

struct MultiViewTile: View {
    let slot: MultiViewSlot
    let hasAudio: Bool
    /// Owned by `MultiViewScreen` so it can hand focus to a tile on open — tvOS
    /// otherwise lands focus on the close button, the first focusable in the
    /// tree. Drives the focus border only, never a size or a position, so the
    /// focus engine's animated context has no layout to fight with.
    @FocusState.Binding var focusedTile: MultiViewSlot.ID?
    /// Whether the tile's own chrome — the channel caption and, off tvOS, the
    /// "…" button — is showing. It rides with the screen's controls, so a
    /// settled grid is nothing but video. tvOS has no "…": the actions hang off
    /// a long press.
    var showsControls = true
    /// Supplied only for a tile that is off the stage in the spotlight layout.
    /// Selecting such a tile swaps it onto the stage — moving the audio there is
    /// a side effect of that, not the point — so its presence is also what tells
    /// the tile it is a rail tile rather than a cell of a uniform grid.
    var onPromote: (() -> Void)?
    var onFocusAudio: () -> Void
    var onPickChannel: () -> Void
    var onRemove: () -> Void

    private var isTileFocused: Bool {
        focusedTile == slot.id
    }

    /// What a tap — or a Select press — on the tile does.
    private var primaryAction: () -> Void {
        onPromote ?? onFocusAudio
    }

    private var cornerRadius: CGFloat {
        #if os(tvOS)
            14
        #else
            10
        #endif
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: borderWidth)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint(accessibilityHint)
    }

    /// White rather than the accent colour: the accent resolves to white on tvOS
    /// anyway, and the speaker glyph is what actually names the audible tile.
    private var borderColor: Color {
        #if os(tvOS)
            if isTileFocused {
                return .white
            }
        #endif
        return hasAudio ? .white.opacity(0.9) : .white.opacity(0.12)
    }

    private var borderWidth: CGFloat {
        #if os(tvOS)
            if isTileFocused {
                return 5
            }
        #endif
        return hasAudio ? 2 : 1
    }

    private var accessibilityLabel: Text {
        guard let media = slot.media else { return Text("Empty tile") }
        return hasAudio
            ? Text("\(media.title), playing audio")
            : Text("\(media.title), muted")
    }

    /// Only a rail tile needs one: everywhere else the tile's own label already
    /// says what selecting it would change.
    private var accessibilityHint: Text {
        onPromote == nil ? Text(verbatim: "") : Text("Shows this channel in the large tile")
    }

    @ViewBuilder
    private var content: some View {
        if let media = slot.media {
            filledTile(media)
        } else {
            emptyTile
        }
    }

    // MARK: - Filled

    @ViewBuilder
    private func filledTile(_ media: PlayableMedia) -> some View {
        #if os(tvOS)
            Button(action: primaryAction) {
                tileBody(media)
            }
            .buttonStyle(TVCardButtonStyle(focusScale: 1.02))
            .focused($focusedTile, equals: slot.id)
            .contextMenu {
                tileActions
            }
        #else
            ZStack(alignment: .topTrailing) {
                tileBody(media)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: primaryAction)

                Menu {
                    tileActions
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .padding(8)
                .accessibilityLabel("Tile options")
                .opacity(showsControls ? 1 : 0)
                .allowsHitTesting(showsControls)
                .animation(.easeInOut(duration: 0.2), value: showsControls)
            }
        #endif
    }

    private func tileBody(_ media: PlayableMedia) -> some View {
        MultiViewTilePlayer(media: media, isMuted: !hasAudio)
            .overlay(alignment: .bottomLeading) {
                // Removed rather than faded to zero: an `opacity(0)` caption stays
                // in the accessibility tree, so VoiceOver would still announce a
                // caption nobody can see. The tile's own label already carries the
                // channel and its audio state. The transition keeps the fade.
                if showsControls {
                    caption(media)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: showsControls)
    }

    private func caption(_ media: PlayableMedia) -> some View {
        HStack(spacing: 6) {
            Image(systemName: hasAudio ? "speaker.wave.2.fill" : "speaker.slash.fill")
                .font(.caption2)
                .foregroundStyle(hasAudio ? .white : .white.opacity(0.5))
            Text(media.title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.black.opacity(0.55), in: Capsule())
        .padding(10)
    }

    @ViewBuilder
    private var tileActions: some View {
        // A rail tile gets the promotion instead of "Play Audio Here": on stage
        // it will be audible anyway, and offering both would let the viewer pull
        // the sound off the big tile — the one thing the spotlight promises not
        // to do.
        if let onPromote {
            Button {
                onPromote()
            } label: {
                Label("Show Large", systemImage: "rectangle.inset.filled")
            }
        } else if !hasAudio {
            Button {
                onFocusAudio()
            } label: {
                Label("Play Audio Here", systemImage: "speaker.wave.2")
            }
        }
        Button {
            onPickChannel()
        } label: {
            Label("Change Channel", systemImage: "arrow.left.arrow.right")
        }
        Button(role: .destructive) {
            onRemove()
        } label: {
            Label("Remove", systemImage: "xmark")
        }
    }

    // MARK: - Empty

    private var emptyTile: some View {
        Button(action: onPickChannel) {
            VStack(spacing: 10) {
                Image(systemName: "plus.circle")
                    .font(.title2)
                Text("Add Channel")
                    .font(.subheadline.weight(.medium))
            }
            .foregroundStyle(.white.opacity(0.65))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        #if os(tvOS)
        .buttonStyle(TVCardButtonStyle(focusScale: 1.02))
        .focused($focusedTile, equals: slot.id)
        #else
        .buttonStyle(.plain)
        #endif
    }
}
