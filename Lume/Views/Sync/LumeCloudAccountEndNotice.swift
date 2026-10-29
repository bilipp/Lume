//
//  LumeCloudAccountEndNotice.swift
//  Lume
//
//  The one-time alert after the server ended this device's Lume Cloud
//  membership (`CloudSyncCoordinator.accountEndNotice`): another device
//  removed this one, or the account was deleted. Raised at the root, because
//  it can happen on any screen during any sync pass.
//
//  Waits for the safe moment `RootNoticeGate` defines.
//

import SwiftUI

extension View {
    /// Shows the coordinator's account-end notice once, then clears it.
    func lumeCloudAccountEndNotice() -> some View {
        modifier(LumeCloudAccountEndNoticeModifier())
    }
}

nonisolated extension LumeCloudAccountEnd {
    /// The alert's message. `returnedToICloud` is false where the device went
    /// Off instead: every revoked device, and a deleted account in a build
    /// without iCloud.
    func noticeMessage(returnedToICloud: Bool) -> LocalizedStringResource {
        switch self {
        case .deviceRevoked:
            "This device was removed from Lume Cloud. Sync is off; your data stays on this device."
        case .accountDeleted where returnedToICloud:
            "Your Lume Cloud account was deleted. Your Apple devices are back on iCloud; your data stays on this device."
        case .accountDeleted:
            "Your Lume Cloud account was deleted. Sync is off; your data stays on this device."
        }
    }
}

private struct LumeCloudAccountEndNoticeModifier: ViewModifier {
    @Environment(CloudSyncCoordinator.self) private var cloudSync: CloudSyncCoordinator?
    @State private var isPresented = false

    func body(content: Content) -> some View {
        content
            .alert("Lume Cloud", isPresented: $isPresented, presenting: cloudSync?.accountEndNotice) { _ in
                Button("OK", role: .cancel) {}
            } message: { notice in
                Text(notice.message)
            }
            .rootNoticeGate(canShow: cloudSync?.accountEndNotice != nil, isPresented: $isPresented) {
                cloudSync?.dismissAccountEndNotice()
            }
    }
}
