@testable import Lume
import Testing

@MainActor
struct SearchKeyTests {
    @Test func `a visibility change invalidates a settled search`() {
        let settled = key(visibilityToken: "visible-a")
        let afterRestrictionChange = key(visibilityToken: "visible-b")

        #expect(settled != afterRestrictionChange)
    }

    @Test func `a playlist scope change invalidates a settled search`() {
        let settled = key(playlistScopeToken: "playlist-a")
        let afterPlaylistChange = key(playlistScopeToken: "playlist-b")

        #expect(settled != afterPlaylistChange)
    }

    @Test func `unchanged search scope preserves the settled key`() {
        #expect(key() == key())
    }

    private func key(
        playlistScopeToken: String = "playlist-a",
        visibilityToken: String = "visible-a"
    ) -> SearchKey {
        SearchKey(
            text: "arrival",
            filter: .all,
            allPlaylists: false,
            playlistScopeToken: playlistScopeToken,
            visibilityToken: visibilityToken
        )
    }
}
