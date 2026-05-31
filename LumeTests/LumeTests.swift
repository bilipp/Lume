import SwiftData
import Testing

struct LumeTests {
    @Test func `target loads`() throws {
        // Verify the test target loads correctly by checking that
        // shared test helpers are accessible.
        let container = try makeTestContainer()
        let entityNames = container.schema.entities.map(\.name)
        #expect(entityNames.contains("Playlist"))
        #expect(entityNames.contains("Category"))
        #expect(entityNames.contains("Movie"))
        #expect(entityNames.contains("Series"))
        #expect(entityNames.contains("Episode"))
        #expect(entityNames.contains("LiveStream"))
        #expect(entityNames.contains("EPGListing"))
    }
}
