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
                    ForEach(PremiumFeature.allCases) { feature in
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
        /// The tvOS Lume Pro pane: status, the full benefits list, and upgrade /
        /// restore actions for free users.
        var tvPremiumDetail: some View {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    TVSettingsSectionLabel("Lume Pro")

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
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                    .padding(.vertical, 8)
                }

                VStack(alignment: .leading, spacing: 16) {
                    TVSettingsSectionLabel(premium.isPremium ? "Included" : "Premium Features")
                    ForEach(PremiumFeature.allCases) { feature in
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
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                    }
                }

                if premium.hasManageableSubscription {
                    ManageSubscriptionRow()
                        .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                }

                if !premium.isPremium {
                    Button {
                        presentPaywall(nil)
                    } label: {
                        HStack(spacing: 16) {
                            Image(systemName: "crown")
                                .font(.system(size: 22, weight: .medium))
                            Text("Upgrade to Premium")
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(TVSettingsRowButtonStyle())

                    Button {
                        Task { await premium.restore() }
                    } label: {
                        HStack(spacing: 16) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 22, weight: .medium))
                            Text("Restore Purchases")
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(TVSettingsRowButtonStyle())
                }
            }
        }
    }

#endif
