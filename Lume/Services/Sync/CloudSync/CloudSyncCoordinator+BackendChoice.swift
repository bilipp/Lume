import Foundation
import SwiftData

/// The first-run sync choice: a fresh install starts Off and asks whether to
/// sync with iCloud, Lume Cloud or not at all before anything reaches the
/// catalog. iCloud and Off commit through `chooseInitialBackend(_:)`; the Lume
/// Cloud flows (create, join, restore) switch on their own, then call
/// `finishBackendChoice()`. Either way the launch gate then waits for the
/// chosen backend's first sync, as it does at every fresh launch.
extension CloudSyncCoordinator {
    /// When a launch asks for the first-run choice.
    enum BackendChoiceOffer {
        /// Previews and automated runs: start on the stored backend.
        case never
        /// A fresh install: no backend stored and no playlist in the catalog.
        case freshInstall
        /// Every launch, for UI tests (`-sync-setup`).
        case always

        /// Whether this launch asks. An install with playlists but no stored
        /// backend predates the choice: it keeps the default, now stored, so an
        /// emptied catalog later doesn't ask either.
        func applies(to settings: LumeCloudSettings, catalogContainer: ModelContainer) -> Bool {
            switch self {
            case .never:
                return false
            case .always:
                return true
            case .freshInstall:
                guard !settings.hasStoredBackend else { return false }
                let playlists = (try? ModelContext(catalogContainer).fetchCount(FetchDescriptor<Playlist>())) ?? 0
                guard playlists == 0 else {
                    settings.backend = LumeCloudSettings.defaultBackend
                    return false
                }
                return true
            }
        }
    }

    /// Commits the first-run choice of iCloud or Off and ends it. Lume Cloud
    /// goes through its account flows instead.
    func chooseInitialBackend(_ target: SyncBackendSelection) async throws {
        guard target != .lumecloud else { throw SyncBackendSwitchError.notJoined }
        try await switchBackend(to: target)
        finishBackendChoice()
    }

    /// Ends the first-run choice. A backend that waits for its first sync
    /// opens the launch gate when that sync lands, so synced playlists show
    /// before the add-playlist form; anything else opens it now.
    func finishBackendChoice() {
        guard status.isAwaitingBackendChoice else { return }
        status.isAwaitingBackendChoice = false
        offeredLumeCloudAccount = nil
        if !backend.waitsForInitialSync {
            status.hasCompletedInitialSync = true
        }
    }

    /// Joins the account the user's other Apple devices sync with
    /// (`offeredLumeCloudAccount`), then makes Lume Cloud this device's
    /// backend. That follows the Apple-wide record, so nothing is written back.
    func joinOfferedLumeCloudAccount() async throws {
        guard let identity = offeredLumeCloudAccount else { throw SyncBackendSwitchError.notJoined }
        try await lumeCloudBackend().join(identity)
        try await switchBackend(to: .lumecloud, cause: .followingRecord)
    }
}
