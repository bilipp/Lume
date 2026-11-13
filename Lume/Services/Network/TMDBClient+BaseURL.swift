import Foundation

nonisolated extension TMDBClient {
    /// Debug and screenshot builds take `-tmdb-base-url <url>`, so a store
    /// screenshot shoot can route TMDB through the example server's fixed
    /// trending feed. Release builds always talk to TMDB.
    static var configuredBaseURL: String {
        #if DEBUG || SCREENSHOTS
            UserDefaults.standard.string(forKey: "tmdb-base-url") ?? productionBaseURL
        #else
            productionBaseURL
        #endif
    }

    private static let productionBaseURL = "https://api.themoviedb.org/3"
}
