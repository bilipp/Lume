//
//  ExternalRatingsView.swift
//  Lume
//
//  The aggregator-ratings row (IMDb, Rotten Tomatoes, Metacritic) shown on the
//  iOS / macOS movie and series detail screens, sourced from OMDb.
//

import SwiftUI

/// A horizontal row of aggregator-rating chips (IMDb, Rotten Tomatoes,
/// Metacritic) sourced from OMDb. Each chip pairs a tinted value with its
/// source name. Renders nothing when there are no ratings.
struct ExternalRatingsView: View {
    let ratings: [ExternalRating]

    var body: some View {
        if !ratings.isEmpty {
            HStack(spacing: 10) {
                ForEach(ratings) { rating in
                    HStack(spacing: 9) {
                        Circle()
                            .fill(rating.tint)
                            .frame(width: 10, height: 10)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(rating.value)
                                .font(.subheadline.weight(.semibold))
                            // Brand names are proper nouns — never localized.
                            Text(rating.source.displayName)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.thinMaterial, in: Capsule())
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(rating.source.displayName): \(rating.value)")
                }
            }
        }
    }
}
