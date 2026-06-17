//
//  SettingsView+Premium.swift
//  Lume
//
//  The Lume Pro surfaces in Settings: the shared paywall helpers, the
//  status / upgrade row that sits first in the iOS/macOS list, the DEBUG-only
//  developer override, and the tvOS Premium pane. Split out of SettingsView to
//  keep that file within the project's line-count cap.
//

import SwiftUI

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

    /// Short status line describing how Premium is unlocked.
    var premiumStatusDetail: String {
        #if !SIDE_LOAD
            if premium.owns(.lifetime) { return String(localized: "Lifetime access") }
            if premium.owns(.monthly) { return String(localized: "Monthly subscription") }
        #endif
        return String(localized: "All features unlocked")
    }
}

#if !os(tvOS)

    extension SettingsView {
        /// The first row in Settings: current Premium status, or a tap-to-upgrade
        /// prompt for free users.
        var premiumStatusSection: some View {
            Section {
                if premium.isPremium {
                    HStack(spacing: 12) {
                        Image(systemName: "crown")
                            .foregroundStyle(.tint)
                            .font(.title3)
                            .frame(width: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Lume Pro")
                            Text(premiumStatusDetail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                } else {
                    Button {
                        presentPaywall(nil)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "crown")
                                .foregroundStyle(.tint)
                                .font(.title3)
                                .frame(width: 30)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Unlock Lume Pro")
                                    .foregroundStyle(.primary)
                                Text("Free plan · See what's included")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            } header: {
                Text("Subscription")
            }
        }

        #if DEBUG && !SIDE_LOAD
            /// DEBUG-only override to preview the free tier and the paywall without
            /// archiving a Release build.
            var developerSection: some View {
                Section {
                    Toggle("Force Premium", isOn: Binding(
                        get: { premium.debugForcePremium },
                        set: { premium.debugForcePremium = $0 }
                    ))
                } header: {
                    Text("Developer")
                } footer: {
                    Text("DEBUG only. Turn off to preview the free tier and the paywall.")
                }
            }
        #endif
    }

#endif

#if os(tvOS)

    extension SettingsView {
        /// The tvOS Premium pane: status, the full benefits list, and upgrade /
        /// restore actions for free users.
        var tvPremiumDetail: some View {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    TVSettingsSectionLabel("Premium")

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
                                ? premiumStatusDetail
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
