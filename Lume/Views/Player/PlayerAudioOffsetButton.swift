//
//  PlayerAudioOffsetButton.swift
//  Lume
//
//  The in-player Audio Delay menu shared by the KSPlayer, VLCKit and
//  AetherEngine overlays on iOS, macOS and visionOS. Shown only while the
//  engine on screen can shift its audio while playing (the host's
//  `PlayerAudioOffsetSession` says which), so AVPlayer and LumeEngine never
//  offer it. The entries are shared with the tvOS overlay's menu.
//

import SwiftData
import SwiftUI

struct PlayerAudioOffsetButton: View {
    var onResetHideTimer: () -> Void

    @Environment(\.playerAudioOffset) private var session

    var body: some View {
        if let session, session.isAdjustable {
            Menu {
                PlayerAudioOffsetMenuItems(session: session, onResetHideTimer: onResetHideTimer)
            } label: {
                Image(systemName: session.effectiveMilliseconds == 0 ? "metronome" : "metronome.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .menuIndicator(.hidden)
            .trackMenuAccessibility(
                "Audio Delay", selected: AudioOffsetPreset.label(session.effectiveMilliseconds), fallback: "Default"
            )
            .help("Audio Delay")
        }
    }
}

/// The Audio Delay menu's entries: the presets, the way back to the
/// provider's default, and saving the session's value as that default.
struct PlayerAudioOffsetMenuItems: View {
    let session: PlayerAudioOffsetSession
    var onResetHideTimer: () -> Void

    @Environment(\.modelContext) private var modelContext

    var body: some View {
        Group {
            Section {
                ForEach(AudioOffsetPreset.values, id: \.self) { milliseconds in
                    Button {
                        session.select(milliseconds)
                        onResetHideTimer()
                    } label: {
                        playerCheckmarkLabel(
                            verbatim: AudioOffsetPreset.label(milliseconds),
                            checked: milliseconds == session.effectiveMilliseconds
                        )
                    }
                }
            }
            if session.hasSessionOverride {
                Section {
                    Button {
                        session.useProviderDefault()
                        onResetHideTimer()
                    } label: {
                        Label {
                            Text("Playlist Default (\(AudioOffsetPreset.label(session.providerMilliseconds)))")
                        } icon: {
                            Image(systemName: "arrow.uturn.backward")
                        }
                    }
                    if session.ownerPlaylistID != nil {
                        Button {
                            session.saveAsProviderDefault(in: modelContext)
                            onResetHideTimer()
                        } label: {
                            Label("Save as Playlist Default", systemImage: "square.and.arrow.down")
                        }
                    }
                }
            }
        }
        .holdsPlayerControls()
    }
}
