//
//  SettingsView+Premium.swift
//  Lume
//
//  The Lume Pro surfaces in Settings: the shared paywall helpers, the plan
//  details page behind the iOS / macOS Lume Pro row, the DEBUG-only developer
//  page, and the tvOS Lume Pro pane. Split out of SettingsView to keep that
//  file within the project's line-count cap.
//

import SwiftUI

extension PremiumManager {
    /// Which plan is unlocking Premium — the headline of the plan details.
    var planTitle: String {
        #if !SIDE_LOAD
            // A lifetime unlock outranks a subscription: it can't lapse, so that's the
            // more useful thing to show if someone somehow holds both. The retired
            // non-consumable is lifetime access too — it just never renewed.
            if owns(.lifetime) || owns(.retiredMonthly) {
                return String(localized: "Lifetime access")
            }
            if owns(.monthly) { return String(localized: "Monthly subscription") }
        #endif
        return String(localized: "All features unlocked")
    }

    /// Billing line under the plan title: the next charge date, the cut-off date once
    /// cancelled, or a prompt to fix a failed payment. Nil for anything that doesn't
    /// renew, so lifetime owners never see a billing date.
    var renewalDetail: String? {
        guard owns(.monthly), let status = subscriptionStatus else { return nil }
        if status.isInBillingRetry {
            return String(localized: "Payment issue — update your payment method")
        }
        guard let renewsAt = status.renewsAt else { return nil }
        let date = renewsAt.formatted(date: .abbreviated, time: .omitted)
        let format = status.willAutoRenew
            ? String(localized: "Renews %@")
            : String(localized: "Ends %@")
        return String(format: format, date)
    }

    /// Plan and billing state on one line, for the tvOS pane's single subtitle slot.
    var statusDetail: String {
        guard let renewalDetail else { return planTitle }
        return "\(planTitle) · \(renewalDetail)"
    }
}

extension SettingsView {
    /// Sets the highlighted feature and presents the paywall.
    func presentPaywall(_ feature: PremiumFeature? = nil) {
        paywallHighlight = feature
        showPaywall = true
    }

    /// Whether a new playlist can be added for free (first playlist always free).
    var canAddPlaylist: Bool {
        premium.isPremium || playlists.isEmpty
    }
}

#if !os(tvOS)

    /// The page behind the Lume Pro row once Pro is unlocked: the plan, its
    /// billing state, and what it includes. Free users get the paywall instead.
    struct PremiumPlanView: View {
        @State private var premium = PremiumManager.shared

        var body: some View {
            List {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "crown")
                            .foregroundStyle(.tint)
                            .font(.title3)
                            .frame(width: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(premium.planTitle)
                            if let renewalDetail = premium.renewalDetail {
                                Text(renewalDetail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 2)

                    // Subscribers must always have a route to cancel; lifetime owners
                    // have nothing to manage, so they don't get this row.
                    if premium.hasManageableSubscription {
                        ManageSubscriptionRow()
                    }
                }

                Section {
                    ForEach(PremiumFeature.available) { feature in
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(feature.title)
                                Text(feature.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: feature.systemImage)
                                .foregroundStyle(.tint)
                        }
                    }
                } header: {
                    Text("Included")
                }
            }
            .platformNavigationTitle("Lume Pro")
        }
    }

    #if DEBUG && !SIDE_LOAD
        /// DEBUG-only overrides to preview the free tier and the paywall without
        /// archiving a Release build.
        struct DeveloperSettingsView: View {
            @State private var premium = PremiumManager.shared
            /// Force-recompute counter the For You row watches.
            @AppStorage(RecommendationSettings.manualRecalculationKey) private var recommendationsRecalcToken = 0

            var body: some View {
                List {
                    Section {
                        Toggle("Force Premium", isOn: Binding(
                            get: { premium.debugForcePremium },
                            set: { premium.debugForcePremium = $0 }
                        ))

                        Button("Recalculate Recommendations") {
                            RecommendationCacheStore().clear(for: ActiveProfileStore.current)
                            recommendationsRecalcToken += 1
                        }
                    } footer: {
                        Text("DEBUG only. Force Premium previews the free tier and paywall. Recalculate rebuilds the For You row now, bypassing the once-a-day throttle.")
                    }
                }
                .platformNavigationTitle("Developer")
            }
        }
    #endif

#endif

#if os(tvOS)

    extension SettingsView {
        /// The tvOS Lume Pro pane, across the pane's full width: status and
        /// the upgrade / restore actions side by side, then the benefits in
        /// two columns. Nothing below the actions can take focus, so focus
        /// never scrolls the pane: it all has to fit on one screen.
        var tvPremiumDetail: some View {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    TVSettingsSectionLabel("Lume Pro")
                    HStack(alignment: .center, spacing: 32) {
                        tvPremiumStatus
                        Spacer(minLength: 0)
                        tvPremiumActions
                    }
                }

                VStack(alignment: .leading, spacing: 16) {
                    TVSettingsSectionLabel(premium.isPremium ? "Included" : "Premium Features")
                    tvPremiumFeatureGrid
                }
            }
        }

        private var tvPremiumStatus: some View {
            HStack(spacing: 18) {
                Image(systemName: "crown")
                    .font(.system(size: 28))
                    .foregroundStyle(.tint)
                    .frame(width: 60, height: 60)
                    .background(.tint.opacity(0.12), in: .rect(cornerRadius: 14, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(premium.isPremium ? "Lume Pro" : "Free Plan")
                        .font(.system(size: 26, weight: .semibold))
                    Text(premium.isPremium
                        ? premium.statusDetail
                        : String(localized: "Upgrade to unlock the features below"))
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, TVSettingsMetrics.rowHPadding)
            .padding(.vertical, 8)
        }

        @ViewBuilder
        private var tvPremiumActions: some View {
            if !premium.isPremium {
                HStack(spacing: 16) {
                    Button {
                        presentPaywall(nil)
                    } label: {
                        Label("Upgrade to Premium", systemImage: "crown")
                    }
                    .buttonStyle(TVSettingsActionButtonStyle(prominent: true))

                    Button {
                        Task { await premium.restore() }
                    } label: {
                        Label("Restore Purchases", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(TVSettingsActionButtonStyle())
                }
            } else if premium.hasManageableSubscription {
                ManageSubscriptionRow()
                    .frame(maxWidth: 620)
                    .padding(.horizontal, TVSettingsMetrics.rowHPadding)
            }
        }

        /// The benefits two to a row, so every row is as tall as its taller
        /// entry and the columns stay aligned.
        private var tvPremiumFeatureGrid: some View {
            let features = PremiumFeature.available
            return Grid(alignment: .topLeading, horizontalSpacing: 40, verticalSpacing: 22) {
                ForEach(Array(stride(from: 0, to: features.count, by: 2)), id: \.self) { index in
                    GridRow {
                        tvPremiumFeatureRow(features[index])
                        if index + 1 < features.count {
                            tvPremiumFeatureRow(features[index + 1])
                        } else {
                            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        }
                    }
                }
            }
            .padding(.horizontal, TVSettingsMetrics.rowHPadding)
        }

        private func tvPremiumFeatureRow(_ feature: PremiumFeature) -> some View {
            HStack(alignment: .top, spacing: 18) {
                Image(systemName: feature.systemImage)
                    .font(.system(size: 26))
                    .foregroundStyle(.tint)
                    .frame(width: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(feature.title).font(.system(size: 24, weight: .semibold))
                    Text(feature.subtitle)
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

#endif
