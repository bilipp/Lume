//
//  JellyfinMediaSourceTests.swift
//  LumeTests
//
//  The source picker's logic, off the player: `PlaybackInfo` decoding, how a
//  version is described, which one plays without asking, what is remembered,
//  and which streams count as a Jellyfin title at all.
//

import Foundation
@testable import Lume
import Testing

private let aioStreamsPlaybackInfo = """
{"MediaSources": [
  {"Protocol": "Http", "Id": "item1", "Type": "Default", "Container": "mkv", "Size": 66678882304.0,
   "Name": "⚡ 4K RD Torrentio\\nDune.Part.Two.2160p.REMUX.mkv", "IsRemote": true,
   "MediaStreams": [{"Type": "Video", "Height": 2160, "Codec": "hevc"}],
   "aiostreams": {"id": "src-remux", "name": "4K RD", "description": "REMUX", "addon": "Torrentio",
     "service": "realdebrid", "cached": true, "resolution": "2160p", "quality": "BluRay REMUX",
     "visualTags": ["HDR10", "DV"], "audioTags": ["Atmos", "TrueHD"], "audioChannels": ["7.1"],
     "languages": ["English"], "size": 66678882304, "type": "debrid", "bingeGroup": "torrentio|rd|2160p"}},
  {"Protocol": "Http", "Id": "src-web", "Type": "Default", "Container": "mp4",
   "Name": "⏳ 1080p TB MediaFusion",
   "aiostreams": {"id": "src-web", "addon": "MediaFusion", "service": "torbox", "cached": false,
     "resolution": "1080p", "quality": "WEB-DL", "visualTags": [], "audioTags": ["DD+"], "bingeGroup": "mf|tb|1080p"}},
  {"Protocol": "Http", "Name": "missing id — skipped, siblings survive"},
  {"Protocol": "Http", "Id": "notice", "Type": "Placeholder", "Name": "ℹ️ 2 streams found"}
], "PlaySessionId": "psid"}
"""

private let stockPlaybackInfo = """
{"MediaSources": [
  {"Id": "v1", "Type": "Default", "Name": "Arrival 4K", "Container": "mkv", "Size": 40000000000,
   "MediaStreams": [
     {"Type": "Video", "Codec": "hevc", "Height": 2160, "VideoRangeType": "DOVIWithHDR10"},
     {"Type": "Audio", "Codec": "eac3", "DisplayTitle": "English - Dolby Digital+ - 5.1"}
   ]},
  {"Id": "v2", "Type": "Default", "Name": "Arrival 1080p", "Container": "mp4",
   "MediaStreams": [{"Type": "Video", "Codec": "h264", "Height": 1080, "VideoRangeType": "SDR"},
                    {"Type": "Audio", "Codec": "aac"}]}
]}
"""

private func decodeOptions(_ json: String) throws -> [MediaSourceOption] {
    let info = try JSONDecoder().decode(JellyfinPlaybackInfo.self, from: Data(json.utf8))
    return MediaSourceOption.options(from: info.mediaSources)
}

private func option(_ id: String, bingeGroup: String? = nil) -> MediaSourceOption {
    MediaSourceOption(source: JellyfinMediaSource(
        id: id, aiostreams: JellyfinSourceExtension(id: id, bingeGroup: bingeGroup)
    ))
}

struct JellyfinMediaSourceTests {
    // MARK: Decoding & description

    @Test func `an AIOStreams listing drops notices and undecodable entries`() throws {
        let options = try decodeOptions(aioStreamsPlaybackInfo)
        #expect(options.map(\.id) == ["src-remux", "src-web"])
        // The first version answers to the item's own id on the stream URL.
        #expect(options.first?.mediaSourceId == "item1")
    }

    @Test func `an AIOStreams version is described from its parsed release`() throws {
        let remux = try #require(try decodeOptions(aioStreamsPlaybackInfo).first)
        #expect(remux.resolution == "4K")
        // Atmos has no technical token without its codec, so it is dropped.
        #expect(remux.tags == ["BluRay REMUX", "HDR10", "DV", "TrueHD"])
        #expect(remux.sizeBytes == 66_678_882_304)
        #expect(remux.isCached == true)
        #expect(remux.provider == "RealDebrid · Torrentio")
        #expect(remux.label?.hasPrefix("⚡ 4K RD Torrentio") == true)
        #expect(remux.bingeGroup == "torrentio|rd|2160p")

        let web = try #require(try decodeOptions(aioStreamsPlaybackInfo).last)
        #expect(web.tags == ["WEB-DL", "E-AC-3"])
        #expect(web.isCached == false)
        #expect(web.provider == "TorBox · MediaFusion")
    }

    @Test func `a stock Jellyfin version is described from its streams`() throws {
        let options = try decodeOptions(stockPlaybackInfo)
        #expect(options.count == 2)
        let uhd = try #require(options.first)
        #expect(uhd.id == "v1")
        #expect(uhd.resolution == "4K")
        #expect(uhd.tags == ["DV", "HEVC", "E-AC-3"])
        #expect(uhd.provider == nil)
        #expect(uhd.label == "Arrival 4K")
        let fullHD = try #require(options.last)
        #expect(fullHD.resolution == "1080p")
        #expect(fullHD.tags == ["H.264", "AAC"])
    }

    @Test func `release tags never carry Dolby word marks`() {
        #expect(MediaSourceOption.technicalTag("Atmos") == nil)
        #expect(MediaSourceOption.technicalTag("Dolby Vision") == "DV")
        #expect(MediaSourceOption.technicalTag("DD+") == "E-AC-3")
        #expect(MediaSourceOption.technicalTag("Dolby Digital") == "AC-3")
        #expect(MediaSourceOption.technicalTag("HDR10+") == "HDR10+")
        #expect(MediaSourceOption.technicalTag("Unknown") == nil)
    }

    // MARK: Auto-pick

    @Test func `a single version plays without asking`() {
        let context = MediaSourceAutoPick.Context(choosesBeforePlaying: true, isResuming: false)
        #expect(MediaSourceAutoPick.pick(from: [option("a")], context: context)?.id == "a")
    }

    @Test func `several versions ask unless the setting is off`() {
        let options = [option("a"), option("b")]
        let asks = MediaSourceAutoPick.Context(choosesBeforePlaying: true, isResuming: false)
        #expect(MediaSourceAutoPick.pick(from: options, context: asks) == nil)
        let plays = MediaSourceAutoPick.Context(choosesBeforePlaying: false, isResuming: false)
        #expect(MediaSourceAutoPick.pick(from: options, context: plays)?.id == "a")
    }

    @Test func `resuming reopens the remembered version while it is offered`() {
        let options = [option("a"), option("b")]
        var context = MediaSourceAutoPick.Context(choosesBeforePlaying: true, isResuming: true, rememberedId: "b")
        #expect(MediaSourceAutoPick.pick(from: options, context: context)?.id == "b")
        context.rememberedId = "gone"
        #expect(MediaSourceAutoPick.pick(from: options, context: context) == nil)
        // From the start, a remembered pick doesn't skip the question.
        context.rememberedId = "b"
        context.isResuming = false
        #expect(MediaSourceAutoPick.pick(from: options, context: context) == nil)
    }

    @Test func `the next episode follows the session's release group`() {
        let options = [option("a", bingeGroup: "g1"), option("b", bingeGroup: "g2")]
        let context = MediaSourceAutoPick.Context(choosesBeforePlaying: true, isResuming: false, bingeGroup: "g2")
        #expect(MediaSourceAutoPick.pick(from: options, context: context)?.id == "b")
    }

    @Test func `after a failure the viewer always chooses`() {
        let context = MediaSourceAutoPick.Context(
            choosesBeforePlaying: false, isResuming: true, rememberedId: "a", bingeGroup: nil, failedIds: ["a"]
        )
        #expect(MediaSourceAutoPick.pick(from: [option("a"), option("b")], context: context) == nil)
    }

    // MARK: Remembered picks

    @Test func `picks are remembered per title and capped`() throws {
        let suite = "jellyfin-picks-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let start = Date(timeIntervalSince1970: 1_000_000)
        MediaSourcePreferences.remember("v2", for: .movie("m1"), at: start.addingTimeInterval(-1), defaults: defaults)
        #expect(MediaSourcePreferences.rememberedSourceId(for: .movie("m1"), defaults: defaults) == "v2")
        #expect(MediaSourcePreferences.rememberedSourceId(for: .movie("m2"), defaults: defaults) == nil)
        // Live channels have no versions to remember.
        MediaSourcePreferences.remember("x", for: .live("c1"), defaults: defaults)
        #expect(MediaSourcePreferences.rememberedSourceId(for: .live("c1"), defaults: defaults) == nil)

        for index in 0 ... MediaSourcePreferences.capacity {
            MediaSourcePreferences.remember("v", for: .episode("e\(index)"), at: start.addingTimeInterval(Double(index)), defaults: defaults)
        }
        // The oldest entries — the movie, then the first episode — made room.
        #expect(MediaSourcePreferences.rememberedSourceId(for: .movie("m1"), defaults: defaults) == nil)
        #expect(MediaSourcePreferences.rememberedSourceId(for: .episode("e0"), defaults: defaults) == nil)
        #expect(MediaSourcePreferences.rememberedSourceId(for: .episode("e\(MediaSourcePreferences.capacity)"), defaults: defaults) == "v")
    }

    // MARK: Stream links

    private func media(url: String, headers: [String: String]?, kind: PlayableMedia.Kind = .vod) throws -> PlayableMedia {
        try PlayableMedia(
            id: "m", url: #require(URL(string: url)), title: "T", subtitle: nil, posterURL: nil,
            kind: kind, startTime: 0, contentRef: .movie("m"), httpHeaders: headers
        )
    }

    @Test func `only a session-authorised Jellyfin stream link is a title with versions`() throws {
        let headers = JellyfinClient.playbackHeaders(token: "tok")
        let link = "http://nas:8096/jellyfin/Videos/abc123/stream?Static=true"
        #expect(try JellyfinSourceResolver.itemId(for: media(url: link, headers: headers)) == "abc123")
        #expect(try JellyfinSourceResolver.itemId(for: media(url: link, headers: nil)) == nil)
        #expect(try JellyfinSourceResolver.itemId(for: media(url: link, headers: headers, kind: .live)) == nil)
        #expect(try JellyfinSourceResolver.itemId(for: media(url: "http://nas/movie/u/p/1.mkv", headers: headers)) == nil)
        // WebDAV's Basic header is not a media-server session.
        let basic = ["Authorization": "Basic dTpw"]
        #expect(try JellyfinSourceResolver.itemId(for: media(url: link, headers: basic)) == nil)
    }

    @Test func `playing a version names it on the stream URL and keeps the identity`() throws {
        let original = try media(url: "http://nas:8096/Videos/abc/stream?Static=true", headers: JellyfinClient.playbackHeaders(token: "old"))
        let fresh = JellyfinClient.playbackHeaders(token: "new")
        let first = JellyfinSourceResolver.media(original, playing: option("v2"), headers: fresh, startTime: 42)
        #expect(first.url.absoluteString == "http://nas:8096/Videos/abc/stream?Static=true&MediaSourceId=v2")
        #expect(first.id == original.id)
        #expect(first.contentRef == original.contentRef)
        #expect(first.startTime == 42)
        #expect(first.httpHeaders == fresh)
        // Switching again replaces the version rather than adding a second one.
        let second = JellyfinSourceResolver.media(first, playing: option("v3"), headers: nil, startTime: 0)
        #expect(second.url.absoluteString == "http://nas:8096/Videos/abc/stream?Static=true&MediaSourceId=v3")
        #expect(second.httpHeaders == fresh)
    }

    @Test func `the stream URL builder names a version only when asked`() throws {
        let server = try #require(URL(string: "http://nas:8096"))
        #expect(JellyfinClient.streamURL(server: server, itemId: "i")?.absoluteString == "http://nas:8096/Videos/i/stream?Static=true")
        #expect(JellyfinClient.streamURL(server: server, itemId: "i", mediaSourceId: "s")?.absoluteString
            == "http://nas:8096/Videos/i/stream?Static=true&MediaSourceId=s")
    }
}
