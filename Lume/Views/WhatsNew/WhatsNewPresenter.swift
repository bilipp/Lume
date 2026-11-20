//
//  WhatsNewPresenter.swift
//  Lume
//
//  Raises the What's New sheet from the browse root, once per update, at the
//  first moment the screen is clear.
//
//  A launch that goes into playback instead (a deep link, a quick resume)
//  keeps the release for the next launch: the sheet belongs to opening the
//  app, not to closing a player.
//

import SwiftUI

extension View {
    /// Presents the release this launch has to show, if any. `rootIsCovered`
    /// is the browse root's own presentations.
    func whatsNewSheet(rootIsCovered: Bool) -> some View {
        modifier(WhatsNewPresenter(rootIsCovered: rootIsCovered))
    }
}

private struct WhatsNewPresenter: ViewModifier {
    let rootIsCovered: Bool

    @Environment(\.scenePhase) private var scenePhase
    @State private var presented: WhatsNewRelease?

    /// Long enough for the browse UI to render and a launch-time cover to make
    /// its claim, so the sheet doesn't race the sync cover.
    private static let settleDelay: Duration = .seconds(1)

    private var canPresent: Bool {
        WhatsNewCoordinator.shared.pending != nil
            && scenePhase == .active
            && !rootIsCovered
            && !ScreenOccupancy.shared.coversBrowseRoot
    }

    func body(content: Content) -> some View {
        content
            .task(id: canPresent) {
                guard canPresent else { return }
                try? await Task.sleep(for: Self.settleDelay)
                guard !Task.isCancelled else { return }
                presented = WhatsNewCoordinator.shared.claim()
            }
            .onChange(of: ScreenOccupancy.shared.playerIsVisible) { _, isVisible in
                if isVisible {
                    WhatsNewCoordinator.shared.deferToNextLaunch()
                }
            }
            // Reported like Settings and the paywall, so the rating prompt and
            // the root notices wait for the sheet.
            .onChange(of: presented?.id) { old, new in
                if old == nil, new != nil {
                    ScreenOccupancy.shared.noteBlockingSheetAppeared()
                } else if old != nil, new == nil {
                    ScreenOccupancy.shared.noteBlockingSheetDismissed()
                }
            }
            .whatsNewPresentation(item: $presented)
    }
}

private extension View {
    @ViewBuilder
    func whatsNewPresentation(item: Binding<WhatsNewRelease?>) -> some View {
        #if os(tvOS)
            fullScreenCover(item: item, content: whatsNewSheetContent)
        #else
            sheet(item: item, content: whatsNewSheetContent)
        #endif
    }

    private func whatsNewSheetContent(_ release: WhatsNewRelease) -> some View {
        WhatsNewSheet(release: release)
            .onAppear { WhatsNewCoordinator.shared.noteSheetAppeared() }
    }
}
