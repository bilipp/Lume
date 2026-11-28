//
//  RecordingActions.swift
//  Lume
//
//  What every surface that lists server recordings shares: polling, the
//  stop / cancel / delete confirmation, failures, the paywall and the player.
//  Used by the Recordings library and Sports Replays.
//

import SwiftUI

extension View {
    /// The library's server polling, parental filter, stop / cancel / delete
    /// confirmation, failure alert and paywall. `confirmsOnRows` leaves the
    /// confirmation to each row's `recordingActionConfirmation(_:for:)`.
    func recordingsLibraryActions(_ model: RecordingsLibraryModel, confirmsOnRows: Bool = false) -> some View {
        modifier(RecordingsLibraryActions(model: model, confirmsOnRows: confirmsOnRows))
    }

    /// The stop / cancel / delete confirmation for one row's recording,
    /// anchored to that row. iOS 26 presents a confirmation dialog as a
    /// popover from the view it hangs on, so a library-wide one points at the
    /// top of the list, whichever row asked.
    func recordingActionConfirmation(_ model: RecordingsLibraryModel, for recording: ServerRecording) -> some View {
        modifier(RecordingActionConfirmation(model: model, recordingID: recording.id))
    }

    /// The player for a recording: macOS's single player window, a full
    /// screen cover everywhere else.
    func recordingPlayer(item: Binding<PlayableMedia?>) -> some View {
        modifier(RecordingPlayerPresentation(media: item))
    }
}

private struct RecordingsLibraryActions: ViewModifier {
    @Bindable var model: RecordingsLibraryModel
    let confirmsOnRows: Bool
    @Environment(\.modelContext) private var modelContext
    @Environment(\.contentRestriction) private var restriction

    func body(content: Content) -> some View {
        content
            // Not while the player covers the library: a `fullScreenCover`
            // doesn't deliver `onDisappear`.
            .observesRecordingServerWhileVisible(isActive: model.playingMedia == nil)
            .onChange(of: RecordingsLibraryParentalKey(recordings: model.store.recordings, restriction: restriction), initial: true) {
                model.updateHiddenIDs(restriction: restriction, context: modelContext)
            }
            .modifier(RecordingActionConfirmation(model: model, recordingID: nil, isEnabled: !confirmsOnRows))
            .alert(
                model.failure?.title ?? "",
                isPresented: failurePresented,
                presenting: model.failure
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { failure in
                Text(failure.message)
            }
            .paywall(isPresented: $model.showingPaywall, highlight: .recordingServer)
    }

    private var failurePresented: Binding<Bool> {
        Binding(
            get: { model.failure != nil },
            set: { if !$0 { model.failure = nil } }
        )
    }
}

/// Confirms the pending stop, cancel or delete: every row's when
/// `recordingID` is `nil`, else only that recording's.
private struct RecordingActionConfirmation: ViewModifier {
    let model: RecordingsLibraryModel
    let recordingID: RecordingID?
    var isEnabled = true

    private var action: RecordingLibraryAction? {
        guard isEnabled, let pending = model.pendingAction else { return nil }
        guard let recordingID else { return pending }
        return pending.recording.id == recordingID ? pending : nil
    }

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                action?.title ?? "",
                isPresented: isPresented,
                titleVisibility: .visible,
                presenting: action
            ) { action in
                Button(action.confirmLabel, role: .destructive) {
                    model.perform(action)
                }
                Button("Cancel", role: .cancel) {}
            } message: { action in
                Text(action.message)
            }
    }

    private var isPresented: Binding<Bool> {
        Binding(
            get: { action != nil },
            // Only this dialog's own action: another row may have taken over.
            set: { if !$0, action != nil { model.pendingAction = nil } }
        )
    }
}

private struct RecordingPlayerPresentation: ViewModifier {
    @Binding var media: PlayableMedia?
    #if os(macOS)
        @Environment(\.openWindow) private var openWindow
    #endif

    func body(content: Content) -> some View {
        #if os(macOS)
            content
                .onChange(of: media) { _, newValue in
                    guard let newValue else { return }
                    MacPlayerWindowRouter.shared.play(newValue, using: openWindow)
                    media = nil
                }
        #else
            content
                .fullScreenCover(item: $media) { media in
                    FullScreenPlayerView(media: media)
                }
        #endif
    }
}
