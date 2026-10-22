//
//  LumeCloudPairingPresenter.swift
//  Lume
//
//  Presents the add-device sheet a `lume://cloud/pair` link asked for, from
//  the root, once the screen is clear.
//

import SwiftUI

extension View {
    /// Presents the add-device flow a `lume://cloud/pair` link asked for, once
    /// nothing it can't be presented over is on screen. `rootIsCovered` is the
    /// browse root's own presentations, the add-device sheet aside. tvOS never
    /// queues a request: it has no camera to scan a pairing QR with.
    func lumeCloudPairingSheet(router: DeepLinkRouter, rootIsCovered: Bool) -> some View {
        #if os(tvOS)
            self
        #else
            modifier(LumeCloudPairingPresenter(router: router, rootIsCovered: rootIsCovered))
        #endif
    }
}

#if !os(tvOS)

    private struct LumeCloudPairingPresenter: ViewModifier {
        @Bindable var router: DeepLinkRouter
        let rootIsCovered: Bool

        /// Long enough for a sheet or alert dismissed to make room to finish its
        /// transition; the same pause the root notices take. Doubles after each
        /// dropped attempt, up to 30 s.
        private static let settleBackoff = LumeCloudEventListener.Backoff(initial: .seconds(1), maximum: .seconds(30))
        /// How long a presentation may take to appear before it counts as
        /// dropped and goes back to waiting.
        private static let appearanceTimeout: Duration = .seconds(2)

        private struct Attempt: Equatable {
            let waiting: UUID?
            let presented: UUID?
            let screenIsClear: Bool
        }

        private var screenIsClear: Bool {
            !rootIsCovered && !ScreenOccupancy.shared.coversBrowseRoot
        }

        func body(content: Content) -> some View {
            content
                .task(id: Attempt(
                    waiting: router.cloudPairingRequest?.id,
                    presented: router.presentedCloudPairing?.id,
                    screenIsClear: screenIsClear
                )) {
                    if router.presentedCloudPairing != nil {
                        guard !router.cloudPairingSheetAppeared else { return }
                        try? await Task.sleep(for: Self.appearanceTimeout)
                        guard !Task.isCancelled else { return }
                        router.requeueCloudPairingIfNotShown()
                    } else if router.cloudPairingRequest != nil, screenIsClear {
                        try? await Task.sleep(for: Self.settleBackoff.delay(afterFailures: router.cloudPairingMissedAttempts))
                        guard !Task.isCancelled else { return }
                        router.presentPendingCloudPairing(screenIsClear: screenIsClear)
                    }
                }
                .sheet(item: $router.presentedCloudPairing) { request in
                    ParentalGateView(
                        subtitle: "Enter your PIN to add a device to Lume Cloud.",
                        onCancel: { router.presentedCloudPairing = nil },
                        content: { LumeCloudPairingSheet(role: .addDevice(code: request.code)) }
                    )
                    .lumeCloudSheetFrame()
                    .onAppear { router.noteCloudPairingSheetAppeared() }
                }
        }
    }

#endif
