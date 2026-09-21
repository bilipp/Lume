//
//  SportsChannelPicks.swift
//  Lume
//
//  Remembers which channel the viewer chose to watch a competition on, so the
//  channel resolver can float that pick to the top for every fixture in the
//  same competition. Device-local by design (a pick names a channel in *this*
//  device's playlists), so it lives in `UserDefaults` rather than the iCloud
//  mirror — a followed league syncs, the channel it happens to be on does not.
//
//  A pick keys off the competition (the provider-neutral league id) plus the
//  channel's `epgChannelId`, falling back to its normalised name — never an
//  `EPGListing.id` or a `PersistentIdentifier`, which don't survive a re-sync.
//  The owning playlist's id is stored alongside so the pick can be pruned when
//  that playlist is deleted.
//

import Foundation

/// Device-local record of the channels a viewer pinned for a competition.
///
/// `nonisolated` so both the main-actor UI (the channel picker's "remember"
/// toggle) and the off-main resolver's snapshot read can use it. Stored as one
/// JSON dictionary — composite key → owning playlist id — under a single
/// `UserDefaults` key.
nonisolated struct SportsChannelPicks {
    private let defaults: UserDefaults
    private let storageKey = "sports.channelPicks.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The stored map: `"<competitionKey>|<channelKey>"` → owning playlist id.
    /// A `Sendable` value that can be captured into the resolver's detached
    /// task, so it never has to carry a `UserDefaults` reference across the
    /// actor boundary.
    func snapshot() -> [String: String] {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return decoded
    }

    private func write(_ map: [String: String]) {
        guard let data = try? JSONEncoder().encode(map) else { return }
        defaults.set(data, forKey: storageKey)
    }

    /// Whether a channel is pinned for a competition.
    func isPicked(competitionKey: String, channelKey: String) -> Bool {
        snapshot()[Self.compositeKey(competitionKey: competitionKey, channelKey: channelKey)] != nil
    }

    /// Pin `channelKey` (owned by `playlistID`) as a chosen channel for
    /// `competitionKey`. Several channels may be pinned for one competition.
    func remember(competitionKey: String, channelKey: String, playlistID: UUID) {
        var map = snapshot()
        map[Self.compositeKey(competitionKey: competitionKey, channelKey: channelKey)] = playlistID.uuidString
        write(map)
    }

    /// Drop a pin.
    func forget(competitionKey: String, channelKey: String) {
        var map = snapshot()
        map.removeValue(forKey: Self.compositeKey(competitionKey: competitionKey, channelKey: channelKey))
        write(map)
    }

    /// Remove every pick that named a channel in `playlistID`. Called from the
    /// playlist-deletion cleanup so a removed playlist leaves no dangling pins.
    func remove(playlistID: UUID) {
        let target = playlistID.uuidString
        let map = snapshot()
        let pruned = map.filter { $0.value != target }
        guard pruned.count != map.count else { return }
        write(pruned)
    }

    /// The channel identity a pick keys off: the stable `epgChannelId` when the
    /// stream has one, else its diacritic- and case-folded name.
    static func channelKey(epgChannelId: String?, name: String) -> String {
        if let epgChannelId, !epgChannelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return epgChannelId
        }
        return name
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func compositeKey(competitionKey: String, channelKey: String) -> String {
        "\(competitionKey)|\(channelKey)"
    }
}
