import Foundation
@testable import Lume
import LumeCloudKit
import SwiftData
import Testing

struct StalkerIdentityStorageTests {
    private func playlist() -> Playlist {
        Playlist(name: "Synthetic", portalURL: "https://portal.example.invalid/stalker_portal/", macAddress: "00:1a:79:00:00:01")
    }

    @Test func `save relaunch and edit retain exact protected identity without plaintext model fields`() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("playlist.store")
        let store = StalkerIdentityStore()
        let identity = StalkerIdentity(serialNumber: "SYNTHETIC-SERIAL", deviceId1: " ONE ", deviceId2: "", signature2: "SIG2")
        let schema = Schema([Playlist.self])
        let config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        var reference: String?
        try autoreleasepool {
            let container = try ModelContainer(for: schema, configurations: config)
            let context = ModelContext(container)
            let playlist = playlist()
            try store.save(identity, for: playlist)
            reference = playlist.stalkerIdentityReference
            context.insert(playlist)
            try context.save()
        }
        defer { if let reference { store.remove(reference: reference) } }
        try autoreleasepool {
            let container = try ModelContainer(for: schema, configurations: config)
            let restored = try #require(ModelContext(container).fetch(FetchDescriptor<Playlist>()).first)
            #expect(try store.load(for: restored) == identity)
            #expect(restored.stalkerIdentityRequired)
            #expect(restored.stalkerIdentityReference == reference)
            let configuration = StalkerClient.Configuration(playlist: restored)
            #expect(configuration.identity == identity)
            #expect(!configuration.identityUnavailable)
            let values = CloudSyncEngine.values(from: restored)
            let encoded = try JSONEncoder().encode(values)
            let json = String(data: encoded, encoding: .utf8) ?? ""
            #expect(!json.contains("SYNTHETIC-SERIAL"))
            #expect(!json.contains(reference ?? "missing-reference"))
        }
    }

    @Test func `missing protected identity and remote account edits fail closed`() throws {
        let playlist = playlist()
        let store = StalkerIdentityStore(service: "LumeTests.stalker.\(UUID().uuidString)")
        #expect(try store.load(for: playlist) == StalkerIdentity())
        try store.save(StalkerIdentity(deviceId1: "ONE"), for: playlist)
        let reference = try #require(playlist.stalkerIdentityReference)
        defer { store.remove(reference: reference) }
        playlist.password = "DIFFERENT-ACCOUNT"
        #expect(throws: StalkerIdentityError.self) { try store.load(for: playlist) }
        playlist.password = ""
        #expect(try store.load(for: playlist).deviceId1 == "ONE")
        playlist.stalkerIdentityReference = nil
        #expect(throws: StalkerIdentityError.self) { try store.load(for: playlist) }
        #expect(StalkerClient.Configuration(playlist: playlist).identityUnavailable)
    }

    @Test func `sync carries required marker but never advanced values and blocks a fresh device`() throws {
        let local = playlist()
        local.stalkerIdentityRequired = true
        local.stalkerIdentityReference = "OPAQUE-LOCAL-REFERENCE"
        let values = CloudSyncEngine.values(from: local)
        let mirror = SyncedPlaylist(id: local.id, value: values)
        #expect(mirror.stalkerIdentityRequired)
        let wire = try LumeCloudPayloadCodec.encoded(mirror, previous: nil)
        let text = String(data: wire, encoding: .utf8) ?? ""
        #expect(!text.contains("OPAQUE-LOCAL-REFERENCE"))
        #expect(!text.contains("deviceId1"))
        let cloudCopy = try LumeCloudPayloadCodec.makeModel(from: LumeCloudPayload.decode(wire), as: SyncedPlaylist.self)
        let fresh = playlist()
        fresh.apply(CloudSyncEngine.values(from: cloudCopy))
        #expect(fresh.stalkerIdentityRequired)
        #expect(fresh.stalkerIdentityReference == nil)
        #expect(StalkerClient.Configuration(playlist: fresh).identityUnavailable)
        // An older sync payload cannot silently disable an installed local identity.
        var old = values
        old.stalkerIdentityRequired = false
        local.apply(old)
        #expect(local.stalkerIdentityRequired)
    }

    @Test func `historical shadow without identity marker still decodes`() throws {
        let values = CloudSyncEngine.values(from: playlist())
        let data = try JSONEncoder().encode(values)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "stalkerIdentityRequired")
        let restored = try JSONDecoder().decode(PlaylistConfigValues.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(!restored.stalkerIdentityRequired)
        #expect(restored.macAddress == values.macAddress)
        #expect(restored.serverURL == values.serverURL)
    }

    @Test func `existing on disk playlist schema migrates without losing account data`() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("historical.store")
        let old = Schema([StalkerLegacySchema.Playlist.self])
        try autoreleasepool {
            let config = ModelConfiguration(schema: old, url: url, cloudKitDatabase: .none)
            let container = try ModelContainer(for: old, configurations: config)
            let context = ModelContext(container)
            let legacy = StalkerLegacySchema.Playlist(
                name: "Synthetic", serverURL: "https://portal.example.invalid/stalker_portal/", username: "", password: ""
            )
            legacy.sourceTypeRaw = "stalker"
            legacy.macAddress = "00:1a:79:00:00:01"
            legacy.categories = [StalkerLegacySchema.Category(apiId: "1", name: "Synthetic genre", parentId: 0, typeRaw: "live", playlist: legacy)]
            context.insert(legacy)
            try context.save()
        }
        try autoreleasepool {
            let current = Schema([Playlist.self])
            let config = ModelConfiguration(schema: current, url: url, cloudKitDatabase: .none)
            let container = try ModelContainer(for: current, configurations: config)
            let context = ModelContext(container)
            let restored = try #require(context.fetch(FetchDescriptor<Playlist>()).first)
            #expect(restored.name == "Synthetic")
            #expect(restored.serverURL == "https://portal.example.invalid/stalker_portal/")
            #expect(restored.macAddress == "00:1a:79:00:00:01")
            #expect(restored.stalkerIdentityReference == nil)
            #expect(!restored.stalkerIdentityRequired)
            #expect(restored.categories.first?.name == "Synthetic genre")
        }
    }
}
