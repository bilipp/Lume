import Foundation
@testable import Lume
import SwiftData

func makeTestContainer() throws -> ModelContainer {
    let schema = Schema([
        Playlist.self,
        Lume.Category.self,
        LiveStream.self,
        Movie.self,
        Series.self,
        Episode.self,
        CastMember.self,
        EPGListing.self,
        EPGSource.self
    ])
    // `cloudKitDatabase: .none` is required: the catalog uses `@Attribute(.unique)`,
    // which CloudKit forbids. The default `.automatic` mirrors to CloudKit on a
    // signed/entitled test host and fails the load with `loadIssueModelContainer`.
    let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
    return try ModelContainer(for: schema, configurations: [config])
}

/// The repo root, walked up from a test file's own path: neither the JSON
/// fixtures nor the string catalog are copied into the test bundle.
func repoRootURL(filePath: String = #filePath) -> URL {
    var url = URL(fileURLWithPath: filePath)
    while url.lastPathComponent != "LumeTests", url.lastPathComponent != "LumeUITests", url.pathComponents.count > 1 {
        url.deleteLastPathComponent()
    }
    url.deleteLastPathComponent()
    return url
}

func exampleDataURL(_ filename: String, filePath: String = #filePath) -> URL {
    repoRootURL(filePath: filePath).appendingPathComponent("ExampleData/\(filename)")
}

func loadExampleJSON<T: Decodable>(_ filename: String, filePath: String = #filePath) throws -> T {
    let url = exampleDataURL(filename, filePath: filePath)
    let data = try Data(contentsOf: url)
    let decoder = JSONDecoder()
    return try decoder.decode(T.self, from: data)
}

/// Two-configuration in-memory container: the local catalog plus the CloudKit
/// mirror's models, matching the app's split containers.
///
/// Both configurations pin `cloudKitDatabase: .none`: the catalog uses
/// `@Attribute(.unique)`, which CloudKit forbids, so the default `.automatic`
/// fails the load with `loadIssueModelContainer` on an entitled simulator host.
func makeProfileTestContainer() throws -> ModelContainer {
    let catalogModels: [any PersistentModel.Type] = [
        Playlist.self, Lume.Category.self, LiveStream.self, Movie.self,
        Series.self, Episode.self, CastMember.self, EPGListing.self, EPGSource.self
    ]
    let cloudModels: [any PersistentModel.Type] = [
        SyncedPlaylist.self, UserContentState.self, UserProfile.self, SyncedEPGSource.self,
        SyncedParentalPIN.self, SyncedCategoryRestriction.self
    ]
    let localConfig = ModelConfiguration(
        "local",
        schema: Schema(catalogModels),
        isStoredInMemoryOnly: true,
        cloudKitDatabase: .none
    )
    let cloudConfig = ModelConfiguration(
        "cloud",
        schema: Schema(cloudModels),
        isStoredInMemoryOnly: true,
        cloudKitDatabase: .none
    )
    return try ModelContainer(
        for: Schema(catalogModels + cloudModels),
        configurations: localConfig, cloudConfig
    )
}

/// Minimal reader for `Lume/Localizable.xcstrings`. The catalog is asserted
/// directly because runtime resolution can't tell a translated key from an
/// English one that resolves to itself.
struct StringCatalog {
    let sourceLanguage: String
    private let strings: [String: Any]

    static func localizable(filePath: String = #filePath) throws -> Self {
        let url = repoRootURL(filePath: filePath).appendingPathComponent("Lume/Localizable.xcstrings")
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        return Self(
            sourceLanguage: root?["sourceLanguage"] as? String ?? "en",
            strings: root?["strings"] as? [String: Any] ?? [:]
        )
    }

    /// Every non-source-language translation of `key`, or `nil` when the key is
    /// absent from the catalog entirely.
    func localizations(for key: String) -> [String: String]? {
        guard let entry = strings[key] as? [String: Any] else { return nil }
        let localizations = entry["localizations"] as? [String: Any] ?? [:]
        var resolved: [String: String] = [:]
        for (language, value) in localizations where language != sourceLanguage {
            let unit = (value as? [String: Any])?["stringUnit"] as? [String: Any]
            resolved[language] = unit?["value"] as? String ?? ""
        }
        return resolved
    }
}

/// Clears every `sync.m3uDigest.*` key from the test host's defaults.
///
/// The m3u skip-if-unchanged fingerprint is device-local `UserDefaults` state,
/// so a suite that drives `syncPlaylist` leaves one key behind per playlist it
/// creates. The ids are fresh UUIDs, so a leftover can never make a *later*
/// test skip — but they accumulate in the host for the life of the simulator,
/// and a suite that wants the real import path has to start from a known-clean
/// slate. Call it from a suite's `init()`, which Swift Testing runs before
/// every test in the suite.
func clearM3UDigests() {
    let defaults = UserDefaults.standard
    for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("sync.m3uDigest.") {
        defaults.removeObject(forKey: key)
    }
}
