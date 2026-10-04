//
//  RecordingsLibrary.swift
//  Lume
//
//  What every platform's recordings library shares: how the server's
//  recordings fall into sections, how a row describes one, which ones
//  parental controls hide from the active profile, and the play / stop /
//  delete actions with their confirmations, failures and empty states.
//

import Foundation
import LumeRecorderKit
import SwiftData
import SwiftUI

enum RecordingsLibrarySection: CaseIterable, Identifiable {
    case inProgress
    case scheduled
    case completed
    /// Failed, cancelled, and any status this build doesn't know.
    case failed

    var id: Self {
        self
    }

    var title: LocalizedStringKey {
        switch self {
        // Its own key: Downloads' "In Progress" reads "watching" in ja/ko.
        case .inProgress: "Recording Now"
        case .scheduled: "Scheduled"
        case .completed: "Completed"
        // Failed and cancelled recordings alike have nothing to play.
        case .failed: "Not Recorded"
        }
    }

    init(status: RecordingStatus) {
        switch status {
        case .recording: self = .inProgress
        case .scheduled: self = .scheduled
        case .completed: self = .completed
        case .failed, .cancelled, .unknown: self = .failed
        }
    }
}

struct RecordingsLibraryGroup: Identifiable {
    let section: RecordingsLibrarySection
    let recordings: [Recording]

    var id: RecordingsLibrarySection {
        section
    }
}

enum RecordingsLibrary {
    /// Non-empty sections in display order. Running and scheduled recordings
    /// read soonest first; finished ones newest first.
    static func groups(_ recordings: [Recording]) -> [RecordingsLibraryGroup] {
        let bySection = Dictionary(grouping: recordings) { RecordingsLibrarySection(status: $0.status) }
        return RecordingsLibrarySection.allCases.compactMap { section in
            guard let items = bySection[section], !items.isEmpty else { return nil }
            let sorted = switch section {
            case .inProgress, .scheduled: items.sorted { $0.start < $1.start }
            case .completed, .failed: items.sorted { $0.start > $1.start }
            }
            return RecordingsLibraryGroup(section: section, recordings: sorted)
        }
    }

    /// Recordings of channels in a category restricted for the active profile.
    /// A recording whose channel isn't in the catalog stays visible.
    static func hiddenRecordingIDs(
        _ recordings: [Recording],
        restriction: ContentRestriction,
        context: ModelContext
    ) -> Set<UUID> {
        guard restriction.isActive, !restriction.restrictedCategoryIDs.isEmpty else { return [] }
        let streamIDs = Array(Set(recordings.compactMap {
            $0.sourceRef.flatMap(RecordingSourceRef.init(rawValue:))?.streamID
        }))
        guard !streamIDs.isEmpty else { return [] }
        var descriptor = FetchDescriptor<LiveStream>(predicate: #Predicate { streamIDs.contains($0.id) })
        descriptor.propertiesToFetch = [\.categoryId]
        let streams = (try? context.fetch(descriptor)) ?? []
        let categoryByStream = Dictionary(streams.map { ($0.id, $0.categoryId) }, uniquingKeysWith: { first, _ in first })
        let visible = RecordingRequestPlanner.visibleRecordings(recordings, restriction: restriction) { ref in
            categoryByStream[ref.streamID] ?? nil
        }
        return Set(recordings.map(\.id)).subtracting(visible.map(\.id))
    }
}

// MARK: - Row text

extension Recording {
    /// Running, finished, or failed after capturing something: the server has
    /// segments to hand out. Anything else gets 409 not_playable.
    var isPlayable: Bool {
        switch status {
        case .recording, .completed: true
        case .failed: (sizeBytes ?? 0) > 0 || (durationSeconds ?? 0) > 0
        case .scheduled, .cancelled, .unknown: false
        }
    }

    var timeRangeText: String {
        displayedTimeRange.formatted(date: .abbreviated, time: .shortened)
    }

    /// The planned window while a recording is scheduled or running. Once it
    /// has ended, the span it actually captured: one stopped early ends where
    /// it stopped, not at the programme's end. A finished recording that never
    /// started (cancelled or missed) keeps the planned window.
    var displayedTimeRange: Range<Date> {
        switch status {
        case .completed, .failed, .cancelled:
            if let startedAt, let finishedAt, finishedAt > startedAt {
                return startedAt ..< finishedAt
            }
        case .scheduled, .recording, .unknown:
            break
        }
        return start ..< max(end, start)
    }

    /// Recorded length and size once there is media, else the planned length.
    var detailText: String? {
        var parts: [String] = []
        if let seconds = durationSeconds, seconds > 0 {
            parts.append(Self.durationText(seconds))
        } else if status.isPending, end > start {
            parts.append(Self.durationText(end.timeIntervalSince(start)))
        }
        if let size = sizeBytes, size > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var statusText: String {
        switch status {
        case .scheduled: String(localized: "Scheduled")
        case .recording: String(localized: "Recording")
        case .completed: String(localized: "Completed")
        case .failed: String(localized: "Failed")
        case .cancelled: String(localized: "Cancelled")
        case .unknown: String(localized: "Unknown Status")
        }
    }

    var statusSystemImage: String {
        switch status {
        case .scheduled: "calendar.badge.clock"
        case .recording: "record.circle"
        case .completed: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        case .cancelled: "xmark.circle"
        case .unknown: "questionmark.circle"
        }
    }

    var statusColor: Color {
        switch status {
        case .recording, .failed: .red
        case .scheduled: .orange
        case .completed: .green
        case .cancelled, .unknown: .secondary
        }
    }

    /// Why a recording failed, in words. The server's reasons are
    /// machine-readable codes; unknown ones fall back to a generic line.
    var failureText: String? {
        guard status == .failed else { return nil }
        let reason = failureReason ?? ""
        if reason == LumeRecorderErrorCode.concurrencyLimit {
            return String(localized: "The server was already recording as many streams as it allows.")
        } else if reason == LumeRecorderErrorCode.insufficientStorage {
            return String(localized: "The server ran out of disk space.")
        } else if reason == "missed" {
            return String(localized: "The server wasn't running when the recording was due to start.")
        } else if reason == "interrupted" {
            return String(localized: "The recording was interrupted.")
        } else if reason.hasPrefix("no_segments") || reason.hasPrefix("source_unavailable") {
            return String(localized: "The server couldn't capture any video from the stream.")
        }
        return String(localized: "The recording failed.")
    }

    private static func durationText(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }
}

// MARK: - Library actions

/// A stop, cancel or delete waiting for confirmation.
struct RecordingLibraryAction: Identifiable {
    enum Kind {
        case stop
        case cancel
        case delete
    }

    let kind: Kind
    let recording: Recording

    var id: String {
        "\(kind)-\(recording.id.uuidString)"
    }

    var isDelete: Bool {
        kind == .delete
    }

    /// Stop vs Cancel follows `RecordingRequestPlanner.isCapturing`, like the
    /// channel menu, EPG detail and player: a schedule whose window has opened
    /// is already capturing, so it reads Stop here too.
    static func actions(for recording: Recording, now: Date = .now) -> [Self] {
        switch recording.status {
        case .recording, .scheduled:
            let primary: Kind = RecordingRequestPlanner.isCapturing(recording, now: now) ? .stop : .cancel
            return [Self(kind: primary, recording: recording), Self(kind: .delete, recording: recording)]
        case .completed, .failed, .cancelled, .unknown:
            return [Self(kind: .delete, recording: recording)]
        }
    }

    var menuLabel: String {
        switch kind {
        case .stop: String(localized: "Stop Recording")
        case .cancel: String(localized: "Cancel Recording")
        case .delete: String(localized: "Delete")
        }
    }

    var systemImage: String {
        switch kind {
        case .stop, .cancel: "stop.circle"
        case .delete: "trash"
        }
    }

    var tint: Color {
        switch kind {
        case .stop, .cancel: .orange
        case .delete: .red
        }
    }

    var title: String {
        switch kind {
        case .stop: String(localized: "Stop this recording?")
        case .cancel: String(localized: "Cancel this recording?")
        case .delete: String(localized: "Delete this recording?")
        }
    }

    var confirmLabel: String {
        switch kind {
        case .stop: String(localized: "Stop Recording")
        case .cancel: String(localized: "Cancel Recording")
        case .delete: String(localized: "Delete")
        }
    }

    var message: String {
        switch kind {
        case .stop:
            String(localized: "“\(recording.title)” stops recording now. What's been recorded so far is kept.")
        case .cancel:
            String(localized: "“\(recording.title)” won't be recorded.")
        case .delete:
            String(localized: "“\(recording.title)” and its video are removed from the recording server for all your devices.")
        }
    }
}

struct RecordingLibraryFailure: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// What the parental filter depends on, so it reruns only when that changes.
struct RecordingsLibraryParentalKey: Equatable {
    let refs: [String?]
    let restriction: ContentRestriction

    init(recordings: [Recording], restriction: ContentRestriction) {
        refs = recordings.map(\.sourceRef)
        self.restriction = restriction
    }
}

// MARK: - Library model

@MainActor
@Observable
final class RecordingsLibraryModel {
    var playingMedia: PlayableMedia?
    var pendingAction: RecordingLibraryAction?
    var failure: RecordingLibraryFailure?
    var showingPaywall = false
    /// The recording whose playback grant is being requested.
    private(set) var loadingID: UUID?
    private(set) var hiddenIDs: Set<UUID> = []

    @ObservationIgnored let store: RecordingServerStore

    init(store: RecordingServerStore? = nil) {
        self.store = store ?? .shared
    }

    var visibleRecordings: [Recording] {
        hiddenIDs.isEmpty ? store.recordings : store.recordings.filter { !hiddenIDs.contains($0.id) }
    }

    func updateHiddenIDs(restriction: ContentRestriction, context: ModelContext) {
        hiddenIDs = RecordingsLibrary.hiddenRecordingIDs(store.recordings, restriction: restriction, context: context)
    }

    func play(_ recording: Recording) {
        guard loadingID == nil else { return }
        loadingID = recording.id
        Task {
            defer { loadingID = nil }
            do throws(RecordingActionError) {
                playingMedia = try await store.playbackMedia(for: recording)
            } catch .premiumRequired {
                showingPaywall = true
            } catch .server(.cancelled) {
                // Superseded; nothing to report.
            } catch {
                failure = RecordingLibraryFailure(
                    title: String(localized: "Couldn't Play Recording"),
                    message: error.localizedDescription
                )
            }
        }
    }

    func perform(_ action: RecordingLibraryAction) {
        let id = action.recording.id
        let isDelete = action.isDelete
        Task {
            do throws(RecordingActionError) {
                if isDelete {
                    try await store.delete(id: id)
                } else {
                    try await store.stop(id: id)
                }
            } catch .premiumRequired {
                showingPaywall = true
            } catch .server(.cancelled) {
                // Superseded; nothing to report.
            } catch {
                failure = RecordingLibraryFailure(
                    title: String(localized: "Couldn't Update Recording"),
                    message: error.localizedDescription
                )
            }
        }
    }
}

// MARK: - Empty state

struct RecordingsLibraryEmptyState: View {
    let store: RecordingServerStore

    var body: some View {
        if !store.isPaired {
            ContentUnavailableView(
                "No Recording Server",
                systemImage: "record.circle",
                description: Text("Pair a recording server in Settings to record live TV.")
            )
        } else if !store.isUnlocked {
            ContentUnavailableView(
                "Recordings",
                systemImage: "crown",
                description: Text("Recording requires Lume Pro.")
            )
        } else if case let .unreachable(error) = store.reachability {
            ContentUnavailableView {
                Label("Recording Server Unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error.localizedDescription)
            } actions: {
                Button("Try Again") {
                    Task { await store.refresh() }
                }
                .disabled(store.isRefreshing)
            }
        } else if store.reachability == .unknown {
            ProgressView()
        } else {
            ContentUnavailableView(
                "No Recordings",
                systemImage: "recordingtape",
                description: Text("Record a channel from its menu, the guide or the player. Recordings appear here.")
            )
        }
    }
}

// MARK: - Actions

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
    func recordingActionConfirmation(_ model: RecordingsLibraryModel, for recording: Recording) -> some View {
        modifier(RecordingActionConfirmation(model: model, recordingID: recording.id))
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
    let recordingID: UUID?
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
