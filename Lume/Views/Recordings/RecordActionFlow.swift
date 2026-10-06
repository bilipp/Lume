//
//  RecordActionFlow.swift
//  Lume
//
//  The shared Record / Schedule / Stop flow every recording entry point runs
//  through: the Lume Pro gate, the duration choice for a channel without guide
//  data, and the toast or alert that reports the outcome. A screen installs it
//  once with `.recordActionFlow()`; the views beneath reach it through
//  `@Environment(\.recordChannel)`. Where no flow is installed the action is
//  `nil` and every Record item hides — the Guide preview and Multi-View tiles
//  never get one.
//

import LumeRecorderKit
import SwiftData
import SwiftUI

/// What a channel's Record control shows, or why it opens the paywall.
enum RecordChannelState: Equatable {
    case record
    case stop(Recording)
    /// Paired, but Lume Pro has lapsed: the control carries the crown.
    case locked
}

/// What a guide programme's record action shows.
enum RecordProgrammeState: Equatable {
    case record
    case schedule
    case cancel(Recording)
    case stop(Recording)
    /// Paired, but Lume Pro has lapsed: Record or Schedule Recording behind
    /// the crown.
    case locked(RecordingRequestPlanner.ProgrammeTiming)
}

/// Record / Stop for a channel, handed down by `.recordActionFlow()`.
struct RecordChannelAction: Equatable {
    fileprivate let model: RecordActionFlowModel
    fileprivate let context: ModelContext

    /// `nil` when the channel can't be recorded at all: no paired server, or a
    /// playlist kind without standalone stream URLs. Reads the store, so the
    /// view that calls it follows pairing, Pro and recording changes.
    func channelState(for stream: LiveStream) -> RecordChannelState? {
        let store = model.store
        guard let owner = model.owner(of: stream, in: context),
              store.supportsRecording(owner.sourceType)
        else { return nil }
        guard store.isUnlocked else { return .locked }
        let ref = RecordingSourceRef(playlistID: owner.id, streamID: stream.id)
        // Only a capture running now turns Record into Stop; a schedule for
        // later tonight is cancelled from its programme, not from here.
        return store.activeRecording(forSourceRef: ref).map(RecordChannelState.stop) ?? .record
    }

    /// `nil` when the programme offers no record action: no paired server, a
    /// playlist kind that can't record (or, upcoming, can't schedule), a
    /// programme that has ended, or an upcoming gap with nothing to schedule.
    /// `programme` is `nil` for a gap filler.
    func programmeState(
        for stream: LiveStream,
        programme: RecordingRequestPlanner.Programme?,
        timing: RecordingRequestPlanner.ProgrammeTiming
    ) -> RecordProgrammeState? {
        let store = model.store
        guard let owner = model.owner(of: stream, in: context),
              store.supportsRecording(owner.sourceType)
        else { return nil }
        switch timing {
        case .ended:
            return nil
        case .upcoming:
            guard programme != nil, store.supportsScheduling(owner.sourceType) else { return nil }
        case .live:
            break
        }
        guard store.isUnlocked else { return .locked(timing) }
        let ref = RecordingSourceRef(playlistID: owner.id, streamID: stream.id)
        if let pending = store.pendingRecording(forSourceRef: ref, programme: programme) {
            return store.isCapturing(pending) ? .stop(pending) : .cancel(pending)
        }
        return timing == .live ? .record : .schedule
    }

    func showPaywall() {
        model.showsPaywall = true
    }

    /// Stops the channel's running recording, or records what's on air now.
    func callAsFunction(_ stream: LiveStream) {
        model.toggle(stream, in: context)
    }

    /// Records what the channel is airing now (or asks for a duration without
    /// guide data), leaving any later scheduled recording of it alone.
    func recordAiring(_ stream: LiveStream) {
        model.recordAiring(stream, in: context)
    }

    /// Records the airing `programme` (or asks for a duration without one).
    func record(_ stream: LiveStream, programme: RecordingRequestPlanner.Programme?) {
        model.recordNow(stream, programme: programme, in: context)
    }

    /// Schedules an upcoming `programme`.
    func schedule(_ stream: LiveStream, programme: RecordingRequestPlanner.Programme) {
        model.schedule(stream, programme: programme, in: context)
    }

    /// Cancels a scheduled recording or ends a running one.
    func stop(_ recording: Recording) {
        model.stop(recording)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model === rhs.model && lhs.context === rhs.context
    }
}

extension RecordChannelAction {
    /// The locked state's text cue for a confirmation dialog, which drops the
    /// record item's crown glyph; `nil` in every other state.
    func lockedDialogMessage(for stream: LiveStream) -> Text? {
        channelState(for: stream) == .locked ? Text("Recording requires Lume Pro.") : nil
    }

    #if os(tvOS)
        /// Record / Stop Recording as a VoiceOver custom action, or `nil` when
        /// the channel can't be recorded.
        func accessibilityAction(for stream: LiveStream) -> UIAccessibilityCustomAction? {
            guard let state = channelState(for: stream) else { return nil }
            let name = if case .stop = state {
                String(localized: "Stop Recording")
            } else {
                String(localized: "Record")
            }
            return UIAccessibilityCustomAction(name: name) { _ in
                self(stream)
                return true
            }
        }
    #endif
}

extension EnvironmentValues {
    @Entry var recordChannel: RecordChannelAction?
}

extension View {
    /// Installs the record flow for everything beneath, and keeps the paired
    /// server's recordings fresh while the screen is visible so Record items
    /// can read Stop Recording. `observesWhileVisible: false` leaves refreshing
    /// to the record controls themselves, for a host that is on screen far
    /// longer than its Record items (the player, and the tabs whose channel
    /// menus carry one). `toastPlacement` keeps the toast clear of controls
    /// that sit along the bottom edge (the tvOS transport).
    func recordActionFlow(
        observesWhileVisible: Bool = true,
        toastPlacement: RecordActionToastPlacement = .bottom
    ) -> some View {
        modifier(RecordActionFlowModifier(observesWhileVisible: observesWhileVisible, toastPlacement: toastPlacement))
    }
}

/// Where the flow's toast appears over the screen it is installed on.
enum RecordActionToastPlacement {
    case bottom
    case top
    case topTrailing

    var alignment: Alignment {
        switch self {
        case .bottom: .bottom
        case .top: .top
        case .topTrailing: .topTrailing
        }
    }

    var edge: Edge {
        switch self {
        case .bottom: .bottom
        case .top, .topTrailing: .top
        }
    }

    /// For a flow installed on a sheet's own content. tvOS presents the sheet
    /// as a card floating over the screen; its top-trailing corner is clear of
    /// the card's artwork, title and actions, where a bottom toast covers the
    /// synopsis and sits right over the presenting screen's own toast.
    static var sheet: Self {
        #if os(tvOS)
            .topTrailing
        #else
            .bottom
        #endif
    }
}

// MARK: - Model

/// One finished action, shown briefly over the screen.
struct RecordActionToast: Equatable, Identifiable {
    let id = UUID()
    let message: String
    let systemImage: String
}

/// A failed action, titled by what it tried to do.
struct RecordActionFailure {
    enum Kind {
        case record
        case stop
        case cancel
    }

    let kind: Kind
    let error: RecordingActionError

    var title: LocalizedStringKey {
        switch kind {
        case .record: "Couldn't Record"
        case .stop: "Couldn't Stop Recording"
        case .cancel: "Couldn't Cancel Recording"
        }
    }
}

/// A record-now that needs a duration because nothing is on air.
struct RecordDurationRequest: Identifiable {
    let id = UUID()
    let stream: LiveStream
}

@MainActor
@Observable
final class RecordActionFlowModel {
    var durationRequest: RecordDurationRequest?
    var failure: RecordActionFailure?
    var showsPaywall = false
    var toast: RecordActionToast?

    @ObservationIgnored let store: RecordingServerStore
    /// Stream ids with a request in flight, so a double tap sends one.
    @ObservationIgnored private var inFlight: Set<String> = []
    /// A playlist's id and kind never change, so a lookup made once per
    /// playlist serves every row and every menu after it.
    @ObservationIgnored private var owners: [String: Owner] = [:]

    struct Owner {
        let id: UUID
        let sourceType: PlaylistSourceType
    }

    init(store: RecordingServerStore? = nil) {
        self.store = store ?? .shared
    }

    // MARK: Lookup

    func owner(of stream: LiveStream, in context: ModelContext) -> Owner? {
        // The cache key is read off the id so a hit skips the fetch entirely.
        let key = String(stream.id.prefix(36))
        if let cached = owners[key] { return cached }
        guard let playlist = playlist(for: stream, in: context) else { return nil }
        let owner = Owner(id: playlist.id, sourceType: playlist.sourceType)
        owners[key] = owner
        return owner
    }

    private func playlist(for stream: LiveStream, in context: ModelContext) -> Playlist? {
        PlayerContentLookup.playlist(for: .live(stream.id), in: context)
    }

    /// What the channel is airing right now, from the guide.
    private func airingProgramme(on stream: LiveStream, in context: ModelContext) -> RecordingRequestPlanner.Programme? {
        guard let channelId = stream.epgChannelId, !channelId.isEmpty else { return nil }
        let now = Date()
        var descriptor = FetchDescriptor<EPGListing>(
            predicate: #Predicate { $0.channelId == channelId && $0.end > now && $0.start <= now },
            sortBy: [SortDescriptor(\.start, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor).first).map(RecordingRequestPlanner.Programme.init(listing:))
    }

    // MARK: Actions

    func toggle(_ stream: LiveStream, in context: ModelContext) {
        guard store.isUnlocked else {
            showsPaywall = true
            return
        }
        guard let playlist = playlist(for: stream, in: context) else { return }
        if let running = store.activeRecording(for: stream, in: playlist) {
            stop(running)
        } else {
            recordNow(stream, playlist: playlist, programme: airingProgramme(on: stream, in: context))
        }
    }

    func recordAiring(_ stream: LiveStream, in context: ModelContext) {
        guard store.isUnlocked else {
            showsPaywall = true
            return
        }
        guard let playlist = playlist(for: stream, in: context) else { return }
        recordNow(stream, playlist: playlist, programme: airingProgramme(on: stream, in: context))
    }

    func recordNow(
        _ stream: LiveStream,
        programme: RecordingRequestPlanner.Programme?,
        duration: RecordingRequestPlanner.FallbackDuration? = nil,
        in context: ModelContext
    ) {
        guard let playlist = playlist(for: stream, in: context) else { return }
        recordNow(stream, playlist: playlist, programme: programme, duration: duration)
    }

    private func recordNow(
        _ stream: LiveStream,
        playlist: Playlist,
        programme: RecordingRequestPlanner.Programme?,
        duration: RecordingRequestPlanner.FallbackDuration? = nil
    ) {
        run(stream) { [store] () async throws(RecordingActionError) in
            let recording = try await store.recordNow(
                stream: stream, playlist: playlist, programme: programme, duration: duration
            )
            return RecordActionToast(
                message: String(localized: "Recording “\(recording.title)”"),
                systemImage: "record.circle"
            )
        } onDurationRequired: { [weak self] in
            self?.durationRequest = RecordDurationRequest(stream: stream)
        }
    }

    func schedule(_ stream: LiveStream, programme: RecordingRequestPlanner.Programme, in context: ModelContext) {
        guard let playlist = playlist(for: stream, in: context) else { return }
        run(stream) { [store] () async throws(RecordingActionError) in
            let recording = try await store.schedule(stream: stream, playlist: playlist, programme: programme)
            return RecordActionToast(
                message: String(localized: "Scheduled “\(recording.title)”"),
                systemImage: "calendar.badge.clock"
            )
        }
    }

    func stop(_ recording: Recording) {
        let id = recording.id
        let isCancel = !store.isCapturing(recording)
        run(key: id.uuidString, failure: isCancel ? .cancel : .stop) { [store] () async throws(RecordingActionError) in
            let stopped = try await store.stop(id: id)
            let message = isCancel
                ? String(localized: "Cancelled “\(stopped.title)”")
                : String(localized: "Stopped recording “\(stopped.title)”")
            return RecordActionToast(message: message, systemImage: "stop.circle")
        }
    }

    func chooseDuration(_ duration: RecordingRequestPlanner.FallbackDuration, for request: RecordDurationRequest, in context: ModelContext) {
        durationRequest = nil
        recordNow(request.stream, programme: nil, duration: duration, in: context)
    }

    private func run(
        _ stream: LiveStream,
        _ action: @escaping () async throws(RecordingActionError) -> RecordActionToast,
        onDurationRequired: (() -> Void)? = nil
    ) {
        run(key: stream.id, failure: .record, action, onDurationRequired: onDurationRequired)
    }

    private func run(
        key: String,
        failure kind: RecordActionFailure.Kind,
        _ action: @escaping () async throws(RecordingActionError) -> RecordActionToast,
        onDurationRequired: (() -> Void)? = nil
    ) {
        guard inFlight.insert(key).inserted else { return }
        Task {
            defer { inFlight.remove(key) }
            do throws(RecordingActionError) {
                let toast = try await action()
                self.toast = toast
                AccessibilityNotification.Announcement(toast.message).post()
            } catch .premiumRequired {
                showsPaywall = true
            } catch .durationRequired {
                onDurationRequired?()
            } catch .server(.cancelled) {
                // Superseded; nothing to report.
            } catch {
                failure = RecordActionFailure(kind: kind, error: error)
            }
        }
    }
}

// MARK: - Modifier

private struct RecordActionFlowModifier: ViewModifier {
    let observesWhileVisible: Bool
    let toastPlacement: RecordActionToastPlacement
    @State private var model = RecordActionFlowModel()
    @Environment(\.modelContext) private var modelContext

    func body(content: Content) -> some View {
        let store = model.store
        content
            .environment(\.recordChannel, RecordChannelAction(model: model, context: modelContext))
            // Only while a Record item could actually show.
            .observesRecordingServerWhileVisible(isActive: observesWhileVisible && store.isPaired && store.isUnlocked)
            .confirmationDialog(
                "Record for How Long?",
                isPresented: durationDialogPresented,
                titleVisibility: .visible,
                presenting: model.durationRequest
            ) { request in
                ForEach(RecordingRequestPlanner.FallbackDuration.allCases) { duration in
                    Button(duration.label) {
                        model.chooseDuration(duration, for: request, in: modelContext)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("There's no guide information for this channel.")
            }
            .alert(
                model.failure?.title ?? "Couldn't Record",
                isPresented: errorPresented,
                presenting: model.failure
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { failure in
                Text(failure.error.localizedDescription)
            }
            .paywall(isPresented: $model.showsPaywall, highlight: .recordingServer)
            .overlay(alignment: toastPlacement.alignment) {
                RecordActionToastView(model: model, placement: toastPlacement)
            }
    }

    private var durationDialogPresented: Binding<Bool> {
        Binding(
            get: { model.durationRequest != nil },
            set: { if !$0 { model.durationRequest = nil } }
        )
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { model.failure != nil },
            set: { if !$0 { model.failure = nil } }
        )
    }
}

/// Reads the toast in its own body, so a toast coming and going doesn't
/// re-render the screen the flow is attached to.
private struct RecordActionToastView: View {
    let model: RecordActionFlowModel
    let placement: RecordActionToastPlacement

    var body: some View {
        ZStack {
            if let toast = model.toast {
                Label(toast.message, systemImage: toast.systemImage)
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(radius: 8)
                    .padding(.horizontal, 16)
                    .padding(placement.edge == .top ? .top : .bottom, 24)
                    .transition(.move(edge: placement.edge).combined(with: .opacity))
                    .task(id: toast.id) {
                        try? await Task.sleep(for: .seconds(3))
                        guard !Task.isCancelled, model.toast?.id == toast.id else { return }
                        model.toast = nil
                    }
            }
        }
        .animation(.easeOut(duration: 0.25), value: model.toast)
        .allowsHitTesting(false)
    }
}

extension RecordingRequestPlanner.FallbackDuration {
    var label: LocalizedStringKey {
        switch self {
        case .thirtyMinutes: "30 Minutes"
        case .oneHour: "1 Hour"
        case .twoHours: "2 Hours"
        }
    }
}
