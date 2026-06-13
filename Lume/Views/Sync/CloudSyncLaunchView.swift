//
//  CloudSyncLaunchView.swift
//  Lume
//
//  Shown at launch on a fresh install (empty local store) while we wait for the
//  first iCloud sync to settle, so cloud playlists can land before the
//  add-playlist form appears. Offers a manual escape hatch — the same "Continue
//  Without Syncing" affordance as the catalog-sync screen — so the user is never
//  forced to wait.
//

import SwiftUI

struct CloudSyncLaunchView: View {
    /// Called when the user opts out of the wait and wants the add-playlist form.
    var onSkip: () -> Void

    /// The escape-hatch button is revealed after a short delay so it doesn't
    /// flash on a fast sync that resolves in well under a second.
    @State private var showSkip = false

    var body: some View {
        VStack(spacing: 24) {
            ProgressView()
            #if os(tvOS)
                .scaleEffect(1.5)
            #endif

            Text("Checking iCloud for your playlists…")
                .font(.headline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if showSkip {
                Button("Continue Without Syncing", action: onSkip)
                    .buttonStyle(.bordered)
                    .transition(.opacity)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            try? await Task.sleep(for: .seconds(4))
            withAnimation { showSkip = true }
        }
    }
}

#Preview {
    CloudSyncLaunchView(onSkip: {})
}
