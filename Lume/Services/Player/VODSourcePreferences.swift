//
//  VODSourcePreferences.swift
//  Lume
//
//  Which copy of a grouped movie or series plays: the source last picked per
//  title on this device, and the rules for when the picker is skipped.
//

import Foundation

// MARK: - Remembered picks

/// The row last picked per title group, on this device only. Never synced and
/// kept out of diagnostic exports. A small capped map like
/// `MediaSourcePreferences`: the pick is a preference for a list that changes
/// under it, so a remembered row that is gone is simply not found.
nonisolated enum VODSourcePreferences {
    static let storageKey = "player.vodSourcePicks"
    static let capacity = 200

    /// TMDB ids of movies and TV shows are separate number spaces, so a key
    /// alone doesn't name one title.
    enum Kind: String {
        case movie, series
    }

    struct Entry: Codable, Equatable {
        var rowID: String
        var pickedAt: Date
    }

    /// The group a row's pick is remembered under: its `titleGroupKey`, else
    /// the row itself.
    static func groupKey(of row: some TitleGroupedRow) -> String {
        row.titleGroupKey ?? row.id
    }

    /// The pick for `groupKey`, else a pick stored under another key whose row
    /// is among `optionIDs`, which then moves to `groupKey`: a title's key
    /// changes from `t:<title>|<year>` to `tmdb:<id>` once it is enriched.
    static func rememberedRowID(
        _ kind: Kind,
        groupKey: String,
        among optionIDs: [String],
        defaults: UserDefaults = .standard
    ) -> String? {
        var entries = load(defaults)
        let currentKey = key(kind, groupKey)
        if let entry = entries[currentKey] { return entry.rowID }
        let prefix = key(kind, "")
        let candidates = Set(optionIDs)
        guard let moved = entries
            .filter({ $0.key.hasPrefix(prefix) && candidates.contains($0.value.rowID) })
            .max(by: { $0.value.pickedAt < $1.value.pickedAt })
        else { return nil }
        entries.removeValue(forKey: moved.key)
        entries[currentKey] = moved.value
        save(entries, defaults)
        return moved.value.rowID
    }

    static func remember(
        rowID: String,
        _ kind: Kind,
        groupKey: String,
        at date: Date = Date(),
        defaults: UserDefaults = .standard
    ) {
        var entries = load(defaults)
        entries[key(kind, groupKey)] = Entry(rowID: rowID, pickedAt: date)
        if entries.count > capacity {
            let evicted = entries.sorted { $0.value.pickedAt < $1.value.pickedAt }.prefix(entries.count - capacity)
            for (key, _) in evicted {
                entries.removeValue(forKey: key)
            }
        }
        save(entries, defaults)
    }

    private static func key(_ kind: Kind, _ groupKey: String) -> String {
        "\(kind.rawValue)|\(groupKey)"
    }

    private static func save(_ entries: [String: Entry], _ defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: storageKey)
        }
    }

    private static func load(_ defaults: UserDefaults) -> [String: Entry] {
        guard let data = defaults.data(forKey: storageKey) else { return [:] }
        return (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
    }
}

// MARK: - Skip rules

nonisolated enum VODSourceDecision: Equatable {
    case play(VODSourceOption)
    case showPicker(preselected: VODSourceOption?)

    /// What Play does with `options` (best first, as `VODSourceResolver`
    /// orders them). Nil when there is nothing to play.
    ///
    /// A source that already failed on every engine always brings the picker
    /// back, so the viewer chooses the next one; nothing is tried
    /// automatically. Otherwise a single source plays directly; with several,
    /// `chooseBeforePlaying` asks and its absence plays the remembered source,
    /// else the best-ranked one. `forcePicker` (long press on Play) asks
    /// whatever the count or setting.
    static func decide(
        options: [VODSourceOption],
        remembered: String?,
        chooseBeforePlaying: Bool,
        forcePicker: Bool,
        failed: Set<String> = []
    ) -> VODSourceDecision? {
        guard let best = options.first else { return nil }
        let rememberedOption = remembered.flatMap { id in options.first { $0.rowID == id } }
        let preselected = rememberedOption.flatMap { failed.contains($0.rowID) ? nil : $0 }
            ?? options.first { !failed.contains($0.rowID) }
        if forcePicker || options.contains(where: { failed.contains($0.rowID) }) {
            return .showPicker(preselected: preselected)
        }
        if options.count == 1 {
            return .play(best)
        }
        if chooseBeforePlaying {
            return .showPicker(preselected: rememberedOption ?? best)
        }
        return .play(rememberedOption ?? best)
    }
}

@MainActor
extension VODSourceDecision {
    /// ``decide(options:remembered:chooseBeforePlaying:forcePicker:failed:)``
    /// as a title's screen runs it: with the copy remembered for `kind` and
    /// `groupKey` (returned too, for the picker) and the Choose Source setting.
    static func decide(
        _ kind: VODSourcePreferences.Kind,
        groupKey: String,
        options: [VODSourceOption],
        forcePicker: Bool,
        failed: Set<String>
    ) -> (decision: VODSourceDecision?, remembered: String?) {
        let remembered = VODSourcePreferences.rememberedRowID(kind, groupKey: groupKey, among: options.map(\.rowID))
        let decision = decide(
            options: options,
            remembered: remembered,
            chooseBeforePlaying: PlayerSettings.Playback.chooseSourceBeforePlaying,
            forcePicker: forcePicker,
            failed: failed
        )
        return (decision, remembered)
    }
}
