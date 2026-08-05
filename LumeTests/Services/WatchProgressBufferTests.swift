import Foundation
@testable import Lume
import Testing

struct WatchProgressBufferTests {
    init() {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("watchProgress.") {
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: - record

    @Test func `record stashes progress for movie`() {
        let ref = PlayableMedia.ContentRef.movie("m-1")
        WatchProgressBuffer.record(ref: ref, progress: 30, duration: 120)
        let entries = WatchProgressBuffer.drain()
        #expect(entries.count == 1)
        #expect(entries[0].kind == .movie)
        #expect(entries[0].id == "m-1")
        #expect(entries[0].progress == 30)
        #expect(entries[0].duration == 120)
    }

    @Test func `record stashes progress for episode`() {
        let ref = PlayableMedia.ContentRef.episode("e-1")
        WatchProgressBuffer.record(ref: ref, progress: 60, duration: 1800)
        let entries = WatchProgressBuffer.drain()
        #expect(entries.count == 1)
        #expect(entries[0].kind == .episode)
        #expect(entries[0].id == "e-1")
    }

    @Test func `record ignores live stream`() {
        let ref = PlayableMedia.ContentRef.live("l-1")
        WatchProgressBuffer.record(ref: ref, progress: 10, duration: 100)
        let entries = WatchProgressBuffer.drain()
        #expect(entries.isEmpty)
    }

    @Test func `record ignores zero progress`() {
        let ref = PlayableMedia.ContentRef.movie("m-2")
        WatchProgressBuffer.record(ref: ref, progress: 0, duration: 120)
        let entries = WatchProgressBuffer.drain()
        #expect(entries.isEmpty)
    }

    @Test func `record deduplicates same progress value`() {
        let ref = PlayableMedia.ContentRef.movie("m-3")
        WatchProgressBuffer.record(ref: ref, progress: 50, duration: 200)
        WatchProgressBuffer.record(ref: ref, progress: 50, duration: 200)
        let entries = WatchProgressBuffer.drain()
        #expect(entries.count == 1)
    }

    @Test func `record updates when progress changes`() {
        let ref = PlayableMedia.ContentRef.movie("m-4")
        WatchProgressBuffer.record(ref: ref, progress: 10, duration: 100)
        WatchProgressBuffer.record(ref: ref, progress: 25, duration: 100)
        let entries = WatchProgressBuffer.drain()
        #expect(entries.count == 1)
        #expect(entries[0].progress == 25)
    }

    // MARK: - remove

    @Test func `remove clears buffered entry`() {
        let ref = PlayableMedia.ContentRef.movie("m-5")
        WatchProgressBuffer.record(ref: ref, progress: 30, duration: 120)
        WatchProgressBuffer.remove(ref: ref)
        let entries = WatchProgressBuffer.drain()
        #expect(entries.isEmpty)
    }

    @Test func `remove for live stream does nothing`() {
        let ref = PlayableMedia.ContentRef.live("l-2")
        WatchProgressBuffer.remove(ref: ref)
        let entries = WatchProgressBuffer.drain()
        #expect(entries.isEmpty)
    }

    // MARK: - drain

    @Test func `drain returns all entries and clears storage`() {
        let ref1 = PlayableMedia.ContentRef.movie("m-6")
        let ref2 = PlayableMedia.ContentRef.episode("e-2")
        WatchProgressBuffer.record(ref: ref1, progress: 10, duration: 100)
        WatchProgressBuffer.record(ref: ref2, progress: 20, duration: 200)

        let entries = WatchProgressBuffer.drain()
        #expect(entries.count == 2)

        let second = WatchProgressBuffer.drain()
        #expect(second.isEmpty)
    }

    @Test func `drain on empty buffer returns empty`() {
        let entries = WatchProgressBuffer.drain()
        #expect(entries.isEmpty)
    }

    // MARK: - contentRef

    @Test func `entry contentRef matches kind`() {
        let movieEntry = WatchProgressBuffer.Entry(kind: .movie, id: "m-1", progress: 0, duration: 0)
        #expect(movieEntry.contentRef == .movie("m-1"))

        let episodeEntry = WatchProgressBuffer.Entry(kind: .episode, id: "e-1", progress: 0, duration: 0)
        #expect(episodeEntry.contentRef == .episode("e-1"))
    }
}
