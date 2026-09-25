import Foundation
@testable import Lume
import SwiftData
import Testing

struct ContentSyncManagerLogicTests {
    // MARK: - cleanEpisodeTitle

    @Test func `clean title removes SxxExx prefix`() {
        let result = ContentSyncManager.cleanEpisodeTitle("Breaking Bad - S05E16 - Felina")
        #expect(result == "Felina")
    }

    @Test func `clean title without separator`() {
        let result = ContentSyncManager.cleanEpisodeTitle("Breaking Bad S05E16 Felina")
        #expect(result == "Felina")
    }

    @Test func `clean title with no token returns raw`() {
        let result = ContentSyncManager.cleanEpisodeTitle("Pilot")
        #expect(result == "Pilot")
    }

    @Test func `clean title with NxM format`() {
        let result = ContentSyncManager.cleanEpisodeTitle("Show Name 1x01 First Episode")
        #expect(result == "First Episode")
    }

    @Test func `clean title with token at end returns empty`() {
        let result = ContentSyncManager.cleanEpisodeTitle("Breaking Bad - S05E16")
        #expect(result == "")
    }

    @Test func `clean title with lower case s`() {
        let result = ContentSyncManager.cleanEpisodeTitle("Show s01e02 Title")
        #expect(result == "Title")
    }

    @Test func `clean title nil returns empty`() {
        let result = ContentSyncManager.cleanEpisodeTitle(nil)
        #expect(result == "")
    }

    @Test func `clean title empty returns empty`() {
        let result = ContentSyncManager.cleanEpisodeTitle("")
        #expect(result == "")
    }

    @Test func `clean title whitespace only returns empty`() {
        let result = ContentSyncManager.cleanEpisodeTitle("   ")
        #expect(result == "")
    }

    @Test func `clean title with dash separator`() {
        let result = ContentSyncManager.cleanEpisodeTitle("Show - S01E02 - Episode Name")
        #expect(result == "Episode Name")
    }

    @Test func `clean title with colon separator`() {
        let result = ContentSyncManager.cleanEpisodeTitle("Show: S01E02: Episode Name")
        #expect(result == "Episode Name")
    }

    @Test func `clean title multi season digit`() {
        let result = ContentSyncManager.cleanEpisodeTitle("Show S12 E999 Episode Name")
        #expect(result == "Episode Name")
    }

    @Test func `clean title preserves non ASCII`() {
        let result = ContentSyncManager.cleanEpisodeTitle("Serie S01E01 Pokémon")
        #expect(result == "Pokémon")
    }

    // MARK: - Inter-phase request spacing

    @Test func `no previous request needs no spacing`() {
        #expect(ContentSyncManager.outstandingPhaseSpacing(since: nil) == .zero)
    }

    @Test func `a phase that took longer than the spacing waits not at all`() {
        let now = ContinuousClock.now
        let remaining = ContentSyncManager.outstandingPhaseSpacing(
            since: now - .seconds(45),
            now: now
        )
        #expect(remaining == .zero)
    }

    @Test func `a fast phase waits only the outstanding remainder`() {
        let now = ContinuousClock.now
        let remaining = ContentSyncManager.outstandingPhaseSpacing(
            since: now - .milliseconds(500),
            now: now
        )
        #expect(remaining == .milliseconds(1500))
    }

    @Test func `spacing never exceeds the configured gap`() {
        let now = ContinuousClock.now
        let remaining = ContentSyncManager.outstandingPhaseSpacing(
            since: now + .seconds(30),
            now: now
        )
        #expect(remaining == ContentSyncManager.contentPhaseRequestSpacing)
    }

    @Test func `a phase exactly at the spacing boundary waits not at all`() {
        let now = ContinuousClock.now
        let remaining = ContentSyncManager.outstandingPhaseSpacing(
            since: now - ContentSyncManager.contentPhaseRequestSpacing,
            now: now
        )
        #expect(remaining == .zero)
    }

    // MARK: - historyPurgeIsSafe

    @Test func `history purge refuses the CloudKit mirror configuration`() throws {
        let schema = Schema([
            SyncedPlaylist.self, UserContentState.self, UserProfile.self, SyncedEPGSource.self,
            SyncedParentalPIN.self, SyncedCategoryRestriction.self
        ])
        let mirror = ModelConfiguration(
            ContentSyncManager.cloudMirrorConfigurationName,
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: mirror)
        #expect(ContentSyncManager.historyPurgeIsSafe(for: container.configurations) == false)
    }

    @Test func `history purge allows the local catalog configuration`() throws {
        let schema = Schema([
            Playlist.self, Lume.Category.self, LiveStream.self, Movie.self,
            Series.self, Episode.self, CastMember.self, EPGListing.self, EPGSource.self
        ])
        let catalog = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: catalog)
        #expect(ContentSyncManager.historyPurgeIsSafe(for: container.configurations))
    }

    // MARK: - SyncStatus

    @Test func `playlist idle is default`() {
        let playlist = Playlist(name: "Test", serverURL: "http://x.com", username: "u", password: "p")
        #expect(playlist.syncStatus == .idle)
        #expect(playlist.syncStatusRaw == "idle")
    }

    @Test func `playlist sync status update`() {
        let playlist = Playlist(name: "Test", serverURL: "http://x.com", username: "u", password: "p")
        playlist.syncStatus = .syncing
        #expect(playlist.syncStatusRaw == "syncing")
        playlist.syncStatus = .error
        #expect(playlist.syncStatusRaw == "error")
    }
}
