//
//  SportarrLibraryTests.swift
//  LumeTests
//

import Foundation
@testable import Lume
import SwiftData
import Testing

struct SportarrLibraryTests {
    @Test func `ordinary names cannot classify files and explicit series can classify an unidentified episode`() throws {
        let plain = try JSONDecoder().decode(JellyfinItem.self, from: Data(#"{"Id":"one","Name":"Lions at Patriots","Type":"Episode","Path":"/private/Game.mkv"}"#.utf8))
        #expect(SportarrImportFile.jellyfin(plain, catalogID: "one", series: nil) == nil)
        let parent = SportarrSeriesReference(id: "nfl", title: "NFL", leagueID: "lg-000032", libraryTitle: "Sports")
        let inherited = SportarrImportFile.jellyfin(plain, catalogID: "one", series: parent)
        #expect(inherited?.eventID == nil)
        #expect(inherited?.leagueID == "lg-000032")
        #expect(inherited?.fileName == "Game.mkv")
        #expect(inherited?.kind == .episode)
    }

    @Test func `explicit file tokens survive the lazy episode DTO without retaining private paths`() throws {
        let item = try JSONDecoder().decode(JellyfinItem.self, from: Data(#"{"Id":"one","Name":"Game","Type":"Episode","Path":"https://private.test/folder/Game.{sportarr-ev-123456}.mkv?token=secret-fixture"}"#.utf8))
        let file = try #require(SportarrImportFile.jellyfin(item, catalogID: "one", series: nil))
        #expect(file.eventID == "ev-123456")
        let data = try JSONEncoder().encode(file)
        #expect(data.range(of: Data("private.test".utf8)) == nil)
        #expect(data.range(of: Data("secret-fixture".utf8)) == nil)
        #expect(data.range(of: Data("folder".utf8)) == nil)
    }

    @Test func `missing and restricted catalog rows cannot appear as replays`() async throws {
        let container = try makeTestContainer()
        let context = ModelContext(container)
        let playlist = Playlist(name: "Fixture", serverURL: "https://example.invalid", username: "", password: "")
        context.insert(playlist)
        var index = SportarrPlaylistIndex(playlistID: playlist.id)
        for name in ["visible", "restricted", "missing"] {
            let id = playlist.id.uuidString + "-movie-" + name
            let file = SportarrImportFile(catalogID: id, kind: .movie, eventID: "ev-123456", title: "Same title", date: nil,
                                          seriesID: nil, seriesTitle: nil, leagueID: nil, libraryTitle: nil, seasonNumber: nil, fileName: name, fingerprint: name)
            index.files[id] = SportarrIndexedFile(file: file)
            if name != "missing" {
                let movie = Movie(id: id, streamId: 1, name: name)
                movie.categoryId = name == "restricted" ? "locked" : "open"
                context.insert(movie)
            }
        }
        try context.save()
        let games = await SportarrLibraryCatalog.games(indexes: [index], scope: .isolated(playlist.id), restriction: ContentRestriction(isActive: true, restrictedCategoryIDs: ["locked"]), container: container)
        #expect(games.count == 1)
        #expect(games.first?.libraryFiles.map(\.label) == ["visible"])
        let noScope = await SportarrLibraryCatalog.games(indexes: [index], scope: .empty, restriction: ContentRestriction(), container: container)
        #expect(noScope.isEmpty)
    }

    @Test func `full team names disambiguate shared cities while city-only names stay unresolved`() {
        let league = "espn:football/nfl"
        let date = Date()
        func team(_ id: String, _ name: String) -> SportsTeam {
            SportsTeam(leagueId: league, teamId: id, name: name, shortName: name, abbreviation: id.uppercased())
        }
        let giants = team("nyg", "New York Giants")
        let jets = team("nyj", "New York Jets")
        let commanders = team("wsh", "Washington Commanders")
        let lions = team("det", "Detroit Lions")
        let first = SportsFixture(
            id: "one", leagueId: league, leagueName: "NFL", leagueAbbreviation: "NFL", startDate: date, status: SportsFixtureStatus(state: .final),
            home: SportsCompetitor(team: giants), away: SportsCompetitor(team: commanders)
        )
        let other = SportsFixture(
            id: "two", leagueId: league, leagueName: "NFL", leagueAbbreviation: "NFL", startDate: date, status: SportsFixtureStatus(state: .final),
            home: SportsCompetitor(team: jets), away: SportsCompetitor(team: lions)
        )
        #expect(SportarrFixtureBridge.match(teams: ["New York Giants", "Washington Commanders"], date: date, precise: true, fixtures: [first, other])?.id == "one")
        #expect(SportarrFixtureBridge.match(teams: ["New York", "Washington"], date: date, precise: true, fixtures: [first, other]) == nil)
        #expect(SportarrFixtureBridge.match(teams: ["Giants", "Commanders"], date: date.addingTimeInterval(86400), precise: true, fixtures: [first, other]) == nil)
    }
}
