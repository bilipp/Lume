//
//  RecommendationSettings.swift
//  Lume
//
//  User preferences for the "For You" recommendations feature. A small scalar
//  flag, so UserDefaults (via @AppStorage) is the right home.
//

import Foundation

nonisolated enum RecommendationSettings {
    /// Whether the "For You" row is built and shown on Home. On by default; the
    /// user can switch recommendations off in Settings.
    static let enabledKey = "recommendations.enabled.v1"
    static let enabledDefault = true
}
