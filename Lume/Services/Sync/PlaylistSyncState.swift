//
//  PlaylistSyncState.swift
//  Lume
//
//  What a playlist's sync looks like *right now*, as one value the settings
//  surfaces can render. Derived from state the playlist already carries —
//  `syncStatus`, `lastSyncDate`, `syncEnabled` — plus the global frequency;
//  nothing new is persisted.
//
//  Three places show this (the iOS list row, the tvOS row, and both detail
//  panes), and before this type each decided for itself what was worth
//  mentioning: the list rows said nothing at all, and the detail panes rendered
//  `Last Synced` only when there was a date, so a playlist that had never
//  finished a sync looked exactly like a healthy one. Resolving it once, here,
//  is what keeps those surfaces telling the same story — and keeps the decision
//  unit-testable, like `AutoSync.shouldSync` next door.
//

import Foundation
import SwiftUI

/// A playlist's sync condition, in the order the surfaces care about it: the
/// states that need the viewer's attention come first, and the healthy steady
/// state comes last and stays quiet.
enum PlaylistSyncState: Equatable {
    /// A sync is running for this playlist right now.
    case syncing
    /// The last attempt ended in an error. Note there is no reason to show
    /// with it: `Playlist` stores only `idle` / `syncing` / `error`, so
    /// "it failed" is the whole of what is actually known.
    case failed
    /// Never finished a sync. Distinct from `failed` because it is also the
    /// ordinary state of a playlist added a moment ago.
    case never
    /// Synced before, but longer ago than the frequency allows — so it is due
    /// and will start on the next launch, playlist switch or foreground.
    case overdue(lastSyncDate: Date)
    /// Synced within the interval. Nothing to say.
    case synced(lastSyncDate: Date)
    /// The playlist opted out of automatic syncing, so staleness is expected
    /// and reporting it would be noise.
    case disabled(lastSyncDate: Date?)

    /// Resolve the state from a playlist's own fields. Takes them loose rather
    /// than taking `Playlist` so it stays testable without a `ModelContext`,
    /// and `now` is injectable for the same reason.
    static func resolve(
        syncEnabled: Bool,
        status: SyncStatus,
        lastSyncDate: Date?,
        frequency: SyncFrequency,
        now: Date = Date()
    ) -> PlaylistSyncState {
        // Checked ahead of `syncEnabled`: a sync kicked off by hand (Sync Now)
        // runs regardless of the opt-out, and while it runs that is the most
        // useful thing to say.
        if status == .syncing { return .syncing }
        guard syncEnabled else { return .disabled(lastSyncDate: lastSyncDate) }
        if status == .error { return .failed }
        guard let lastSyncDate else { return .never }
        if frequency.isDue(lastSyncDate: lastSyncDate, now: now) {
            return .overdue(lastSyncDate: lastSyncDate)
        }
        return .synced(lastSyncDate: lastSyncDate)
    }

    /// The date to show as "Last Synced", when there is one.
    var lastSyncDate: Date? {
        switch self {
        case let .overdue(date), let .synced(date): date
        case let .disabled(date): date
        case .syncing, .failed, .never: nil
        }
    }

    /// Whether a list row should draw an accessory for this state at all.
    ///
    /// Only the states a viewer would act on earn one. Badging every row —
    /// including the healthy majority — trains the eye to skip the badge, which
    /// costs exactly the signal this was added for.
    var deservesRowAccessory: Bool {
        switch self {
        case .syncing, .failed, .never: true
        case .overdue, .synced, .disabled: false
        }
    }

    /// SF Symbol for the row accessory. `nil` where `deservesRowAccessory` is
    /// false, and for `.syncing`, which draws a spinner instead of a glyph.
    var symbolName: String? {
        switch self {
        case .failed: "exclamationmark.triangle.fill"
        case .never: "clock.badge.questionmark"
        case .syncing, .overdue, .synced, .disabled: nil
        }
    }

    /// Tint for the accessory and the detail status row.
    ///
    /// Deliberately never `.accentColor`: that resolves to white on tvOS, where
    /// it would read as ordinary text rather than as a warning.
    var tint: Color {
        switch self {
        case .failed: .orange
        case .syncing, .never, .overdue, .synced, .disabled: .secondary
        }
    }

    /// The detail pane's Status line. Always says something, including for the
    /// two states the panes used to render as an absent row.
    var statusLabel: LocalizedStringResource {
        switch self {
        case .syncing: "Syncing"
        case .failed: "Last sync failed"
        case .never: "Never synced"
        case .overdue: "Sync due"
        case .synced: "Up to date"
        case .disabled: "Sync off"
        }
    }
}

extension Playlist {
    /// This playlist's sync state under the stored global frequency. The
    /// convenience the views actually call; `PlaylistSyncState.resolve` stays
    /// the testable seam beneath it.
    var syncState: PlaylistSyncState {
        PlaylistSyncState.resolve(
            syncEnabled: syncEnabled,
            status: syncStatus,
            lastSyncDate: lastSyncDate,
            frequency: SyncFrequency.resolve(
                UserDefaults.standard.string(forKey: SyncFrequency.storageKey) ?? ""
            )
        )
    }
}
