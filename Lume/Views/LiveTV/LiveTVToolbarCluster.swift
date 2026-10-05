//
//  LiveTVToolbarCluster.swift
//  Lume
//
//  The Live TV toolbar's Recordings and Multi-View buttons, kept side by side
//  as their own cluster — one Liquid Glass capsule on iOS 26 / macOS 26,
//  split from the sort / Sync / Settings cluster by a fixed `ToolbarSpacer`.
//  On iPhone and iPad each button is opt-in from Settings › Live TV; macOS
//  shows both, and visionOS keeps Recordings only. When the bar is too
//  narrow for both, they fold into one menu (see `LiveTVToolbarSpace`).
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
    /// `openMultiView` runs Multi-View's own Lume Pro gate. `switcherTitle` is
    /// the playlist switcher's title when the bar shows one — it competes for
    /// the same room. tvOS has no toolbar: it reaches both from the Live TV
    /// rail and the Guide.
    @ViewBuilder
    func liveTVToolbarCluster(
        multiViewAvailable: Bool,
        switcherTitle: String?,
        openMultiView: @escaping () -> Void
    ) -> some View {
        #if os(tvOS)
            self
        #else
            modifier(LiveTVToolbarClusterModifier(
                multiViewAvailable: multiViewAvailable,
                switcherTitle: switcherTitle,
                openMultiView: openMultiView
            ))
        #endif
    }
}

#if !os(tvOS)

    private struct LiveTVToolbarClusterModifier: ViewModifier {
        let multiViewAvailable: Bool
        let switcherTitle: String?
        let openMultiView: () -> Void

        @State private var store = RecordingServerStore.shared
        @State private var premium = PremiumManager.shared
        @State private var showingRecordings = false
        @State private var showingPaywall = false
        /// Written only when the width crosses `crampedBelowWidth`, so a live
        /// window resize rebuilds the toolbar once, not every frame.
        @State private var isCramped = false
        @AppStorage(LiveTVToolbarSettings.showsRecordingsKey)
        private var recordingsEnabled = LiveTVToolbarSettings.showsRecordingsDefault
        @AppStorage(LiveTVToolbarSettings.showsMultiViewKey)
        private var multiViewEnabled = LiveTVToolbarSettings.showsMultiViewDefault
        #if os(iOS)
            @Environment(\.horizontalSizeClass) private var horizontalSizeClass
            @AppStorage(SportsSyncService.tabEnabledKey)
            private var sportsTabEnabled = SportsSyncService.tabEnabledDefault
        #endif

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
                .background { crampedWidthReader }
                .recordingsLibrarySheet(isPresented: $showingRecordings)
                .paywall(isPresented: $showingPaywall, highlight: .recordingServer)
        }

        /// Maps the width to a Bool, so the action runs only when the
        /// threshold is crossed. Re-identified by the threshold, so a new
        /// playlist name or tab set re-measures against the new one. The Mac
        /// and visionOS toolbars have room and measure nothing.
        @ViewBuilder
        private var crampedWidthReader: some View {
            #if os(iOS)
                let space = toolbarSpace
                Color.clear
                    .onGeometryChange(for: Bool.self) { proxy in
                        space.isCramped(width: proxy.size.width)
                    } action: { cramped in
                        isCramped = cramped
                    }
                    .id(space)
            #endif
        }

        #if os(iOS)
            /// The bar this device lays out: an iPad in a regular-width window
            /// floats its tab bar in the navigation bar; iPhone and a compact
            /// iPad window put it at the bottom.
            private var toolbarSpace: LiveTVToolbarSpace {
                let tabBarOnTop = UIDevice.current.userInterfaceIdiom == .pad && horizontalSizeClass == .regular
                return LiveTVToolbarSpace(
                    tabBarOnTop: tabBarOnTop,
                    tabTitleWidths: tabBarOnTop ? tabTitles.map { Self.width(of: $0, font: Self.tabFont) } : [],
                    switcherTitleWidth: switcherTitle.map { Self.width(of: $0, font: Self.switcherFont) }
                )
            }

            /// Every titled tab but Search (an icon). A playlist can hide
            /// Movies or Series; counting them anyway errs towards the menu.
            private var tabTitles: [String] {
                var titles = [
                    String(localized: "Home"),
                    String(localized: "Movies"),
                    String(localized: "Series"),
                    String(localized: "Live TV")
                ]
                if sportsTabEnabled {
                    titles.append(String(localized: "Sports"))
                }
                return titles
            }

            private static let tabFont = UIFont.systemFont(ofSize: 17)

            /// `PlaylistSwitcher`'s `.headline` title.
            private static var switcherFont: UIFont {
                UIFont.preferredFont(forTextStyle: .headline)
            }

            private static func width(of text: String, font: UIFont) -> CGFloat {
                ceil((text as NSString).size(withAttributes: [.font: font]).width)
            }
        #endif

        /// Separate buttons are a group of toolbar items, never an HStack in
        /// one item: an item pushed into the "..." overflow needs a menu
        /// representation, and a stack of buttons has none (see
        /// `LibraryToolbarModifier`). The combined form is one `Menu` item,
        /// which the overflow shows as a submenu.
        @ToolbarContentBuilder
        private var cluster: some ToolbarContent {
            let layout = LiveTVToolbarClusterLayout(
                showsRecordings: showsRecordings,
                showsMultiView: showsMultiView,
                isCramped: isCramped
            )
            if layout != .hidden {
                if layout == .combined {
                    ToolbarItem(placement: .automatic) {
                        Menu {
                            recordingsButton
                            multiViewButton
                        } label: {
                            Label("Recordings and Multi-View", systemImage: "play.rectangle.on.rectangle")
                        }
                    }
                } else {
                    ToolbarItemGroup(placement: .automatic) {
                        if showsRecordings {
                            recordingsButton
                        }
                        if showsMultiView {
                            multiViewButton
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

        private var recordingsButton: some View {
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

        /// `openMultiView` raises Multi-View's paywall without Lume Pro; the
        /// crown says so up front, as on the Recordings button.
        private var multiViewButton: some View {
            Button {
                openMultiView()
            } label: {
                Label("Multi-View", systemImage: premium.isPremium ? "rectangle.split.2x2" : "crown")
            }
        }
    }

#endif
