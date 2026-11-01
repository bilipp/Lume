//
//  IntentPlayback.swift
//  Lume
//
//  What the play intents share: re-checking Siri's pick for the profile and
//  plan in effect right now, and opening Lume only once there is something to
//  play. Every check runs while the intent is still in the background, so a
//  title that isn't there (or isn't allowed) gets a spoken "not found" and the
//  app stays closed. Read-only and offline; nothing here logs or returns a
//  stream URL.
//

import AppIntents
import Foundation
import SwiftData

nonisolated enum IntentPlaybackError: Error, CustomLocalizedStringResourceConvertible {
    /// Also what a restricted, hidden or plan-locked title reads as, so a
    /// child profile can't tell one from a title that doesn't exist.
    case notFound(IntentContentKind)
    case nothingToResume

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notFound(.channel): "Lume couldn't find that channel."
        case .notFound(.movie): "Lume couldn't find that movie."
        case .notFound(.series): "Lume couldn't find that series."
        case .nothingToResume: "There's nothing to continue watching in Lume."
        }
    }
}

/// A Siri intent that ends by opening Lume on a `DeepLink`. Runs in the
/// background first so a miss never brings the app forward.
nonisolated protocol LumePlaybackIntent: ForegroundContinuableIntent {}

nonisolated extension LumePlaybackIntent {
    /// Plays Siri's pick of a catalog title: re-checked, then opened.
    func play<Entity: IntentCatalogEntity>(
        _ entity: Entity,
        parameter: IntentParameter<Entity>,
        catalog: ModelContainer,
        profiles: ProfileManager
    ) async throws -> some IntentResult {
        let link = try await IntentPlayback.link(of: entity, parameter: parameter, catalog: catalog, profiles: profiles)
        try await openLume(playing: link)
        return .result()
    }

    /// Brings Lume forward and leaves `link` in `IntentRouter` for the browse
    /// root to play once the launch gate clears. The Pro check happens there,
    /// so a free user's request survives the paywall.
    func openLume(playing link: DeepLink) async throws {
        if #available(iOS 26.0, macOS 26.0, tvOS 26.0, visionOS 26.0, *) {
            let mode = systemContext.currentMode
            try await IntentLaunch.open(
                link,
                path: IntentLaunch.path(
                    isForeground: mode == .foreground,
                    canContinueInForeground: mode.canContinueInForeground
                ),
                foreground: { try await continueInForeground(alwaysConfirm: false) },
                refusal: needsToContinueInForegroundError(alwaysConfirm: true)
            )
        } else {
            try await IntentLaunch.queueThenForeground(link) {
                try await requestToContinueInForeground()
            }
        }
    }
}

/// How a play intent reaches the browse root.
@MainActor
enum IntentLaunch {
    nonisolated enum Path: Equatable {
        case alreadyForeground
        case continueInForeground
        /// The app can't come forward, so nothing is left to play later.
        case refuse
    }

    nonisolated static func path(isForeground: Bool, canContinueInForeground: Bool) -> Path {
        if isForeground { return .alreadyForeground }
        return canContinueInForeground ? .continueInForeground : .refuse
    }

    /// A launch that can't come forward never queues its request.
    static func open(
        _ link: DeepLink,
        path: Path,
        router: IntentRouter = .shared,
        foreground: @MainActor () async throws -> Void,
        refusal: any Error
    ) async throws {
        switch path {
        case .alreadyForeground:
            router.enqueue(link, startedBySiri: true)
        case .continueInForeground:
            try await queueThenForeground(link, router: router, foreground: foreground)
        case .refuse:
            throw refusal
        }
    }

    /// The request is queued before `foreground` runs: the launch auto-sync
    /// gate fires as the scene comes up, which can be before foregrounding
    /// returns, and has to see the Siri request to hold the sync. A failed
    /// foregrounding takes the request back out.
    static func queueThenForeground(
        _ link: DeepLink,
        router: IntentRouter = .shared,
        foreground: @MainActor () async throws -> Void
    ) async throws {
        router.enqueue(link, startedBySiri: true)
        do {
            try await foreground()
        } catch {
            router.withdraw(PendingIntent(link: link, startedBySiri: true))
            throw error
        }
    }
}

nonisolated enum IntentPlayback {
    private static let fallbackLimit = 10

    /// The link that plays Siri's pick, checked for the profile and plan in
    /// effect now.
    static func link<Entity: IntentCatalogEntity>(
        of entity: Entity,
        parameter: IntentParameter<Entity>,
        catalog: ModelContainer,
        profiles: ProfileManager
    ) async throws -> DeepLink {
        let session = await IntentEntityLookup.currentSession(profiles: profiles)
        let resolver = IntentEntityLookup.resolver(container: catalog, session: session)
        let id = try await reachableID(of: entity, parameter: parameter, resolver: resolver)
        return try await playLink(kind: Entity.kind, id: id, catalog: catalog, restriction: resolver.restriction)
    }

    /// The catalog id to play for Siri's pick. An entity that can no longer be
    /// reached by id (a resync replaced it) is looked up again by its title,
    /// asking which one when the best matches tie.
    private static func reachableID<Entity: IntentCatalogEntity>(
        of entity: Entity,
        parameter: IntentParameter<Entity>,
        resolver: IntentCatalogResolver
    ) async throws -> String {
        if !resolver.items(ids: [entity.id], kind: Entity.kind).isEmpty {
            return entity.id
        }
        let candidates: [Entity] = IntentEntityLookup.entities(matching: entity.title, resolver: resolver)
        switch candidates.count {
        case 0:
            throw IntentPlaybackError.notFound(Entity.kind)
        case 1:
            return candidates[0].id
        default:
            return try await parameter.requestDisambiguation(among: candidates).id
        }
    }

    /// The link that plays catalog item `id` of `kind`, checked through
    /// `WidgetLinkResolver` against the active profile and plan — the same
    /// check the browse root repeats when it plays the link. A series plays
    /// the episode its Play button would: the one in progress, else the one
    /// after the furthest watched. A series whose episodes were never loaded
    /// opens its detail screen instead.
    @MainActor
    static func playLink(
        kind: IntentContentKind,
        id: String,
        catalog: ModelContainer,
        restriction: ContentRestriction
    ) throws -> DeepLink {
        let context = ModelContext(catalog)
        let link: DeepLink? = switch kind {
        case .channel:
            .playLive(id: id)
        case .movie:
            .playMovie(id: id)
        case .series:
            seriesLink(id: id, in: context, restriction: restriction)
        }
        guard let link, WidgetLinkResolver.resolve(link, in: context, restriction: restriction) != nil else {
            throw IntentPlaybackError.notFound(kind)
        }
        return link
    }

    /// `.resume`, once the stream it reopens is still there for this profile.
    @MainActor
    static func resumeLink(catalog: ModelContainer, profiles: ProfileManager) throws -> DeepLink {
        let (context, restriction) = IntentEntityLookup.catalogContext(
            container: catalog,
            isChildProfile: profiles.activeProfileIsChild
        )
        guard ResumeSnapshotCheck.canResume(in: context, restriction: restriction) else {
            throw IntentPlaybackError.nothingToResume
        }
        return .resume
    }

    @MainActor
    private static func seriesLink(id: String, in context: ModelContext, restriction: ContentRestriction) -> DeepLink? {
        guard case let .openSeries(series)? = WidgetLinkResolver.resolve(
            .openSeries(id: id), in: context, restriction: restriction
        ) else { return nil }
        guard let episode = SeriesEpisodeProgress.nextEpisode(in: series.episodes, fallback: nil) else {
            return .openSeries(id: id)
        }
        return .playEpisode(id: episode.id)
    }
}
