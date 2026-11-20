//
//  StreamInfoCaption.swift
//  Lume
//
//  The opt-in stream-information caption shown above the title in the player
//  chrome on iOS / iPadOS / macOS / visionOS: the programme line, and at the
//  Advanced level a row of glass chips (`StreamInfoChipRow`).
//
//  Ungated on purpose: one leaf mounted by every engine's controls overlay, so
//  the four near-identical title blocks can never drift. It rides the host's
//  existing visibility and auto-hide — there is no new button, panel or gesture
//  competing with the tap-to-toggle, the scrubber drag and the interactive
//  dismiss already on the video surface.
//
//  It owns its data as well as its settings: the host passes only what it
//  already has, and the per-stream resolve hangs off the same `isEnabled` gate
//  that decides whether anything renders, so a viewer with the caption off pays
//  for no fetch at all.
//
//  MultiView needs no suppression: `MultiViewKSTile` and its siblings build
//  their own surfaces and never instantiate a `*ControlsOverlay`
//  (`grep -rn ControlsOverlay Lume/Views/Player/MultiView/` returns nothing).
//

import SwiftData
import SwiftUI

struct StreamInfoCaption: View {
    let media: PlayableMedia
    let videoInfo: PlayerVideoInfo?
    let engine: PlayerEngineKind
    /// The engine the Advanced chips pull audio and bitrate from.
    let sampler: (any PlayerStreamSampling)?

    @Environment(\.modelContext) private var modelContext
    /// Programme-level context, resolved once per stream. `nil` until that
    /// resolve lands, which collapses the programme line rather than flashing
    /// a partial one.
    @State private var details: StreamInfoDetails?

    /// Both preferences live here and nowhere else. Safe as `@AppStorage`
    /// because this is a leaf — the player tree above it never re-renders on a
    /// toggle. Hoisting either one into the engine view or `FullScreenPlayerView`
    /// would rebuild the whole player on every change.
    @AppStorage(PlayerSettings.StreamInfo.enabledKey)
    private var isEnabled = PlayerSettings.StreamInfo.enabledDefault
    @AppStorage(PlayerSettings.StreamInfo.detailLevelKey)
    private var detailLevelRaw = PlayerSettings.StreamInfo.detailLevelDefault.rawValue

    var body: some View {
        if isEnabled {
            caption
                .task(id: media.id) {
                    details = nil
                    // The overlay is mounted only while the controls are up, so
                    // this re-runs on the next reveal — which the caption needs
                    // anyway to be seen after a mid-session toggle.
                    details = await PlayerStreamInfo.resolveDetached(
                        for: media.contentRef,
                        container: modelContext.container
                    )
                }
        }
    }

    // MARK: - Caption

    private var caption: some View {
        let info = snapshot
        return VStack(alignment: .leading, spacing: 6) {
            if let programme = info.programmeCaption {
                Text(programme)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .accessibilityLabel(info.spokenProgrammeParts.joined(separator: ", "))
            }
            if detailLevel == .advanced {
                StreamInfoChipRow(snapshot: info, sampler: sampler)
                    .padding(.bottom, 2)
            } else if info.programmeCaption == nil {
                // `.task` never fires on an empty stack; zero-size so the title
                // block's spacing is unchanged while there is nothing to show.
                Color.clear.frame(width: 0, height: 0)
            }
        }
        // Clamped rather than unbounded: this rides the bottom control column
        // above the transport, so at the top AX sizes an unclamped caption
        // grows until it crowds the title and the scrubber off the video.
        // VoiceOver reads the full labels regardless of the rendered size.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    // MARK: - Derived

    private var detailLevel: StreamInfoDetailLevel {
        StreamInfoDetailLevel(rawValue: detailLevelRaw) ?? PlayerSettings.StreamInfo.detailLevelDefault
    }

    private var snapshot: PlayerInfoSnapshot {
        PlayerInfoSnapshot(
            media: media,
            details: details,
            videoInfo: videoInfo,
            engine: engine,
            detailLevel: detailLevel
        )
    }
}
