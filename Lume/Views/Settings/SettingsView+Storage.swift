//
//  SettingsView+Storage.swift
//  Lume
//
//  The "Storage" section's single entry point into `StorageManagementView`,
//  split out of SettingsView to keep that file within the project's
//  line-count cap.
//

import SwiftUI

extension SettingsView {
    #if !os(tvOS)
        /// iOS / macOS grouped-list section.
        var storageSection: some View {
            Section {
                NavigationLink {
                    StorageManagementView()
                } label: {
                    Label("Storage & Cache", systemImage: "internaldrive")
                }
            } header: {
                Text("Storage")
            }
        }
    #endif
}
