import SwiftData

/// Reads the mirror store directly (never through `@Query`) and so must follow
/// it when a backend switch swaps the container, and re-read it when a backend
/// wrote rows into it. CloudKit's own writes don't reach `mirrorDidChange()`:
/// they post `.NSPersistentStoreRemoteChange` and run a reconcile.
@MainActor
protocol SyncMirrorConsumer: AnyObject {
    func repoint(container: ModelContainer)
    func mirrorDidChange()
}

/// How `CloudSyncCoordinator` holds its consumers.
struct WeakMirrorConsumer {
    weak var value: (any SyncMirrorConsumer)?
}
