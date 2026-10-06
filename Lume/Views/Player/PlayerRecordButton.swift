//
//  PlayerRecordButton.swift
//  Lume
//
//  The in-player Record control shared by the KSPlayer, VLCKit, AVPlayer and
//  LumeEngine overlays on iOS, macOS and visionOS (tvOS draws its own button
//  over the same state, in `TVPlayerControlsOverlay+Record.swift`). It reads
//  only the recording store and the channel the player host resolved
//  (`playerRecordStream`), and hands every action to the record flow the host
//  installs — never the playback clock, never SwiftData.
//

import LumeRecorderKit
import SwiftUI

extension EnvironmentValues {
    /// The live channel the player's Record control acts on, resolved once per
    /// stream by `FullScreenPlayerView`; `nil` when the stream isn't one.
    @Entry var playerRecordStream: LiveStream?
}

extension RecordChannelAction {
    /// `nil` hides the player's Record control — also while `stream` is still
    /// the previous channel's, before the host resolves the new one.
    func playerState(for stream: LiveStream, playing media: PlayableMedia) -> RecordChannelState? {
        guard media.isLive, media.contentRef == .live(stream.id) else { return nil }
        return channelState(for: stream)
    }

    func perform(_ state: RecordChannelState, on stream: LiveStream) {
        switch state {
        case .record:
            recordAiring(stream)
        case let .stop(recording):
            stop(recording)
        case .locked:
            showPaywall()
        }
    }
}

/// How the player's Record control draws each state.
extension RecordChannelState {
    var playerSystemImage: String {
        switch self {
        case .record: "record.circle"
        case .stop: "record.circle.fill"
        case .locked: "crown"
        }
    }

    var isRecording: Bool {
        if case .stop = self { return true }
        return false
    }

    var accessibilityLabel: LocalizedStringKey {
        switch self {
        case .record, .locked: "Record"
        case .stop: "Stop Recording"
        }
    }
}

struct PlayerRecordButton: View {
    let media: PlayableMedia
    var onResetHideTimer: () -> Void

    @Environment(\.playerRecordStream) private var stream
    @Environment(\.recordChannel) private var recordChannel

    var body: some View {
        if let stream, let recordChannel, let state = recordChannel.playerState(for: stream, playing: media) {
            Button {
                recordChannel.perform(state, on: stream)
                onResetHideTimer()
            } label: {
                Image(systemName: state.playerSystemImage)
                    .symbolReplaceTransition(value: state.playerSystemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(state.isRecording ? Color.red : Color.white)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(state.accessibilityLabel)
            .observesRecordingServerWhileVisible(isActive: RecordingServerStore.shared.isUnlocked)
        }
    }
}

extension View {
    /// Polls the paired server while this view is on screen and `isActive`.
    /// Balanced: every begin is matched by one end, however often either
    /// condition flips.
    func observesRecordingServerWhileVisible(isActive: Bool) -> some View {
        modifier(RecordingServerObservation(isActive: isActive))
    }
}

private struct RecordingServerObservation: ViewModifier {
    let isActive: Bool
    @State private var isVisible = false
    @State private var isObserving = false

    private var store: RecordingServerStore {
        .shared
    }

    func body(content: Content) -> some View {
        content
            .onAppear {
                isVisible = true
                setObserving(isActive)
            }
            .onDisappear {
                isVisible = false
                setObserving(false)
            }
            .onChange(of: isActive) { _, active in setObserving(isVisible && active) }
    }

    private func setObserving(_ wanted: Bool) {
        guard wanted != isObserving else { return }
        isObserving = wanted
        if wanted {
            store.beginObserving()
        } else {
            store.endObserving()
        }
    }
}
