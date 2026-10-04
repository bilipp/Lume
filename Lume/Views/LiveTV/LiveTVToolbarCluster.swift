//
//  LiveTVToolbarCluster.swift
//  Lume
//
//  The Live TV toolbar's Recordings and Multi-View buttons, kept side by side
//  as their own cluster — one Liquid Glass capsule on iOS 26 / macOS 26,
//  split from the sort / Sync / Settings cluster by a fixed `ToolbarSpacer`.
//  On iPhone and iPad each button is opt-in from Settings › Live TV; macOS
//  shows both, and visionOS keeps Recordings only.
//

import SwiftUI

/// Settings › Live TV's toolbar switches (iOS / iPadOS only). Both default off.
nonisolated enum LiveTVToolbarSettings {
    static let showsRecordingsKey = "lume.liveTV.showsRecordingsInToolbar"
    static let showsRecordingsDefault = false
    static let showsMultiViewKey = "lume.liveTV.showsMultiViewInToolbar"
    static let showsMultiViewDefault = false
}

extension View {
    /// Adds the Recordings button (once a recording server is paired) and the
    /// Multi-View button (when `multiViewAvailable`) as one cluster. Recordings
    /// without Lume Pro carries the crown and opens the paywall;
    /// `openMultiView` runs Multi-View's own Lume Pro gate. tvOS has no
    /// toolbar: it reaches both from the Live TV rail and the Guide.
    @ViewBuilder
    func liveTVToolbarCluster(multiViewAvailable: Bool, openMultiView: @escaping () -> Void) -> some View {
        #if os(tvOS)
            self
        #else
            modifier(LiveTVToolbarClusterModifier(multiViewAvailable: multiViewAvailable, openMultiView: openMultiView))
        #endif
    }
}

#if !os(tvOS)

    private struct LiveTVToolbarClusterModifier: ViewModifier {
        let multiViewAvailable: Bool
        let openMultiView: () -> Void

        @State private var store = RecordingServerStore.shared
        @State private var showingRecordings = false
        @State private var showingPaywall = false
        @AppStorage(LiveTVToolbarSettings.showsRecordingsKey)
        private var recordingsEnabled = LiveTVToolbarSettings.showsRecordingsDefault
        @AppStorage(LiveTVToolbarSettings.showsMultiViewKey)
        private var multiViewEnabled = LiveTVToolbarSettings.showsMultiViewDefault

        private var showsRecordings: Bool {
            #if os(iOS)
                store.isPaired && recordingsEnabled
            #else
                store.isPaired
            #endif
        }

        private var showsMultiView: Bool {
            #if os(iOS)
                multiViewAvailable && multiViewEnabled
            #elseif os(macOS)
                multiViewAvailable
            #else
                false
            #endif
        }

        func body(content: Content) -> some View {
            content
                .toolbar { cluster }
                .recordingsLibrarySheet(isPresented: $showingRecordings)
                .paywall(isPresented: $showingPaywall, highlight: .recordingServer)
        }

        /// A group of separate buttons, never an HStack in one item: an item
        /// pushed into the "..." overflow needs a menu representation, and a
        /// stack of buttons has none (see `LibraryToolbarModifier`).
        @ToolbarContentBuilder
        private var cluster: some ToolbarContent {
            if showsRecordings || showsMultiView {
                ToolbarItemGroup(placement: .automatic) {
                    if showsRecordings {
                        Button {
                            if store.isUnlocked {
                                showingRecordings = true
                            } else {
                                showingPaywall = true
                            }
                        } label: {
                            Label("Recordings", systemImage: store.isUnlocked ? "recordingtape" : "crown")
                        }
                    }
                    if showsMultiView {
                        Button {
                            openMultiView()
                        } label: {
                            Label("Multi-View", systemImage: "rectangle.split.2x2")
                        }
                    }
                }
                #if os(iOS) || os(macOS)
                    if #available(iOS 26, macOS 26, *) {
                        ToolbarSpacer(.fixed, placement: .automatic)
                    }
                #endif
            }
        }
    }

#endif
