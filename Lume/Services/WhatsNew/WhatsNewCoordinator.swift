//
//  WhatsNewCoordinator.swift
//  Lume
//
//  Holds the release this launch wants to show, until one browse root claims
//  it. Every window runs a browse root, so the claim is what keeps the sheet
//  to one of them.
//

import Foundation
import Observation

@MainActor
@Observable
final class WhatsNewCoordinator {
    static let shared = WhatsNewCoordinator()

    /// The release waiting to be shown in this launch.
    private(set) var pending: WhatsNewRelease?
    /// Whether the sheet went up in this launch. The rating prompt stays quiet
    /// for the rest of it.
    private(set) var didPresentThisLaunch = false

    private let store: WhatsNewStore
    private let releases: [WhatsNewRelease]
    private let current: AppVersion?
    private let platform: WhatsNewPlatform
    private var didEvaluate = false

    init(
        store: WhatsNewStore = WhatsNewStore(),
        releases: [WhatsNewRelease] = WhatsNewCatalog.releases,
        current: AppVersion? = AppVersion(SupportInfo.appVersion),
        platform: WhatsNewPlatform = .current
    ) {
        self.store = store
        self.releases = releases
        self.current = current
        self.platform = platform
    }

    /// Evaluates the launch once. A fresh install has nothing to catch up on,
    /// so it only records the version it started with.
    ///
    /// - Parameters:
    ///   - isFreshInstall: no playlist in the catalog at launch.
    ///   - mode: automated runs never show the sheet unless a UI test asks.
    func noteLaunch(isFreshInstall: Bool, mode: Mode = .current) {
        guard !didEvaluate, let current else { return }
        didEvaluate = true

        switch mode {
        case .disabled:
            return
        case .forced:
            pending = WhatsNewPolicy.releaseToPresent(
                lastSeen: AppVersion(0, 0),
                current: current,
                releases: releases,
                platform: platform
            )
            return
        case .normal:
            break
        }

        if store.lastSeenVersion == nil, isFreshInstall {
            store.lastSeenVersion = current
            return
        }
        pending = WhatsNewPolicy.releaseToPresent(
            lastSeen: store.lastSeenVersion,
            current: current,
            releases: releases,
            platform: platform
        )
        if pending == nil {
            store.lastSeenVersion = current
        }
    }

    /// Hands the pending release to the one browse root that shows it.
    func claim() -> WhatsNewRelease? {
        defer { pending = nil }
        return pending
    }

    /// The sheet is on screen: this update is acknowledged, also if the app is
    /// killed before Continue.
    func noteSheetAppeared() {
        didPresentThisLaunch = true
        if let current {
            store.lastSeenVersion = current
        }
    }

    /// Something more important took the screen (a player). The release stays
    /// unseen and is offered again at the next launch.
    func deferToNextLaunch() {
        pending = nil
    }

    enum Mode {
        case normal
        /// Previews, unit tests and UI tests.
        case disabled
        /// A UI test passing `-whats-new`.
        case forced

        static var current: Mode {
            if CommandLine.arguments.contains("-whats-new") { return .forced }
            return LumeApp.isTestOrPreviewHost ? .disabled : .normal
        }
    }
}
