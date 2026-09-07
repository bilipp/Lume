//
//  OnboardingUsageProbe.swift
//  Lume
//
//  The upgrade-suppression signal for the "How Lume Works" guide: does the
//  CloudKit-mirrored user state show real usage from before this build?
//
//  Deliberately reads the *cloud* store (`UserContentState`, `UserProfile`) and
//  never the catalog: a catalog that comes up `.unreadable` or
//  `.emptiedButHadData` (see `CloudSyncEngine.localCatalogReadiness()`) drops a
//  long-time user into the empty-store launch branch, which is exactly the case
//  this signal has to survive. A playlist count would read that user as brand new.
//

import Foundation
import SwiftData

enum OnboardingUsageProbe {
    /// True when this Apple ID's synced user state shows the app has really been
    /// used before — watch progress, or a profile the user created themselves.
    ///
    /// - Parameter context: a `ModelContext` on the CloudKit-mirrored
    ///   `CloudUserData` container.
    static func hasPriorUsage(in context: ModelContext) -> Bool {
        hasWatchProgress(in: context) || hasNonDefaultProfile(in: context)
    }

    /// A throwing probe reads as "no prior usage" on purpose: a false negative
    /// costs an existing user one skippable guide, while a false positive would
    /// seed the seen-version and silently retire the guide for a genuinely new
    /// install.
    private static func hasWatchProgress(in context: ModelContext) -> Bool {
        var descriptor = FetchDescriptor<UserContentState>(
            predicate: #Predicate { $0.watchProgress > 0 || $0.isWatched || $0.lastWatchedDate != nil }
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor).isEmpty) == false
    }

    /// The default profile is created by bootstrap on every install, so it proves
    /// nothing; only a profile the user added themselves counts.
    private static func hasNonDefaultProfile(in context: ModelContext) -> Bool {
        let defaultID = UserProfile.defaultProfileID
        var descriptor = FetchDescriptor<UserProfile>(predicate: #Predicate { $0.id != defaultID })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor).isEmpty) == false
    }
}
