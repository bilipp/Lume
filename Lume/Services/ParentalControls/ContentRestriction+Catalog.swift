//
//  ContentRestriction+Catalog.swift
//  Lume
//
//  Builds a `ContentRestriction` straight from a catalog `ModelContext`, for
//  callers that run outside the view tree and so have no `@Query` to read the
//  categories from (the widget snapshot export, Siri intents).
//
//  The child-profile flag is passed in: `UserProfile` lives in the CloudKit
//  mirror, and these callers read the catalog container only.
//

import Foundation
import SwiftData

nonisolated extension ContentRestriction {
    static func fromCatalog(_ context: ModelContext, isChildProfile: Bool) -> ContentRestriction {
        ContentRestriction(
            isActive: isChildProfile,
            restrictedCategoryIDs: isChildProfile ? categoryIDs(in: context, matching: #Predicate { $0.isRestricted }) : [],
            hiddenCategoryIDs: categoryIDs(in: context, matching: #Predicate { $0.isHidden })
        )
    }

    private static func categoryIDs(
        in context: ModelContext,
        matching predicate: Predicate<Category>
    ) -> Set<String> {
        let categories = (try? context.fetch(FetchDescriptor<Category>(predicate: predicate))) ?? []
        return Set(categories.map(\.id))
    }
}
