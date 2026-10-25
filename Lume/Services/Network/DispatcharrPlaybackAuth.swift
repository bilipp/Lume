//
//  DispatcharrPlaybackAuth.swift
//  Lume
//
//  VLCKit sends no headers, so a Dispatcharr recording's `Authorization:
//  Bearer <JWT>` is folded into a transient `token` query item at the handoff,
//  the same contract as `JellyfinPlaybackAuth`: built at the point of use,
//  never persisted onto a deep link or restoration state. The recording
//  endpoints accept a JWT there (and propagate it to every HLS segment), but
//  never an API key, so an API-key sign-in has no URL form.
//

import Foundation

nonisolated enum DispatcharrPlaybackAuth {
    /// Only a recording endpoint takes `?token=`; a Bearer header on any
    /// other URL is left alone.
    private static let recordingPath = "/api/channels/recordings/"

    /// The JWT inside a playback header value, if it is a Bearer header.
    static func token(from headers: [String: String]?) -> String? {
        guard let value = headers?["Authorization"], value.hasPrefix("Bearer ") else { return nil }
        let token = value.dropFirst("Bearer ".count).trimmingCharacters(in: .whitespaces)
        return token.isEmpty ? nil : token
    }

    static func authenticatedURL(_ url: URL, headers: [String: String]?) -> URL? {
        guard url.path(percentEncoded: false).contains(recordingPath),
              let token = token(from: headers)
        else { return nil }
        return url.addingQueryItemIfAbsent(name: "token", value: token)
    }
}
