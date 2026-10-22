/// Why a reconcile was requested — determines whether a pass with nothing to do
/// can be skipped. A foreground return and a bare `.NSPersistentStoreRemoteChange`
/// only run when the backend has remote data pending (`SyncBackend.hasPendingChanges`);
/// launch, the pre-suspension flush, a finished catalog sync, and a queued
/// follow-up always run.
enum ReconcileReason {
    /// Cold-launch first pass — establishes the baseline and pulls anything
    /// CloudKit already imported.
    case launch
    /// App returned to the foreground.
    case foreground
    /// App is suspending — flush local edits to the cloud before it does.
    case backgroundFlush
    /// CloudKit reported a store change (import, or our own export ack).
    case remoteChange
    /// A playlist's catalog finished syncing, so pending cloud state can apply.
    case contentSync
    /// An internal follow-up pass (coalesced overlap, or a post-profile-switch
    /// re-baseline) — always runs.
    case queued
}
