import Foundation

/// Crash-recovery buffer for in-flight watch progress.
///
/// Committing watch progress to SwiftData on a timer forces the main context to
/// merge the change and re-run every `@Query` observing `Movie`/`Episode`/
/// `Series` — most visibly the Home screen's continue-watching rows — on the
/// main thread. That merge is what hitches KSPlayer's render loop every few
/// seconds, even when the `save()` itself runs on a background context.
///
/// So during playback we only stash progress here: `UserDefaults` writes trigger
/// no store merge and no SwiftUI invalidation (nothing observes this key via
/// `@AppStorage`). The player commits the buffered value to SwiftData only at
/// safe boundaries — close, episode switch, app backgrounding — and whatever is
/// still buffered after a crash or force-quit is reconciled on the next launch.
enum WatchProgressBuffer {
    enum Kind: String, Codable { case movie, episode }

    struct Entry: Codable {
        let kind: Kind
        let id: String
        let progress: TimeInterval
        let duration: TimeInterval

        var contentRef: PlayableMedia.ContentRef {
            switch kind {
            case .movie: .movie(id)
            case .episode: .episode(id)
            }
        }
    }

    private static let storageKey = "pendingWatchProgress"

    /// Stash the latest progress for `ref`, overwriting any earlier value. Live
    /// streams carry no resumable progress and are ignored.
    static func record(ref: PlayableMedia.ContentRef, progress: TimeInterval, duration: TimeInterval) {
        guard progress > 0, let (kind, id) = decompose(ref) else { return }
        var all = load()
        all[key(kind, id)] = Entry(kind: kind, id: id, progress: progress, duration: duration)
        save(all)
    }

    /// Drop the buffered entry for `ref` once it has been committed to SwiftData.
    static func remove(ref: PlayableMedia.ContentRef) {
        guard let (kind, id) = decompose(ref) else { return }
        var all = load()
        if all.removeValue(forKey: key(kind, id)) != nil { save(all) }
    }

    /// Read and clear every buffered entry. Used at launch to reconcile progress
    /// that never reached SwiftData because the app died mid-playback.
    static func drain() -> [Entry] {
        let all = load()
        if !all.isEmpty { UserDefaults.standard.removeObject(forKey: storageKey) }
        return Array(all.values)
    }

    private static func decompose(_ ref: PlayableMedia.ContentRef) -> (Kind, String)? {
        switch ref {
        case let .movie(id): (.movie, id)
        case let .episode(id): (.episode, id)
        case .live: nil
        }
    }

    private static func key(_ kind: Kind, _ id: String) -> String {
        "\(kind.rawValue):\(id)"
    }

    private static func load() -> [String: Entry] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return [:] }
        return decoded
    }

    private static func save(_ all: [String: Entry]) {
        guard !all.isEmpty else {
            UserDefaults.standard.removeObject(forKey: storageKey)
            return
        }
        guard let data = try? JSONEncoder().encode(all) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
