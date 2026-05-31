import Foundation
import SwiftData

// MARK: - Helper Methods

extension ContentSyncManager {
    func markPlaylistError(playlistId: UUID) {
        let errContext = ModelContext(modelContainer)
        errContext.autosaveEnabled = false
        if let epl = try? errContext.fetch(
            FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == playlistId })
        ).first {
            epl.syncStatus = .error
            try? errContext.save()
        }
    }

    func updatePlaylistInfo(_ playlistId: UUID, with authResponse: XtreamAuthResponse) {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        guard let playlist = try? context.fetch(
            FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == playlistId })
        ).first else { return }

        playlist.userStatus = authResponse.userInfo.status
        playlist.maxConnections = authResponse.userInfo.maxConnections
        playlist.activeConnections = authResponse.userInfo.activeCons
        playlist.expDate = authResponse.userInfo.expDate
        playlist.serverTimezone = authResponse.serverInfo.timezone
        playlist.lastUpdated = Date()
        try? context.save()
    }

    func buildExistingCategoryLookup(context: ModelContext, playlistId: UUID, type: CategoryType) -> [String: Category] {
        let prefix = "\(playlistId.uuidString)-\(type.rawValue)-"
        let typeRaw = type.rawValue
        let descriptor = FetchDescriptor<Category>(
            predicate: #Predicate { $0.typeRaw == typeRaw }
        )
        guard let allCategories = try? context.fetch(descriptor) else { return [:] }
        var lookup: [String: Category] = [:]
        lookup.reserveCapacity(allCategories.count)
        for category in allCategories where category.id.hasPrefix(prefix) {
            lookup[category.apiId] = category
        }
        return lookup
    }
}
