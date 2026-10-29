import CoreData
import Foundation
import OSLog
import SwiftData

/// Hands the backend choice between the Apple devices of one Apple ID through
/// the CloudKit-synced `SyncedBackendChoice` singleton.
///
/// Reads the record on launch, on foreground and after each CloudKit import:
/// - `lumecloud` on this build's server → a device on iCloud joins that
///   account with the record's root key (the record wins over the keychain).
///   A device already on Lume Cloud with another account moves to the
///   record's, by way of iCloud so both moves are ordinary union-merge switches.
/// - `icloud` → a device on Lume Cloud with the account the record left
///   follows back to iCloud and removes itself from the device list.
///
/// A join picked up while the launch gate is still closed holds it until the
/// first Lume Cloud pass lands, and queues the one-time "Sync moved to Lume
/// Cloud" alert.
///
/// While a fresh install shows the first-run sync choice, a `lumecloud`
/// record is only offered there (`CloudSyncCoordinator.offeredLumeCloudAccount`).
///
/// A device set to Off is never moved. Writes the record after this device
/// switches into Lume Cloud, or from Lume Cloud back to iCloud; Off is never
/// written. Inert unless `isEnabled` (`LumeApp.isCloudKitEnvironment`), so
/// SIDE_LOAD builds, tests and previews never touch the record.
@MainActor
final class SyncedBackendChoiceWatcher {
    /// A detached copy of the record, safe to hold across suspensions.
    struct Choice: Equatable {
        var backend: String
        var serverURL: String
        var accountId: String
        var rootKey: Data?
        var changedAt: Date
    }

    private let coordinator: CloudSyncCoordinator
    /// The iCloud `CloudUserData` store, which holds the record.
    private let container: ModelContainer
    let isEnabled: Bool
    private let serverURL: String
    private let keyStore: LumeCloudKeyStore
    private let now: () -> Date

    private var isStarted = false
    private var evaluation: Task<Void, Never>?
    private var needsEvaluation = false
    private var observers: [NSObjectProtocol] = []

    init(
        coordinator: CloudSyncCoordinator,
        container: ModelContainer,
        isEnabled: Bool,
        serverURL: URL = LumeCloudConfig.serverURL,
        keyStore: LumeCloudKeyStore = LumeCloudKeyStore(),
        now: @escaping () -> Date = { Date() }
    ) {
        self.coordinator = coordinator
        self.container = container
        self.isEnabled = isEnabled
        self.serverURL = LumeCloudConfig.comparable(serverURL)
        self.keyStore = keyStore
        self.now = now
        guard isEnabled else { return }
        coordinator.onBackendSwitched = { [weak self] origin, target, cause in
            // A move by way of iCloud written back would publish `icloud` and
            // send every other device back too.
            guard cause != .followingRecord else { return }
            self?.backendDidSwitch(from: origin, to: target)
        }
        observeCloudKitImports()
    }

    // MARK: Triggers

    /// Launch, after the coordinator started. Imports that finish earlier are
    /// covered by this first read.
    func start() async {
        guard isEnabled else { return }
        isStarted = true
        await refresh()
    }

    /// Foreground return and CloudKit imports. Overlapping requests collapse
    /// into one follow-up read.
    func refresh() async {
        guard isEnabled, isStarted else { return }
        if let running = evaluation {
            needsEvaluation = true
            await running.value
            return
        }
        // Cleared inside the task, right after its last check: awaiting a
        // finished task doesn't suspend, so a waiter looping on `evaluation`
        // until the starter cleared it would spin the main actor forever.
        let task = Task {
            repeat {
                needsEvaluation = false
                await evaluate()
            } while needsEvaluation
            evaluation = nil
        }
        evaluation = task
        await task.value
    }

    private func observeCloudKitImports() {
        let observer = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard
                let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                as? NSPersistentCloudKitContainer.Event,
                event.type == .import, event.endDate != nil, event.succeeded
            else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.refresh() }
            }
        }
        observers.append(observer)
    }

    // MARK: Following the record

    private func evaluate() async {
        let choice: Choice?
        do {
            choice = try dedupedChoice()
        } catch {
            Logger.sync.error("Backend choice couldn't be read: \(error.localizedDescription)")
            return
        }
        if coordinator.status.isAwaitingBackendChoice {
            coordinator.offeredLumeCloudAccount = choice.flatMap(offeredAccount(in:))
            return
        }
        guard let choice, isOnThisServer(choice) else { return }
        let current = coordinator.selectedBackend
        switch SyncedBackendChoice.Backend(rawValue: choice.backend) {
        case .lumecloud:
            guard current != .off, !choice.accountId.isEmpty, !isJoined(underRecordKeyOf: choice),
                  let keychain = readableKeychain()
            else { return }
            await followIntoLumeCloud(choice, keychain: keychain)
        case .icloud:
            guard current == .lumecloud, readableKeychain() != nil else { return }
            await followIntoICloud(choice)
        case nil:
            // Written by a newer build; leave the device where it is.
            return
        }
    }

    /// The account a `lumecloud` record on this build's server names, for the
    /// first-run sync choice to offer: while it's up the device follows nothing.
    private func offeredAccount(in choice: Choice) -> LumeCloudIdentity? {
        guard isOnThisServer(choice), SyncedBackendChoice.Backend(rawValue: choice.backend) == .lumecloud else { return nil }
        return identity(of: choice, keychain: keyStore.load())
    }

    /// Nil while the keychain is locked: that says nothing about the identity,
    /// so the record is read again later.
    private func readableKeychain() -> LumeCloudKeyStore.Stored? {
        let stored = keyStore.load()
        return stored == .unavailable ? nil : stored
    }

    /// The record carries its own root key and names the account already joined.
    private func isJoined(underRecordKeyOf choice: Choice) -> Bool {
        guard coordinator.selectedBackend == .lumecloud, let rootKey = choice.rootKey else { return false }
        let recorded = LumeCloudIdentity(accountId: choice.accountId, rootKey: rootKey)
        return (try? coordinator.lumeCloudBackend().identity) == recorded
    }

    private func followIntoLumeCloud(_ choice: Choice, keychain: LumeCloudKeyStore.Stored) async {
        let current = coordinator.selectedBackend
        guard let identity = identity(of: choice, keychain: keychain) else { return }
        if current == .lumecloud {
            guard (try? coordinator.lumeCloudBackend().identity) != identity else { return }
            Logger.sync.notice("Another Apple device moved Lume Cloud to a different account: following")
            guard await followBackToICloud() else { return }
        } else {
            Logger.sync.notice("Another Apple device moved sync to Lume Cloud: joining")
        }
        await join(identity)
    }

    private func followIntoICloud(_ choice: Choice) async {
        guard coordinator.selectedBackend == .lumecloud else { return }
        let joined = try? coordinator.lumeCloudBackend().identity
        guard choice.accountId.isEmpty || joined == nil || joined?.accountId == choice.accountId else { return }
        Logger.sync.notice("Another Apple device left Lume Cloud: returning to iCloud")
        await followBackToICloud()
    }

    /// The record's account. The record's root key wins over the keychain's;
    /// the keychain only fills in a record whose encrypted key hasn't arrived.
    private func identity(of choice: Choice, keychain: LumeCloudKeyStore.Stored) -> LumeCloudIdentity? {
        guard !choice.accountId.isEmpty else { return nil }
        if let rootKey = choice.rootKey {
            return LumeCloudIdentity(accountId: choice.accountId, rootKey: rootKey)
        }
        guard case let .identity(stored) = keychain, stored.accountId == choice.accountId else { return nil }
        return stored
    }

    private func join(_ identity: LumeCloudIdentity) async {
        coordinator.beginLaunchJoinWait()
        do {
            try await coordinator.lumeCloudBackend().join(identity)
            try await coordinator.switchBackend(to: .lumecloud, cause: .followingRecord)
            coordinator.settings.queueMovedNotice()
        } catch {
            coordinator.endLaunchJoinWait(openingGate: false)
            Logger.sync.error("Joining Lume Cloud from the Apple-wide choice failed: \(error)")
        }
    }

    /// Switches to iCloud, then removes this device from the account's device
    /// list. The keychain identity stays, as after a Leave on this device.
    @discardableResult
    private func followBackToICloud() async -> Bool {
        do {
            try await coordinator.switchBackend(to: .icloud, cause: .followingRecord)
        } catch {
            Logger.sync.error("Returning to iCloud from the Apple-wide choice failed: \(error)")
            return false
        }
        await (try? coordinator.lumeCloudBackend())?.leave()
        return true
    }

    /// The record serves this build when it names this build's server; an
    /// `icloud` record from before the server was recorded serves every build.
    private func isOnThisServer(_ choice: Choice) -> Bool {
        let recorded = LumeCloudConfig.comparable(choice.serverURL)
        if recorded.isEmpty {
            return choice.backend == SyncedBackendChoice.Backend.icloud.rawValue
        }
        return recorded == serverURL
    }

    // MARK: Writing the record

    private func backendDidSwitch(from origin: SyncBackendSelection, to target: SyncBackendSelection) {
        let choice: Choice
        switch (origin, target) {
        case (_, .lumecloud):
            guard let identity = try? coordinator.lumeCloudBackend().identity else { return }
            choice = Choice(
                backend: SyncedBackendChoice.Backend.lumecloud.rawValue,
                serverURL: serverURL,
                accountId: identity.accountId,
                rootKey: identity.rootKey,
                changedAt: now()
            )
        case (.lumecloud, .icloud):
            // Names the account left, so only its members follow.
            choice = Choice(
                backend: SyncedBackendChoice.Backend.icloud.rawValue,
                serverURL: serverURL,
                accountId: (try? coordinator.lumeCloudBackend().lastKnownAccountId()) ?? "",
                rootKey: nil,
                changedAt: now()
            )
        default:
            return
        }
        do {
            try write(choice)
        } catch {
            Logger.sync.error("Backend choice couldn't be saved: \(error.localizedDescription)")
        }
    }

    /// Updates the singleton unless it already says the same.
    func write(_ choice: Choice) throws {
        let context = ModelContext(container)
        let existing = try newestRow(in: context)
        var current = existing.map { Choice($0) }
        current?.changedAt = choice.changedAt
        if current != choice {
            let row: SyncedBackendChoice
            if let existing {
                row = existing
            } else {
                row = SyncedBackendChoice(backend: .icloud)
                context.insert(row)
            }
            row.backend = choice.backend
            row.serverURL = choice.serverURL
            row.accountId = choice.accountId
            row.rootKey = choice.rootKey
            row.changedAt = choice.changedAt
        }
        if context.hasChanges {
            try context.save()
        }
    }

    // MARK: Reading the record

    private static var newestFirst: FetchDescriptor<SyncedBackendChoice> {
        FetchDescriptor(sortBy: [SortDescriptor(\.changedAt, order: .reverse)])
    }

    /// The newest row in `context`; older copies (two devices each inserted one
    /// before CloudKit converged) are deleted from it, unsaved.
    private func newestRow(in context: ModelContext) throws -> SyncedBackendChoice? {
        let rows = try context.fetch(Self.newestFirst)
        for duplicate in rows.dropFirst() {
            context.delete(duplicate)
        }
        return rows.first
    }

    /// The newest record, with older copies deleted. Nil when no device ever
    /// wrote one.
    func dedupedChoice() throws -> Choice? {
        let context = ModelContext(container)
        guard let newest = try newestRow(in: context) else { return nil }
        if context.hasChanges {
            try context.save()
        }
        return Choice(newest)
    }
}

extension SyncedBackendChoiceWatcher.Choice {
    init(_ row: SyncedBackendChoice) {
        self.init(
            backend: row.backend,
            serverURL: row.serverURL,
            accountId: row.accountId,
            rootKey: row.rootKey,
            changedAt: row.changedAt
        )
    }
}
