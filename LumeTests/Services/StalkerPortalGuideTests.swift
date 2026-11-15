import Foundation
@testable import Lume
import SwiftData
import Testing

struct StalkerEPGInfoDecodingTests {
    private func programmes(_ json: String) throws -> [StalkerEPGProgramme] {
        try JSONDecoder().decode(StalkerEnvelope<StalkerEPGInfo>.self, from: Data(json.utf8)).js.programmes
    }

    @Test func `data keyed by channel decodes, filling a missing ch_id from the key`() throws {
        let list = try programmes("""
        {"js":{"data":{
          "7":[{"ch_id":"7","name":"Morning","descr":"News","category":"News",
                "start_timestamp":1700000000,"stop_timestamp":"1700003600"}],
          "8":[{"name":"Film","start_timestamp":"1700000000","stop_timestamp":0}]
        }}}
        """)
        #expect(list.count == 2)
        let film = try #require(list.first { $0.title == "Film" })
        #expect(film.channelId == "8")
        #expect(film.start == 1_700_000_000)
        #expect(film.stop == 0)
        let morning = try #require(list.first { $0.title == "Morning" })
        #expect(morning.stop == 1_700_003_600)
        #expect(morning.description == "News")
        #expect(morning.category == "News")
    }

    @Test func `nested and flat arrays decode, an empty or odd data is no guide`() throws {
        let nested = try programmes(#"{"js":{"data":[[{"ch_id":"1","name":"A","start_timestamp":1}]]}}"#)
        #expect(nested.map(\.channelId) == ["1"])
        let flat = try programmes(#"{"js":{"data":[{"ch_id":"2","name":"B","start_timestamp":1}]}}"#)
        #expect(flat.map(\.channelId) == ["2"])
        #expect(try programmes(#"{"js":{"data":[]}}"#).isEmpty)
        #expect(try programmes(#"{"js":{"data":false}}"#).isEmpty)
        #expect(try programmes(#"{"js":{}}"#).isEmpty)
    }

    @Test func `a debug line printed before the JSON is skipped`() throws {
        let body = #"generated in: 0.512s; query counter: 40; {"js":{"data":{"3":[{"ch_id":"3","name":"C","start_timestamp":5}]}}}"#
        let url = try #require(URL(string: "http://portal.test/c/"))
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        let envelope = try StalkerClient.decodeValidated(
            StalkerEnvelope<StalkerEPGInfo>.self,
            response: response,
            data: Data(body.utf8)
        )
        #expect(envelope.js.programmes.map(\.title) == ["C"])
    }
}

struct StalkerPortalGuideTests {
    private let playlistID = UUID()

    @Test func `the source URL round-trips to its playlist, an XMLTV URL does not`() {
        let url = StalkerPortalGuide.sourceURL(playlistID: playlistID)
        #expect(StalkerPortalGuide.playlistID(fromSourceURL: url) == playlistID)
        #expect(StalkerPortalGuide.playlistID(fromSourceURL: "http://host/xmltv.php") == nil)
    }

    @Test func `a channel keeps its xmltv_id, else gets the playlist-scoped key`() {
        #expect(StalkerPortalGuide.epgChannelId(xmltvId: "news.hd", playlistID: playlistID, streamId: 5) == "news.hd")
        let key = StalkerPortalGuide.epgChannelId(xmltvId: "", playlistID: playlistID, streamId: 5)
        #expect(key == "stalker-\(playlistID.uuidString)-5")
        #expect(StalkerPortalGuide.epgChannelId(xmltvId: nil, playlistID: playlistID, streamId: 5) == key)
    }

    @Test func `programmes land on their channel key and a missing stop ends at the next start`() {
        let entries = [
            StalkerEPGProgramme(channelId: "5", title: "Second", start: 2000, stop: 0),
            StalkerEPGProgramme(channelId: "5", title: "First", category: "News", start: 1000, stop: 0),
            StalkerEPGProgramme(channelId: "5", title: "Fixed", start: 3000, stop: 4000),
            StalkerEPGProgramme(channelId: "9", title: "Unknown channel", start: 1000, stop: 2000),
            StalkerEPGProgramme(channelId: "5", title: "  ", start: 5000, stop: 6000),
            StalkerEPGProgramme(channelId: "5", title: "Backwards", start: 7000, stop: 6500)
        ]
        let result = StalkerPortalGuide.programmes(from: entries, channelKeys: [5: "ch5"])
            .sorted { $0.start < $1.start }

        #expect(result.map(\.title) == ["First", "Second", "Fixed"])
        #expect(result.allSatisfy { $0.channelId == "ch5" })
        #expect(result[0].end == Date(timeIntervalSince1970: 2000))
        #expect(result[0].categories == ["News"])
        #expect(result[1].end == Date(timeIntervalSince1970: 3000))
        #expect(result[2].end == Date(timeIntervalSince1970: 4000))
    }

    @Test func `the last programme without a stop is dropped`() {
        let entries = [StalkerEPGProgramme(channelId: "5", title: "Open", start: 1000, stop: nil)]
        #expect(StalkerPortalGuide.programmes(from: entries, channelKeys: [5: "ch5"]).isEmpty)
    }

    @Test func `a Stalker playlist links its portal guide unless it has an XMLTV URL`() {
        let playlist = Playlist(name: "Portal", portalURL: "http://portal.test/c/", macAddress: "00:1A:79:00:00:00")
        #expect(EPGSourceReconciler.guideURL(for: playlist) == StalkerPortalGuide.sourceURL(playlistID: playlist.id))
        playlist.epgURL = "http://guide.test/epg.xml"
        #expect(EPGSourceReconciler.guideURL(for: playlist) == "http://guide.test/epg.xml")
    }
}

struct StalkerPortalGuideSyncTests {
    @Test func `the portal guide fills the channels an XMLTV source leaves unclaimed`() async throws {
        let now = Int(Date().timeIntervalSince1970)
        let xmltv = """
        <?xml version="1.0" encoding="UTF-8"?>
        <tv>
          <programme start="\(Self.xmltvTime(now))" stop="\(Self.xmltvTime(now + 3600))" channel="news.1">
            <title>XMLTV News</title>
          </programme>
        </tv>
        """
        let guide = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).xml")
        try Data(xmltv.utf8).write(to: guide)
        defer { try? FileManager.default.removeItem(at: guide) }

        let container = try makeTestContainer()
        let context = ModelContext(container)
        let playlist = Playlist(name: "Portal", portalURL: "http://portal.test/c/", macAddress: "00:1A:79:00:00:00")
        context.insert(playlist)
        let key = StalkerPortalGuide.channelKey(playlistID: playlist.id, streamId: 2)
        context.insert(LiveStream(id: "\(playlist.id.uuidString)-live-1", streamId: 1, name: "News", epgChannelId: "news.1"))
        context.insert(LiveStream(id: "\(playlist.id.uuidString)-live-2", streamId: 2, name: "Films", epgChannelId: key))
        // The portal source is older, yet the XMLTV file still claims first.
        context.insert(EPGSource(name: "Portal", url: StalkerPortalGuide.sourceURL(playlistID: playlist.id), playlistID: playlist.id))
        try context.save()
        try await Task.sleep(for: .milliseconds(10))
        context.insert(EPGSource(name: "Manual", url: guide.absoluteString))
        try context.save()

        let fetch: EPGSyncManager.PortalGuideFetch = { configuration, hours in
            #expect(configuration.macAddress == "00:1A:79:00:00:00")
            #expect(hours == StalkerPortalGuide.periodHours)
            return [
                StalkerEPGProgramme(channelId: "1", title: "Portal News", start: now, stop: now + 3600),
                StalkerEPGProgramme(channelId: "2", title: "Portal Film", start: now, stop: now + 7200)
            ]
        }
        let synced = await EPGSyncManager(modelContainer: container, fetchPortalGuide: fetch).syncAllSources()
        #expect(synced)

        let listings = try ModelContext(container).fetch(FetchDescriptor<EPGListing>(sortBy: [SortDescriptor(\.title)]))
        #expect(listings.map(\.title) == ["Portal Film", "XMLTV News"])
        #expect(listings.first?.channelId == key)
    }

    @Test func `a failed portal fetch keeps the guide it had`() async throws {
        let container = try makeTestContainer()
        let context = ModelContext(container)
        let playlist = Playlist(name: "Portal", portalURL: "http://portal.test/c/", macAddress: "00:1A:79:00:00:00")
        context.insert(playlist)
        let key = StalkerPortalGuide.channelKey(playlistID: playlist.id, streamId: 2)
        context.insert(LiveStream(id: "\(playlist.id.uuidString)-live-2", streamId: 2, name: "Films", epgChannelId: key))
        let source = EPGSource(name: "Portal", url: StalkerPortalGuide.sourceURL(playlistID: playlist.id), playlistID: playlist.id)
        context.insert(source)
        try context.save()

        let now = Int(Date().timeIntervalSince1970)
        let first = await EPGSyncManager(modelContainer: container) { _, _ in
            [StalkerEPGProgramme(channelId: "2", title: "Film", start: now, stop: now + 3600)]
        }.syncAllSources()
        #expect(first)

        let second = await EPGSyncManager(modelContainer: container) { _, _ in
            throw StalkerError.authenticationFailed
        }.syncAllSources()
        #expect(!second)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<EPGListing>()) == 1)
        let sourceID = source.id
        let stored = try ModelContext(container).fetch(FetchDescriptor<EPGSource>(predicate: #Predicate { $0.id == sourceID }))
        #expect(stored.first?.syncStatus == .error)
    }

    private static func xmltvTime(_ secs: Int) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMddHHmmss Z"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(secs)))
    }
}
