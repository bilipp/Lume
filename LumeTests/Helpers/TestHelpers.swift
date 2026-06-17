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

func exampleDataURL(_ filename: String, filePath: String = #filePath) -> URL {
    var url = URL(fileURLWithPath: filePath)
    while url.lastPathComponent != "LumeTests", url.lastPathComponent != "LumeUITests" {
        url.deleteLastPathComponent()
    }
    url.deleteLastPathComponent()
    return url.appendingPathComponent("ExampleData/\(filename)")
}

func loadExampleJSON<T: Decodable>(_ filename: String, filePath: String = #filePath) throws -> T {
    let url = exampleDataURL(filename, filePath: filePath)
    let data = try Data(contentsOf: url)
    let decoder = JSONDecoder()
    return try decoder.decode(T.self, from: data)
}
