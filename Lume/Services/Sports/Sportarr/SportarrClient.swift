//
//  SportarrClient.swift
//  Lume
//
//  Fixed-origin, keyless metadata reads. The device-local opt-in is checked at
//  the transport boundary as well as by the sync coordinator. Never acquisition.
//

import Foundation

nonisolated enum SportarrSettings {
    static let enabledKey = "sports.sportarrIntegration"
}

nonisolated enum SportarrLookup<Value: Sendable> {
    case found(Value)
    case missing
    case unavailable
    case disabled
}

nonisolated struct SportarrClient: SportarrMetadataProvider {
    private static let baseURL = URL(string: "https://sportarr.net/api/metadata/agents")!
    private let session: URLSession
    private let isEnabled: @Sendable () -> Bool

    init(session: URLSession? = nil, isEnabled: @escaping @Sendable () -> Bool = { UserDefaults.standard.bool(forKey: SportarrSettings.enabledKey) }) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            configuration.timeoutIntervalForRequest = 15
            self.session = URLSession(configuration: configuration)
        }
        self.isEnabled = isEnabled
    }

    func episode(_ id: String) async -> SportarrLookup<SportarrEpisode> {
        guard SportarrIdentifier.canonical(id, prefix: "ev") != nil else { return .missing }
        return await fetch("episode/" + id)
    }

    func series(_ id: String) async -> SportarrLookup<SportarrSeries> {
        guard SportarrIdentifier.canonical(id, prefix: "lg") != nil else { return .missing }
        return await fetch("series/" + id)
    }

    func season(leagueID: String, number: Int) async -> SportarrLookup<SportarrSeason> {
        guard SportarrIdentifier.canonical(leagueID, prefix: "lg") != nil, (1800 ... 3000).contains(number) else { return .missing }
        return await fetch("series/\(leagueID)/season/\(number)/episodes")
    }

    private func fetch<Value: Decodable & Sendable>(_ path: String) async -> SportarrLookup<Value> {
        guard isEnabled(), !Task.isCancelled else { return .disabled }
        var request = URLRequest(url: Self.baseURL.appending(path: path))
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Lume/3.2 (Sportarr metadata)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: request)
            guard isEnabled(), !Task.isCancelled else { return .disabled }
            guard let http = response as? HTTPURLResponse else { return .unavailable }
            if http.statusCode == 404 { return .missing }
            guard (200 ... 299).contains(http.statusCode) else { return .unavailable }
            if let failure = try? JSONDecoder().decode(SportarrFailure.self, from: data), failure.error != nil { return .missing }
            return try .found(JSONDecoder().decode(Value.self, from: data))
        } catch {
            return .unavailable
        }
    }
}

private nonisolated struct SportarrFailure: Decodable {
    let error: String?
}
