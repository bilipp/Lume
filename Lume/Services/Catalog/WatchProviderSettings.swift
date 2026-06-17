//
//  WatchProviderSettings.swift
//  Lume
//
//  The user's chosen streaming services. Only the providers selected here are
//  surfaced as "Browse by Provider" sections on the Movies and Series tabs.
//  Backed by UserDefaults — a small set of scalar ids, not structured data.
//

import Foundation
import SwiftUI

@MainActor
@Observable
final class WatchProviderSettings {
    static let shared = WatchProviderSettings()

    private static let storageKey = "content.watchProviders.selected"

    /// The TMDB provider ids the user wants to browse by.
    private(set) var selectedIDs: Set<Int>

    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.storageKey)
        selectedIDs = Set(WatchProviderIDs.decode(raw))
    }

    func isSelected(_ id: Int) -> Bool {
        selectedIDs.contains(id)
    }

    func toggle(_ id: Int) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(WatchProviderIDs.encode(Array(selectedIDs)), forKey: Self.storageKey)
    }
}
