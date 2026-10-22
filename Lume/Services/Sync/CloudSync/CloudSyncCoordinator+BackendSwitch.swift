import Foundation
import OSLog
import SwiftData

/// Why a backend switch was refused. Nothing changed.
enum SyncBackendSwitchError: Error, Equatable {
    /// This build can't use the backend: iCloud in a SIDE_LOAD build, or Lume
    /// Cloud's store failed to open.
    case unavailable
    /// Lume Cloud holds no account on this device: create or join one first.
    case notJoined
}

/// Why a backend switch ran.
enum SyncBackendSwitchCause {
    /// Started on this device: the user, or the server ending its membership.
    case local
    /// Following another Apple device's choice, so it isn't written back.
    case followingRecord
}

/// What the account-end notice reports: why the membership ended, and the
/// backend the device ended up on.
struct LumeCloudAccountEndNotice: Equatable {
    let reason: LumeCloudAccountEnd
    let resultingBackend: SyncBackendSelection

    var message: LocalizedStringResource {
        reason.noticeMessage(returnedToICloud: resultingBackend == .icloud)
    }
}

/// Switching the device's backend live, without a relaunch.
extension CloudSyncCoordinator {
    /// The backend this device syncs through.
    var selectedBackend: SyncBackendSelection {
        SyncBackendSelection(backend.kind)
    }

    /// Whether this build can sync through iCloud.
    var isICloudAvailable: Bool {
        #if SIDE_LOAD
            false
        #else
            backends[.icloud] != nil
        #endif
    }

    /// The backends the Settings picker offers, in order.
    var availableBackends: [SyncBackendSelection] {
        isICloudAvailable ? [.icloud, .lumecloud, .off] : [.lumecloud, .off]
    }

    /// The Lume Cloud backend, created on first use: the account flows run on
    /// it before a switch attaches it.
    func lumeCloudBackend() throws -> LumeCloudBackend {
        if let existing = backends[.lumecloud] as? LumeCloudBackend {
            return existing
        }
        let created = try makeLumeCloudBackend()
        register(created)
        return created
    }

    /// Makes `target` this device's backend and persists the choice. In order:
    /// stop the old backend → carry mirror-only data into the new mirror (a
    /// Lume Cloud target empties its mirror and bookkeeping first, so it
    /// re-pulls) → rebuild the engine on the target's reset shadow namespace and
    /// repoint the mirror's readers → reconcile. The empty shadow makes that
    /// first reconcile a union merge: it can't read anything as deleted.
    ///
    /// Off keeps the engine and the readers on the previous mirror and never
    /// reconciles. Switches queue behind each other.
    func switchBackend(to target: SyncBackendSelection, cause: SyncBackendSwitchCause = .local) async throws {
        let previous = switchTask
        let task = Task {
            await previous?.value
            try await performSwitch(to: target, cause: cause)
        }
        switchTask = Task { _ = try? await task.value }
        try await task.value
    }

    /// The backend a launch starts on for the stored `choice`. A Lume Cloud
    /// choice keeps its backend even while the keychain can't be read yet
    /// (before first unlock): the backend picks the identity up on a later pass.
    /// When the Lume Cloud store can't open, the launch falls back to iCloud
    /// (Off where this build has no iCloud) without touching the stored choice.
    static func launchBackend(
        for choice: SyncBackendSelection,
        iCloud: any SyncBackend,
        makeLumeCloudBackend: () throws -> LumeCloudBackend
    ) -> any SyncBackend {
        #if SIDE_LOAD
            let fallback: any SyncBackend = OffBackend()
        #else
            let fallback = iCloud
        #endif
        switch choice {
        case .icloud:
            return fallback
        case .off:
            return OffBackend()
        case .lumecloud:
            do {
                return try makeLumeCloudBackend()
            } catch {
                Logger.sync.error("Lume Cloud store failed to open at launch: \(error)")
                return fallback
            }
        }
    }

    /// The server ended this device's Lume Cloud membership; the backend has
    /// already dropped the identity. A revoked device goes Off; a deleted
    /// account sends the device back to iCloud, or Off where iCloud isn't
    /// available. Local data stays either way.
    func handleAccountEnded(_ reason: LumeCloudAccountEnd) async {
        guard backend is LumeCloudBackend else { return }
        do {
            try await switchBackend(to: accountEndTarget(for: reason))
        } catch {
            Logger.sync.error("Leaving Lume Cloud failed: \(error)")
        }
        accountEndNotice = LumeCloudAccountEndNotice(reason: reason, resultingBackend: selectedBackend)
    }

    /// Where the device goes when the server ends its membership for `reason`.
    private func accountEndTarget(for reason: LumeCloudAccountEnd) -> SyncBackendSelection {
        reason == .accountDeleted ? lumeCloudLeaveTarget : .off
    }

    /// The account-end notice was seen.
    func dismissAccountEndNotice() {
        accountEndNotice = nil
    }

    private func performSwitch(to target: SyncBackendSelection, cause: SyncBackendSwitchCause) async throws {
        guard target != selectedBackend else {
            settings.backend = target
            return
        }
        let origin = selectedBackend
        let next = try resolveBackend(for: target)
        await suspendPasses()
        let previous = backend
        previous.stop()
        if next.kind != nil, let targetMirror = next.mirrorContainer {
            do {
                try await carryOverMirrorData(into: targetMirror, preparedBy: next)
            } catch {
                Logger.sync.error("Backend switch failed while copying the mirror: \(error)")
                previous.attach(to: self)
                resumePasses()
                throw error
            }
        }
        install(next)
        settings.backend = target
        if let kind = next.kind, let targetMirror = next.mirrorContainer {
            await replaceEngine(mirrorContainer: targetMirror, namespace: kind, resettingShadow: true)
        }
        resumePasses()
        Logger.sync.notice("Sync backend switched to \(target.rawValue, privacy: .public)")
        onBackendSwitched?(origin, target, cause)
        guard next.kind != nil else { return }
        await next.start()
        reconcile(reason: .queued, debounced: false)
    }

    private func resolveBackend(for target: SyncBackendSelection) throws -> any SyncBackend {
        switch target {
        case .icloud:
            guard isICloudAvailable, let iCloud = backends[.icloud] else { throw SyncBackendSwitchError.unavailable }
            return iCloud
        case .lumecloud:
            let lumeCloud: LumeCloudBackend
            do {
                lumeCloud = try lumeCloudBackend()
            } catch {
                throw SyncBackendSwitchError.unavailable
            }
            guard lumeCloud.isJoined else { throw SyncBackendSwitchError.notJoined }
            return lumeCloud
        case .off:
            return backends[.off] ?? OffBackend()
        }
    }

    /// Snapshots the current mirror before `next` prepares its own (Lume Cloud
    /// empties it), so this also works when the two are the same store
    /// (rejoining from Off).
    private func carryOverMirrorData(into target: ModelContainer, preparedBy next: any SyncBackend) async throws {
        let activeProfileID = ActiveProfileStore.current ?? UserProfile.defaultProfileID
        let snapshot = try await SyncMirrorSeeder.snapshot(of: mirrorContainer, activeProfileID: activeProfileID)
        try await next.prepareMirrorForAttach()
        try await SyncMirrorSeeder.seed(snapshot, into: target)
    }
}
