//
//  PaywallView.swift
//  Lume
//
//  The Lume Premium paywall: benefits list + the two plans (monthly subscription,
//  one-time lifetime). Presented as a sheet whenever a free user reaches a gated
//  feature, and from the Premium status row in Settings. Never shown in sideloaded
//  builds (those are always Premium).
//

import StoreKit
import SwiftUI

struct PaywallView: View {
    /// The feature that triggered the paywall, highlighted at the top. Nil when
    /// opened from the Settings status row (a general upgrade prompt).
    var highlight: PremiumFeature?

    @State private var premium = PremiumManager.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    /// Apple's standard EULA, plus Lume's privacy policy. Subscriptions must link
    /// to terms of use and a privacy policy on the purchase screen.
    private static let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    private static let privacyURL = URL(string: "https://github.com/bilipp/Lume/blob/main/PRIVACY.md")!

    var body: some View {
        #if os(tvOS)
            tvBody
        #else
            standardBody
        #endif
    }

    /// The features shown as benefits — the highlighted one first, if any.
    private var orderedFeatures: [PremiumFeature] {
        guard let highlight else { return PremiumFeature.allCases }
        return [highlight] + PremiumFeature.allCases.filter { $0 != highlight }
    }

    // MARK: - iOS / macOS

    #if !os(tvOS)
        private var standardBody: some View {
            NavigationStack {
                ScrollView {
                    VStack(spacing: 28) {
                        header
                        benefitsList
                        planButtons
                        legalFooter
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 24)
                    .frame(maxWidth: 520)
                    .frame(maxWidth: .infinity)
                }
                .navigationTitle("Lume Premium")
                #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                #endif
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { dismiss() }
                        }
                        ToolbarItem(placement: .primaryAction) {
                            Button("Restore") {
                                Task { await premium.restore() }
                            }
                            .disabled(premium.isWorking)
                        }
                    }
                    .onChange(of: premium.isPremium) { _, isPremium in
                        if isPremium { dismiss() }
                    }
            }
            #if os(macOS)
            .frame(minWidth: 460, idealWidth: 520, minHeight: 560, idealHeight: 680)
            #endif
        }

        private var header: some View {
            VStack(spacing: 10) {
                Image(systemName: "crown")
                    .font(.system(size: 44))
                    .foregroundStyle(.tint)
                Text("Unlock Lume Premium")
                    .font(.title.bold())
                    .multilineTextAlignment(.center)
                Text("Lume is free and open source. Premium supports development and unlocks a few extra conveniences.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }

        private var benefitsList: some View {
            VStack(spacing: 16) {
                ForEach(orderedFeatures) { feature in
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: feature.systemImage)
                            .font(.title3)
                            .foregroundStyle(.tint)
                            .frame(width: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(feature.title).font(.headline)
                            Text(feature.subtitle)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }

        @ViewBuilder
        private var planButtons: some View {
            if premium.products.isEmpty {
                ProgressView().padding(.vertical, 12)
            } else {
                VStack(spacing: 12) {
                    ForEach(premium.products, id: \.id) { product in
                        Button {
                            Task { await premium.purchase(product) }
                        } label: {
                            planLabel(for: product)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(premium.isWorking)
                    }
                }
            }
        }

        private func planLabel(for product: Product) -> some View {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(planTitle(for: product)).fontWeight(.semibold)
                    if let caption = planCaption(for: product) {
                        Text(caption).font(.caption).opacity(0.9)
                    }
                }
                Spacer()
                Text(product.displayPrice).fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
        }
    #endif

    // MARK: - tvOS

    #if os(tvOS)
        private var tvBody: some View {
            ScrollView {
                HStack(alignment: .top, spacing: 60) {
                    VStack(alignment: .leading, spacing: 18) {
                        Image(systemName: "crown")
                            .font(.system(size: 56))
                            .foregroundStyle(.tint)
                        Text("Lume Premium")
                            .font(.system(size: 48, weight: .bold))
                        Text("Lume is free and open source. Premium supports development and unlocks a few extra conveniences.")
                            .font(.system(size: 24))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: 560, alignment: .leading)

                        VStack(alignment: .leading, spacing: 18) {
                            ForEach(orderedFeatures) { feature in
                                HStack(alignment: .top, spacing: 18) {
                                    Image(systemName: feature.systemImage)
                                        .font(.system(size: 28))
                                        .foregroundStyle(.tint)
                                        .frame(width: 44)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(feature.title).font(.system(size: 26, weight: .semibold))
                                        Text(feature.subtitle)
                                            .font(.system(size: 22))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .padding(.top, 12)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(spacing: 20) {
                        if premium.products.isEmpty {
                            ProgressView()
                        } else {
                            ForEach(premium.products, id: \.id) { product in
                                Button {
                                    Task { await premium.purchase(product) }
                                } label: {
                                    VStack(spacing: 4) {
                                        Text(planTitle(for: product))
                                            .font(.system(size: 26, weight: .semibold))
                                        Text(product.displayPrice)
                                            .font(.system(size: 22))
                                        if let caption = planCaption(for: product) {
                                            Text(caption)
                                                .font(.system(size: 18))
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                }
                                .disabled(premium.isWorking)
                            }
                        }

                        Button("Restore Purchases") {
                            Task { await premium.restore() }
                        }
                        .disabled(premium.isWorking)

                        Button("Not Now") { dismiss() }
                    }
                    .frame(width: 460)
                }
                .padding(80)
            }
            .onChange(of: premium.isPremium) { _, isPremium in
                if isPremium { dismiss() }
            }
        }
    #endif

    // MARK: - Plan copy

    private func planTitle(for product: Product) -> String {
        switch product.id {
        case PremiumManager.Plan.lifetime.rawValue: String(localized: "Lifetime")
        case PremiumManager.Plan.monthly.rawValue: String(localized: "Monthly")
        default: product.displayName
        }
    }

    private func planCaption(for product: Product) -> String? {
        switch product.id {
        case PremiumManager.Plan.lifetime.rawValue: String(localized: "One-time purchase")
        case PremiumManager.Plan.monthly.rawValue: String(localized: "Billed monthly, cancel anytime")
        default: nil
        }
    }

    #if !os(tvOS)
        private var legalFooter: some View {
            VStack(spacing: 8) {
                // swiftlint:disable:next line_length
                Text("Payment is charged to your Apple Account. Subscriptions renew automatically unless cancelled at least 24 hours before the end of the period. Manage or cancel in your Apple Account settings.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                HStack(spacing: 16) {
                    Button("Terms of Use") { openURL(Self.termsURL) }
                    Button("Privacy Policy") { openURL(Self.privacyURL) }
                }
                .font(.caption2)
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
            }
        }
    #endif
}
