//
//  IntentEntityLookup.swift
//  Lume
//
//  The shared body of the channel, movie and series entity queries. Siri runs
//  them in the app's process, so they read the same catalog container as
//  `default.store` (registered with `AppDependencyManager` in `LumeApp`) and
//  the profile and plan in effect right now. Read-only and offline.
//

import AppIntents
import Foundation
import SwiftData

/// A catalog title Siri can name. `id` is the playlist-prefixed catalog id the
/// widget deep links use — never a stream URL.
nonisolated protocol IntentCatalogEntity: AppEntity where ID == String {
    static var kind: IntentContentKind { get }
    var title: String { get }
    var playlistName: String { get }
    var showsPlaylistName: Bool { get }
    init(id: String, title: String, playlistName: String, showsPlaylistName: Bool)
}

nonisolated extension IntentCatalogEntity {
    init(item: IntentCatalogItem, showsPlaylistName: Bool) {
        self.init(
            id: item.id,
            title: item.displayTitle,
            playlistName: item.playlistName,
            showsPlaylistName: showsPlaylistName
        )
    }

    /// The prefix-stripped title, with the playlist underneath only when
    /// another listed title reads the same.
    var displayRepresentation: DisplayRepresentation {
        guard showsPlaylistName, !playlistName.isEmpty else {
            return DisplayRepresentation(title: "\(title)")
        }
        return DisplayRepresentation(title: "\(title)", subtitle: "\(playlistName)")
    }
}

/// The query behind each catalog entity, run against the catalog container
/// and the profile in effect.
nonisolated protocol IntentCatalogEntityQuery: EntityStringQuery where Entity: IntentCatalogEntity {
    var catalog: ModelContainer { get }
    var profiles: ProfileManager { get }
}

nonisolated extension IntentCatalogEntityQuery {
    func entities(for identifiers: [String]) async throws -> [Entity] {
        await IntentEntityLookup.entities(for: identifiers, resolver: resolver())
    }

    func entities(matching string: String) async throws -> [Entity] {
        await IntentEntityLookup.entities(matching: string, resolver: resolver())
    }

    func suggestedEntities() async throws -> [Entity] {
        await IntentEntityLookup.suggestedEntities(resolver: resolver())
    }

    private func resolver() async -> IntentCatalogResolver {
        let session = await IntentEntityLookup.currentSession(profiles: profiles)
        return IntentEntityLookup.resolver(container: catalog, session: session)
    }
}

nonisolated enum IntentEntityLookup {
    /// The main-actor state a lookup depends on, read once per query.
    struct Session {
        let isPremium: Bool
        let isChildProfile: Bool
        let storedPlaylistID: String
    }

    private static let matchLimit = 10
    private static let suggestionLimit = 20

    @MainActor
    static func currentSession(profiles: ProfileManager) -> Session {
        Session(
            isPremium: PremiumManager.shared.isPremium,
            isChildProfile: profiles.activeProfileIsChild,
            storedPlaylistID: UserDefaults.standard.string(forKey: PlaylistSelectionStore.key) ?? ""
        )
    }

    /// A fresh catalog context and the restriction it reads for the viewer.
    static func catalogContext(
        container: ModelContainer,
        isChildProfile: Bool
    ) -> (context: ModelContext, restriction: ContentRestriction) {
        let context = ModelContext(container)
        return (context, .fromCatalog(context, isChildProfile: isChildProfile))
    }

    static func resolver(container: ModelContainer, session: Session) -> IntentCatalogResolver {
        let (context, restriction) = catalogContext(container: container, isChildProfile: session.isChildProfile)
        let playlists = (try? context.fetch(FetchDescriptor<Playlist>())) ?? []
        return IntentCatalogResolver(
            context: context,
            playlists: playlists.unlocked(isPremium: session.isPremium),
            restriction: restriction,
            activePlaylistID: playlists.activeID(for: session.storedPlaylistID, isPremium: session.isPremium)
        )
    }

    // MARK: - Query bodies

    static func entities<Entity: IntentCatalogEntity>(
        for ids: [String],
        resolver: IntentCatalogResolver
    ) -> [Entity] {
        entities(from: resolver.items(ids: ids, kind: Entity.kind))
    }

    /// The best match alone, or the matches tied for best so Siri asks which.
    static func entities<Entity: IntentCatalogEntity>(
        matching name: String,
        resolver: IntentCatalogResolver
    ) -> [Entity] {
        let matches = resolver.search(kind: Entity.kind, name: name, limit: matchLimit)
        let count = matches.isAmbiguous ? matches.leadingTieCount : 1
        return entities(from: Array(matches.items.prefix(count)))
    }

    static func suggestedEntities<Entity: IntentCatalogEntity>(resolver: IntentCatalogResolver) -> [Entity] {
        entities(from: resolver.suggested(kind: Entity.kind, limit: suggestionLimit))
    }

    private static func entities<Entity: IntentCatalogEntity>(from items: [IntentCatalogItem]) -> [Entity] {
        var titleCounts: [String: Int] = [:]
        for item in items {
            titleCounts[IntentCatalogResolver.normalized(item.displayTitle), default: 0] += 1
        }
        return items.map { item in
            Entity(
                item: item,
                showsPlaylistName: titleCounts[IntentCatalogResolver.normalized(item.displayTitle), default: 0] > 1
            )
        }
    }
}
