import CloudKit
import CoreData
import Foundation
import OSLog

extension ICloudBackend {
    /// Turn a CloudKit sync-event error into a readable message, logging the full
    /// detail to `Logger.sync`.
    ///
    /// A CloudKit `partialFailure` — the opaque "CKErrorDomain error 2" that
    /// reaches the user — usually hides the real cause inside
    /// `partialErrorsByItemID`; `localizedDescription` on its own just repeats
    /// "error 2". Unwrapping the per-record errors lets the log (and the settings
    /// screen) name what actually failed — most often a record type that isn't in
    /// the deployed CloudKit schema yet (e.g. a build pointed at an environment
    /// whose schema was never deployed: every record is rejected and the batch
    /// reports `partialFailure`).
    ///
    /// When that dictionary is *empty* the failure is above the record level —
    /// account, zone, or quota — and there is nothing to unwrap, so
    /// `CloudSyncErrorDescription` carries the diagnosis instead: the log gets
    /// the domain, code, `CKError` case name and the whole underlying-error
    /// chain, and the settings row gets a mapped sentence rather than an error
    /// number (#156).
    nonisolated static func describe(
        _ error: Error?,
        eventType: NSPersistentCloudKitContainer.EventType
    ) -> String? {
        guard let error else { return nil }
        let phase = eventName(eventType)
        let ckError = CloudSyncErrorDescription.ckError(in: error)

        if let ckError, ckError.code == .partialFailure,
           let perItem = ckError.partialErrorsByItemID, !perItem.isEmpty
        {
            for (itemID, itemError) in perItem {
                // CloudSyncErrorDescription, not String(reflecting:): conflict
                // errors can dump the whole CKRecord, and synced-playlist
                // records carry server URLs and account credentials.
                Logger.sync.error(
                    "CloudKit \(phase, privacy: .public) rejected \(String(describing: itemID), privacy: .public): \(CloudSyncErrorDescription.logDetail(for: itemError), privacy: .public)"
                )
            }
            // Records usually all fail identically; collapse to the distinct
            // underlying messages so the UI shows the cause, not "error 2".
            let messages = Set(perItem.values.map { CloudSyncErrorDescription.message(for: $0) })
            return messages.sorted().joined(separator: "; ")
        }

        Logger.sync.error(
            "CloudKit \(phase, privacy: .public) failed: \(CloudSyncErrorDescription.logDetail(for: error), privacy: .public)"
        )
        return CloudSyncErrorDescription.message(for: error)
    }

    private nonisolated static func eventName(_ type: NSPersistentCloudKitContainer.EventType) -> String {
        switch type {
        case .setup: "setup"
        case .import: "import"
        case .export: "export"
        @unknown default: "unknown"
        }
    }
}
