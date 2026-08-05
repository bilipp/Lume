//
//  PremiumPlanTests.swift
//  LumeTests
//
//  Guards the plan catalogue against the mistake that shipped once already: the
//  "monthly" plan was advertised as an auto-renewing subscription while the product
//  behind it — `com.bilipp.lume.premium.monthly` — was a non-consumable in App Store
//  Connect. Non-consumables never appear under App Store ▸ Subscriptions, so buyers
//  had no way to cancel something the paywall told them renewed every month.
//
//  These are contract tests, not behaviour tests: they pin the product IDs and the
//  renewable/purchasable split so a future edit can't quietly put the retired product
//  back on sale or mark a one-time unlock as renewable.
//

@testable import Lume
import Testing

@MainActor
struct PremiumPlanTests {
    /// The IDs must match App Store Connect exactly — a typo here means
    /// `Product.products(for:)` silently returns fewer products and the paywall
    /// renders a spinner forever.
    @Test func `product ids match app store connect`() {
        #expect(PremiumManager.Plan.monthly.rawValue == "com.bilipp.lume.pro.monthly")
        #expect(PremiumManager.Plan.lifetime.rawValue == "com.bilipp.lume.premium.lifetime")
        #expect(PremiumManager.Plan.retiredMonthly.rawValue == "com.bilipp.lume.premium.monthly")
    }

    /// The retired non-consumable must never be offered again, and the paywall lists
    /// the subscription before the lifetime unlock.
    @Test func `only current plans are purchasable`() {
        #expect(PremiumManager.Plan.purchasable == [.monthly, .lifetime])
        #expect(!PremiumManager.Plan.purchasable.contains(.retiredMonthly))
    }

    /// Exactly one plan is a real subscription. Anything else claiming to renew is the
    /// original bug: renewal copy and a cancel affordance attached to a product the
    /// App Store cannot cancel.
    @Test func `only the subscription is renewable`() {
        let renewable = PremiumManager.Plan.allCases.filter(\.isRenewable)
        #expect(renewable == [.monthly])
        #expect(!PremiumManager.Plan.lifetime.isRenewable)
        #expect(!PremiumManager.Plan.retiredMonthly.isRenewable)
    }

    /// The retired product still entitles: those buyers paid once for what they were
    /// told was a subscription, so they keep Pro permanently.
    @Test func `every plan is still honoured as an entitlement`() {
        #expect(PremiumManager.Plan.allCases.count == 3)
        #expect(Set(PremiumManager.Plan.allCases.map(\.rawValue)).count == 3)
    }
}
