import Foundation

enum XtreamError: Error {
    case invalidURL
    case authenticationFailed
    case networkError(Error)
    case decodingError(Error)
    case invalidResponse
    case serverError(Int)
}

class XtreamClient {
    private let urlSession: URLSession
    
    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }
    
    // MARK: - Helper Methods
    
    private func buildURL(serverURL: String, path: String, queryItems: [URLQueryItem]) -> URL? {
        var components = URLComponents(string: serverURL)
        // Ensure the path is appended properly
        if !(components?.path.hasSuffix("/") ?? false) && !path.hasPrefix("/") {
            components?.path.append("/")
        }
        components?.path.append(path)
        
        let existingItems = components?.queryItems ?? []
        components?.queryItems = existingItems + queryItems
        
        return components?.url
    }
    
    private func request<T: Decodable>(_ url: URL) async throws -> T {
        let (data, response) = try await urlSession.data(from: url)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw XtreamError.invalidResponse
        }
        
        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw XtreamError.authenticationFailed
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            throw XtreamError.serverError(httpResponse.statusCode)
        }
        
        do {
            let decoder = JSONDecoder()
            return try decoder.decode(T.self, from: data)
        } catch {
            throw XtreamError.decodingError(error)
        }
    }
    
    // MARK: - API Methods
    
    /// 1. Get Server and User Info
    func getInfo(playlist: Playlist) async throws -> XtreamAuthResponse {
        let queryItems = [
            URLQueryItem(name: "username", value: playlist.username),
            URLQueryItem(name: "password", value: playlist.password)
        ]
        
        guard let url = buildURL(serverURL: playlist.serverURL, path: "player_api.php", queryItems: queryItems) else {
            throw XtreamError.invalidURL
        }
        
        return try await request(url)
    }
    
    /// 2. Get Live Categories
    func getLiveCategories(playlist: Playlist) async throws -> [XtreamCategory] {
        let queryItems = [
            URLQueryItem(name: "username", value: playlist.username),
            URLQueryItem(name: "password", value: playlist.password),
            URLQueryItem(name: "action", value: "get_live_categories")
        ]
        
        guard let url = buildURL(serverURL: playlist.serverURL, path: "player_api.php", queryItems: queryItems) else {
            throw XtreamError.invalidURL
        }
        
        return try await request(url)
    }
    
    /// 3. Get Live Streams
    func getLiveStreams(playlist: Playlist, categoryId: String? = nil) async throws -> [XtreamLiveStream] {
        var queryItems = [
            URLQueryItem(name: "username", value: playlist.username),
            URLQueryItem(name: "password", value: playlist.password),
            URLQueryItem(name: "action", value: "get_live_streams")
        ]
        if let categoryId = categoryId {
            queryItems.append(URLQueryItem(name: "category_id", value: categoryId))
        }
        
        guard let url = buildURL(serverURL: playlist.serverURL, path: "player_api.php", queryItems: queryItems) else {
            throw XtreamError.invalidURL
        }
        
        return try await request(url)
    }
    
    /// 4. Get VOD Categories
    func getVODCategories(playlist: Playlist) async throws -> [XtreamCategory] {
        let queryItems = [
            URLQueryItem(name: "username", value: playlist.username),
            URLQueryItem(name: "password", value: playlist.password),
            URLQueryItem(name: "action", value: "get_vod_categories")
        ]
        
        guard let url = buildURL(serverURL: playlist.serverURL, path: "player_api.php", queryItems: queryItems) else {
            throw XtreamError.invalidURL
        }
        
        return try await request(url)
    }
    
    /// 5. Get VOD Streams
    func getVODStreams(playlist: Playlist, categoryId: String? = nil) async throws -> [XtreamVODStream] {
        var queryItems = [
            URLQueryItem(name: "username", value: playlist.username),
            URLQueryItem(name: "password", value: playlist.password),
            URLQueryItem(name: "action", value: "get_vod_streams")
        ]
        if let categoryId = categoryId {
            queryItems.append(URLQueryItem(name: "category_id", value: categoryId))
        }
        
        guard let url = buildURL(serverURL: playlist.serverURL, path: "player_api.php", queryItems: queryItems) else {
            throw XtreamError.invalidURL
        }
        
        return try await request(url)
    }
    
    /// 6. Get VOD Info
    func getVODInfo(playlist: Playlist, vodId: Int) async throws -> XtreamVODInfo {
        let queryItems = [
            URLQueryItem(name: "username", value: playlist.username),
            URLQueryItem(name: "password", value: playlist.password),
            URLQueryItem(name: "action", value: "get_vod_info"),
            URLQueryItem(name: "vod_id", value: String(vodId))
        ]
        
        guard let url = buildURL(serverURL: playlist.serverURL, path: "player_api.php", queryItems: queryItems) else {
            throw XtreamError.invalidURL
        }
        
        return try await request(url)
    }
    
    /// 7. Get Series Categories
    func getSeriesCategories(playlist: Playlist) async throws -> [XtreamCategory] {
        let queryItems = [
            URLQueryItem(name: "username", value: playlist.username),
            URLQueryItem(name: "password", value: playlist.password),
            URLQueryItem(name: "action", value: "get_series_categories")
        ]
        
        guard let url = buildURL(serverURL: playlist.serverURL, path: "player_api.php", queryItems: queryItems) else {
            throw XtreamError.invalidURL
        }
        
        return try await request(url)
    }
    
    /// 8. Get Series
    func getSeries(playlist: Playlist, categoryId: String? = nil) async throws -> [XtreamSeries] {
        var queryItems = [
            URLQueryItem(name: "username", value: playlist.username),
            URLQueryItem(name: "password", value: playlist.password),
            URLQueryItem(name: "action", value: "get_series")
        ]
        if let categoryId = categoryId {
            queryItems.append(URLQueryItem(name: "category_id", value: categoryId))
        }
        
        guard let url = buildURL(serverURL: playlist.serverURL, path: "player_api.php", queryItems: queryItems) else {
            throw XtreamError.invalidURL
        }
        
        return try await request(url)
    }
    
    /// 9. Get Series Info
    func getSeriesInfo(playlist: Playlist, seriesId: Int) async throws -> XtreamSeriesInfoResponse {
        let queryItems = [
            URLQueryItem(name: "username", value: playlist.username),
            URLQueryItem(name: "password", value: playlist.password),
            URLQueryItem(name: "action", value: "get_series_info"),
            URLQueryItem(name: "series_id", value: String(seriesId))
        ]
        
        guard let url = buildURL(serverURL: playlist.serverURL, path: "player_api.php", queryItems: queryItems) else {
            throw XtreamError.invalidURL
        }
        
        return try await request(url)
    }
    
    /// 11. Get Short EPG
    func getShortEPG(playlist: Playlist, streamId: Int, limit: Int? = nil) async throws -> [XtreamShortEPG] {
        var queryItems = [
            URLQueryItem(name: "username", value: playlist.username),
            URLQueryItem(name: "password", value: playlist.password),
            URLQueryItem(name: "action", value: "get_short_epg"),
            URLQueryItem(name: "stream_id", value: String(streamId))
        ]
        if let limit = limit {
            queryItems.append(URLQueryItem(name: "limit", value: String(limit)))
        }
        
        guard let url = buildURL(serverURL: playlist.serverURL, path: "player_api.php", queryItems: queryItems) else {
            throw XtreamError.invalidURL
        }
        
        // EPG might come wrapped in a dictionary depending on server, but typically it's an array based on docs.
        // If it comes wrapped as `{"epg_listings": [...]}` we might need to handle it.
        // Assuming array directly based on XtreamAPI.md response description.
        // "Response: List of EpgListing objects..."
        // In many Xtream cases it's actually wrapped. For now, we trust the markdown list.
        
        struct ShortEPGResponse: Decodable {
            let epg_listings: [XtreamShortEPG]
        }
        
        do {
            let response: ShortEPGResponse = try await request(url)
            return response.epg_listings
        } catch {
            // Try array fallback if not wrapped
            if let arrayResponse: [XtreamShortEPG] = try? await request(url) {
                return arrayResponse
            }
            throw error
        }
    }
}
