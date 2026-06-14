//
//  ProfileSettings.swift
//  Lume
//
//  User-facing profile preferences persisted in `UserDefaults` (via
//  `@AppStorage`). Distinct from `ActiveProfileStore`, which holds the resolved
//  active-profile id read by the sync engine — these are plain UI options.
//

import Foundation

enum ProfileSettings {
    /// When true, the app shows the "Who's watching?" chooser at every launch
    /// (when more than one profile exists) instead of silently resuming the
    /// last-active profile. Off by default — most setups have a single user.
    static let askOnStartupKey = "profiles.askOnStartup.v1"
    static let askOnStartupDefault = false
}
