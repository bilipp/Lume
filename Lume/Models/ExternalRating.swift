//
//  ExternalRating.swift
//  Lume
//
//  A critic/audience score for a title from an external aggregator (IMDb,
//  Rotten Tomatoes, Metacritic), sourced from the OMDb API's `Ratings` array.
//  Stored on the SwiftData models as a Codable value (in a `Data` blob, like
//  `TitleVideo`) so the detail screens can render a ratings row without a
//  refetch.
//

import Foundation
import SwiftUI

/// A single external rating with the metadata the detail screens need to render
/// it (display name, brand tint, formatted value).
///
/// `nonisolated` because it is decoded and mapped inside the `nonisolated`
/// ``OMDBClient`` — under this project's default-MainActor isolation a plain
/// type would otherwise pick up a main-actor-isolated `Equatable`/`Hashable`
/// conformance that can't be used off the main actor.
nonisolated struct ExternalRating: Codable, Hashable, Identifiable {
    /// The aggregators we recognise. OMDb reports more (e.g. its own internal
    /// keys), but these three are the ones worth surfacing.
    nonisolated enum Source: String, Codable, CaseIterable {
        case imdb
        case rottenTomatoes
        case metacritic

        /// Maps OMDb's free-text `Source` label to a known source, or nil for
        /// ones we don't display.
        init?(omdbSource: String) {
            switch omdbSource {
            case "Internet Movie Database": self = .imdb
            case "Rotten Tomatoes": self = .rottenTomatoes
            case "Metacritic": self = .metacritic
            default: return nil
            }
        }
    }

    let source: Source
    /// The value exactly as OMDb formats it (e.g. `7.6/10`, `85%`, `67/100`).
    let value: String

    var id: String {
        source.rawValue
    }
}

nonisolated extension ExternalRating.Source {
    /// Short label shown beneath the value.
    var displayName: String {
        switch self {
        case .imdb: "IMDb"
        case .rottenTomatoes: "Rotten Tomatoes"
        case .metacritic: "Metacritic"
        }
    }
}

nonisolated extension ExternalRating {
    /// The numeric portion of `value`, normalised to a 0…100 percentage where it
    /// makes sense — used to colour-code the Rotten Tomatoes / Metacritic chips.
    /// Returns nil for sources without a meaningful threshold (IMDb).
    private var percentScore: Double? {
        switch source {
        case .imdb:
            nil
        case .rottenTomatoes:
            // "85%"
            Double(value.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces))
        case .metacritic:
            // "67/100"
            Double(value.split(separator: "/").first.map(String.init) ?? "")
        }
    }

    /// A compact value for the chip, dropping the denominator
    /// (e.g. `7.6/10` → `7.6`, `67/100` → `67`). Percentages keep their sign.
    var compactValue: String {
        if let slash = value.firstIndex(of: "/") {
            return String(value[value.startIndex ..< slash])
        }
        return value
    }

    /// Brand-ish tint for the chip. Rotten Tomatoes and Metacritic are
    /// colour-coded by score (fresh/rotten · good/mixed/bad); IMDb is gold.
    var tint: Color {
        switch source {
        case .imdb:
            Color(red: 0.96, green: 0.77, blue: 0.13) // IMDb gold
        case .rottenTomatoes:
            // "Fresh" at 60%+.
            if (percentScore ?? 0) >= 60 {
                Color(red: 0.98, green: 0.36, blue: 0.22)
            } else {
                Color(red: 0.45, green: 0.62, blue: 0.86)
            }
        case .metacritic:
            switch percentScore ?? 0 {
            case 61...: Color(red: 0.40, green: 0.73, blue: 0.30) // green
            case 40 ..< 61: Color(red: 0.98, green: 0.79, blue: 0.20) // yellow
            default: Color(red: 0.90, green: 0.30, blue: 0.27) // red
            }
        }
    }
}
