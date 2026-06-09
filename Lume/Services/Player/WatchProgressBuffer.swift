import Foundation

/// Crash-recovery buffer for in-flight watch progress.
///
/// Committing watch progress to SwiftData on a timer forces the main context to
/// merge the change and re-run every `@Query` observing `Movie`/`Episode`/
/// `Series` — most visibly the Home screen's continue-watching rows — on the
/// main thread. That merge is what hitches KSPlayer's render loop every few
/// seconds, even when the `save()` itself runs on a background context.
///
/// So during playback we only stash progress here. The player commits the
/// buffered value to SwiftData only at safe boundaries — close, episode switch,
/// app backgrounding — and whatever is still buffered after a crash or
/// force-quit is reconciled on the next launch.
///
/// Even this lightweight buffer has to be careful: KSPlayer presents frames via
/// a main-run-loop display link *and* keeps decode/render threads busy on the
/// Apple TV's limited cores, so it drops a burst of frames to resync if anything
/// — on or off the main thread — stalls that pipeline for even a few ms. Hence
/// the deliberately minimal write path here: a flat primitive `UserDefaults`
/// layout (no JSON coding, no whole-dict read-modify-write), dispatched onto a
/// serial `.background` queue that yields to the video pipeline, with a paused-
/// playback dedup so a still clock doesn't rewrite anything.
///
/// The on-disk layout is internal — the app isn't published, so there is no
/// legacy format to migrate.
enum WatchProgressBuffer {
    enum Kind: String { case movie, episode }

    struct Entry {
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

    /// One `UserDefaults` key per pending item, value = `[progress, duration]`.
    private static let prefix = "watchProgress."

    /// Serializes the writes and runs them at the lowest priority, off the
    /// caller's thread — the player samples from the main actor, where KSPlayer
    /// presents frames, and `.background` keeps the write from preempting decode.
    private static let queue = DispatchQueue(label: "com.lume.watchprogressbuffer", qos: .background)

    /// Last progress written per key, so a paused stream (clock not moving)
    /// doesn't rewrite `UserDefaults` every tick. Touched only on `queue`.
    private static var lastProgress: [String: TimeInterval] = [:]

    /// Stash the latest progress for `ref`, overwriting any earlier value.
    /// Returns immediately; the (deduped) write lands on `queue`. Live streams
    /// carry no resumable progress and are ignored.
    static func record(ref: PlayableMedia.ContentRef, progress: TimeInterval, duration: TimeInterval) {
        guard progress > 0, let (kind, id) = decompose(ref) else { return }
        let storageKey = prefix + key(kind, id)
        queue.async {
            guard lastProgress[storageKey] != progress else { return }
            lastProgress[storageKey] = progress
            UserDefaults.standard.set([progress, duration], forKey: storageKey)
        }
    }

    /// Drop the buffered entry for `ref` once it has been committed to SwiftData.
    static func remove(ref: PlayableMedia.ContentRef) {
        guard let (kind, id) = decompose(ref) else { return }
        let storageKey = prefix + key(kind, id)
        queue.async {
            lastProgress[storageKey] = nil
            UserDefaults.standard.removeObject(forKey: storageKey)
        }
    }

    /// Read and clear every buffered entry. Used at launch to reconcile progress
    /// that never reached SwiftData because the app died mid-playback. Runs
    /// synchronously on `queue` so it can't race an in-flight `record`/`remove`.
    static func drain() -> [Entry] {
        queue.sync {
            let defaults = UserDefaults.standard
            var entries: [Entry] = []

            for (storageKey, value) in defaults.dictionaryRepresentation() where storageKey.hasPrefix(prefix) {
                defaults.removeObject(forKey: storageKey)
                lastProgress[storageKey] = nil
                guard let values = value as? [Double], values.count == 2,
                      let (kind, id) = parse(String(storageKey.dropFirst(prefix.count)))
                else { continue }
                entries.append(Entry(kind: kind, id: id, progress: values[0], duration: values[1]))
            }

            return entries
        }
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

    private static func parse(_ suffix: String) -> (Kind, String)? {
        guard let sep = suffix.firstIndex(of: ":"),
              let kind = Kind(rawValue: String(suffix[suffix.startIndex ..< sep]))
        else { return nil }
        return (kind, String(suffix[suffix.index(after: sep)...]))
    }
}
