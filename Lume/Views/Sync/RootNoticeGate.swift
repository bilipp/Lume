//
//  RootNoticeGate.swift
//  Lume
//
//  The safe moment for a one-time alert raised at the root: the app active,
//  the launch gate open, and nothing blocking on screen — which the root can't
//  see for itself, so it reads `ScreenOccupancy.isRootAlertBlocked`. While the
//  alert is up it counts as a blocking sheet, so the other root presentations
//  wait for it, and it holds `ScreenOccupancy`'s root-notice claim, so the
//  same notice in another window stays down.
//

import SwiftUI

extension View {
    /// Sets `isPresented` once `canShow` holds at a safe moment, and calls
    /// `onDismiss` when the alert goes away.
    func rootNoticeGate(canShow: Bool, isPresented: Binding<Bool>, onDismiss: @escaping () -> Void) -> some View {
        modifier(RootNoticeGate(canShow: canShow, isPresented: isPresented, onDismiss: onDismiss))
    }
}

private struct RootNoticeGate: ViewModifier {
    let canShow: Bool
    @Binding var isPresented: Bool
    let onDismiss: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @Environment(CloudSyncCoordinator.self) private var cloudSync: CloudSyncCoordinator?
    @State private var notice = UUID()

    /// Long enough for a closing player to finish its dismissal transition.
    private static let settleDelay: Duration = .seconds(1)

    private var isSafeMoment: Bool {
        canShow
            && scenePhase == .active
            && cloudSync?.status.isLaunchGateOpen ?? true
            && !ScreenOccupancy.shared.isRootAlertBlocked
            && ScreenOccupancy.shared.canRaiseRootNotice(notice)
    }

    func body(content: Content) -> some View {
        content
            .task(id: isSafeMoment) {
                guard isSafeMoment else { return }
                try? await Task.sleep(for: Self.settleDelay)
                guard !Task.isCancelled, ScreenOccupancy.shared.claimRootNotice(notice) else { return }
                isPresented = true
            }
            .onChange(of: isPresented) { _, presented in
                guard !presented else {
                    ScreenOccupancy.shared.noteBlockingSheetAppeared()
                    return
                }
                ScreenOccupancy.shared.noteBlockingSheetDismissed()
                ScreenOccupancy.shared.releaseRootNotice(notice)
                onDismiss()
            }
            .onDisappear {
                ScreenOccupancy.shared.releaseRootNotice(notice)
            }
    }
}
