//
//  TVPlayerControlsOverlay+Record.swift
//  Lume
//
//  The tvOS player's Record control: the rightmost button of the trailing row
//  ([Audio] [Subtitles] [Favorite] [Record]), live channels only. It shares
//  `RecordChannelState` and the host's record flow with the other
//  platforms' `PlayerRecordButton`, and never reads the playback clock.
//

#if os(tvOS)

    import SwiftUI

    extension TVPlayerControlsOverlay {
        var recordButton: some View {
            TVPlayerRecordButton(media: media, focus: $focus, onResetHideTimer: onResetHideTimer)
        }
    }

    extension View {
        /// Hands focus to Favorite when the Record button leaves the row while
        /// it holds focus — surfing to a channel that can't record removes it,
        /// and a focused view that vanishes leaves focus orphaned. Attached to
        /// the trailing row, which outlives the button; reads the same state
        /// the button does, so the row itself never re-renders on a poll.
        func tvPlayerRecordFocusHandoff(
            media: PlayableMedia,
            focus: FocusState<TVPlayerFocus?>.Binding
        ) -> some View {
            modifier(TVPlayerRecordFocusHandoff(media: media, focus: focus))
        }
    }

    private struct TVPlayerRecordFocusHandoff: ViewModifier {
        let media: PlayableMedia
        var focus: FocusState<TVPlayerFocus?>.Binding

        @Environment(\.playerRecordStream) private var stream
        @Environment(\.recordChannel) private var recordChannel

        private var showsRecordButton: Bool {
            guard let stream, let recordChannel else { return false }
            return recordChannel.playerState(for: stream, playing: media) != nil
        }

        func body(content: Content) -> some View {
            content
                .onChange(of: showsRecordButton) { wasShown, isShown in
                    guard wasShown, !isShown, focus.wrappedValue == .record else { return }
                    // Deferred: a focus write inside the update that removes
                    // the focused view is dropped by the focus engine.
                    Task { @MainActor in focus.wrappedValue = .favorite }
                }
        }
    }

    private struct TVPlayerRecordButton: View {
        let media: PlayableMedia
        var focus: FocusState<TVPlayerFocus?>.Binding
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
                }
                .buttonStyle(TVPlayerRecordButtonStyle(isRecording: state.isRecording))
                .focused(focus, equals: .record)
                .accessibilityLabel(state.accessibilityLabel)
                .observesRecordingServerWhileVisible(isActive: RecordingServerStore.shared.isUnlocked)
            }
        }
    }

    /// `TVPlayerCircleButtonStyle`, except that a running recording swaps the
    /// glass for a solid red disc with a white glyph, focused or not.
    private struct TVPlayerRecordButtonStyle: ButtonStyle {
        let isRecording: Bool

        func makeBody(configuration: Configuration) -> some View {
            if isRecording {
                RecordingBody(configuration: configuration)
            } else {
                TVPlayerCircleButtonStyle().makeBody(configuration: configuration)
            }
        }

        struct RecordingBody: View {
            let configuration: ButtonStyleConfiguration
            @Environment(\.isFocused) private var isFocused

            var body: some View {
                let pressed = configuration.isPressed
                configuration.label
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 60, height: 60)
                    .background(Circle().fill(Color.red))
                    .scaleEffect(pressed ? 1.05 : (isFocused ? 1.14 : 1.0))
                    .shadow(color: .black.opacity(isFocused ? 0.4 : 0), radius: 16, y: 8)
                    .animation(.easeOut(duration: 0.18), value: isFocused)
                    .animation(.easeOut(duration: 0.1), value: pressed)
            }
        }
    }

#endif
