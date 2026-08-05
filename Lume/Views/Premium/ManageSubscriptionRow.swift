//
//  ManageSubscriptionRow.swift
//  Lume
//
//  The cancel / change-plan route for subscribers. Apple hosts the actual
//  management UI — we only have to get the user there, which differs per platform:
//
//  • iOS / visionOS — `.manageSubscriptionsSheet` presents Apple's sheet in-app.
//  • macOS — no such sheet exists; the account subscriptions URL opens the App Store.
//  • tvOS — neither is available, so we spell out where to go in Settings.
//
//  Only rendered when `PremiumManager.hasManageableSubscription` is true, so lifetime
//  owners never see a cancel affordance for something that cannot be cancelled.
//

import StoreKit
import SwiftUI

struct ManageSubscriptionRow: View {
    #if os(iOS) || os(visionOS)
        @State private var premium = PremiumManager.shared
        @State private var showManageSheet = false
    #elseif os(macOS)
        @Environment(\.openURL) private var openURL

        /// Opens the App Store app's account subscriptions page.
        private static let accountSubscriptionsURL = URL(string: "https://apps.apple.com/account/subscriptions")!
    #endif

    var body: some View {
        #if os(tvOS)
            // tvOS has no in-app management surface and no way to deep-link the
            // Settings app, so the instructions *are* the feature.
            HStack(alignment: .top, spacing: 18) {
                Image(systemName: "creditcard")
                    .font(.system(size: 26))
                    .foregroundStyle(.tint)
                    .frame(width: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Manage Subscription")
                        .font(.system(size: 24, weight: .semibold))
                    Text("Change or cancel in Settings ▸ Users & Accounts ▸ your Apple Account ▸ Subscriptions.")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        #else
            Button {
                #if os(macOS)
                    openURL(Self.accountSubscriptionsURL)
                #else
                    showManageSheet = true
                #endif
            } label: {
                Label {
                    Text("Manage Subscription")
                        .foregroundStyle(.primary)
                } icon: {
                    Image(systemName: "creditcard")
                        .foregroundStyle(.tint)
                }
            }
            #if os(iOS) || os(visionOS)
            .manageSubscriptionsSheet(isPresented: $showManageSheet)
            // Cancelling in the sheet doesn't revoke the entitlement immediately —
            // the user keeps Pro until the period ends — but `willAutoRenew` flips,
            // so re-read it to update the renewal line behind the sheet.
            .onChange(of: showManageSheet) { _, isPresented in
                guard !isPresented else { return }
                Task { await premium.refreshEntitlements() }
            }
            #endif
        #endif
    }
}
