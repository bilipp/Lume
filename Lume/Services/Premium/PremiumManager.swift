//
//  PremiumManager.swift
//  Lume
//
//  The single source of truth for whether the user has Lume Pro, and the
//  StoreKit 2 layer behind it (monthly subscription + one-time lifetime).
//
//  Business model: Lume is free, open-source software. Builds the user compiles
//  and sideloads themselves are fully unlocked (the `SIDE_LOAD` compilation
//  condition, set only in the "Sideload" build configuration). The App Store
//  build gates a handful of convenience features behind Lume Pro — see
//  `PremiumFeature`.
//

import Foundation
import OSLog
import StoreKit

@MainActor
@Observable
final class PremiumManager {
    static let shared = PremiumManager()

    /// The two ways to unlock Premium on the App Store. The lifetime option is a
    /// non-consumable; the monthly option is an auto-renewable subscription.
    enum Plan: String, CaseIterable {
        case monthly = "com.bilipp.lume.premium.monthly"
        case lifetime = "com.bilipp.lume.premium.lifetime"
    }

    /// App Store Connect subscription group for the monthly plan.
    static let subscriptionGroupID = "21111111"

    /// Loaded `Product`s, ascending by price (monthly first, lifetime second).
    private(set) var products: [Product] = []
    /// Product IDs the user currently owns (active subscription or lifetime).
    private(set) var purchasedProductIDs: Set<String> = []
    /// True while a purchase or restore is in flight, for button spinners.
    private(set) var isWorking = false

    #if SIDE_LOAD
        /// Sideloaded / self-compiled builds unlock everything. No StoreKit, no
        /// paywall — this is the open-source promise.
        var isPremium: Bool {
            true
        }

    #elseif DEBUG
        /// DEBUG-only override so the free tier and the real purchase flow are
        /// testable without archiving a Release build. Defaults to Premium-on for
        /// convenient day-to-day development; flip it off in Settings ▸ Developer
        /// to exercise the paywall and a `.storekit` purchase.
        static let debugForcePremiumKey = "premium.debugForcePremium"

        var debugForcePremium: Bool = UserDefaults.standard
            .object(forKey: PremiumManager.debugForcePremiumKey) as? Bool ?? true
        {
            didSet { UserDefaults.standard.set(debugForcePremium, forKey: PremiumManager.debugForcePremiumKey) }
        }

        var isPremium: Bool {
            debugForcePremium || !purchasedProductIDs.isEmpty
        }
    #else
        /// App Store build: Premium iff the user owns the lifetime unlock or has an
        /// active subscription.
        var isPremium: Bool {
            !purchasedProductIDs.isEmpty
        }
    #endif

    private var transactionListener: Task<Void, Never>?

    private init() {
        #if !SIDE_LOAD
            // Listen for renewals, refunds, Ask-to-Buy approvals and purchases made
            // on other devices for the whole app lifetime.
            transactionListener = Task { [weak self] in
                for await update in Transaction.updates {
                    await self?.handle(update)
                }
            }
            Task {
                await loadProducts()
                await refreshEntitlements()
            }
        #endif
    }

    // MARK: - Plan lookup / display

    func product(for plan: Plan) -> Product? {
        products.first { $0.id == plan.rawValue }
    }

    /// Whether the user is currently entitled through that specific plan.
    func owns(_ plan: Plan) -> Bool {
        purchasedProductIDs.contains(plan.rawValue)
    }

    // MARK: - StoreKit

    func loadProducts() async {
        do {
            let ids = Plan.allCases.map(\.rawValue)
            let loaded = try await Product.products(for: ids)
            products = loaded.sorted { $0.price < $1.price }
            if products.count != ids.count {
                let missing = Set(ids).subtracting(products.map(\.id))
                Logger.premium.error("Missing products (not configured?): \(missing, privacy: .public)")
            }
        } catch {
            Logger.premium.error("Failed to load products: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Purchase a plan. Returns true once the entitlement is granted.
    @discardableResult
    func purchase(_ product: Product) async -> Bool {
        isWorking = true
        defer { isWorking = false }
        do {
            let result = try await product.purchase()
            switch result {
            case let .success(verification):
                guard case let .verified(transaction) = verification else {
                    Logger.premium.error("Purchase verification failed for \(product.id, privacy: .public)")
                    return false
                }
                await refreshEntitlements()
                await transaction.finish()
                return isPremium
            case .userCancelled, .pending:
                return false
            @unknown default:
                return false
            }
        } catch {
            Logger.premium.error("Purchase failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Restore purchases (App Store Review requires this for non-consumables and
    /// subscriptions). Syncs transactions, then re-reads entitlements.
    func restore() async {
        isWorking = true
        defer { isWorking = false }
        try? await AppStore.sync()
        await refreshEntitlements()
    }

    /// Recompute `purchasedProductIDs` from the current entitlements, dropping any
    /// refunded / revoked transaction.
    func refreshEntitlements() async {
        var owned: Set<String> = []
        for await result in Transaction.currentEntitlements {
            guard case let .verified(transaction) = result else { continue }
            if transaction.revocationDate == nil {
                owned.insert(transaction.productID)
            }
        }
        purchasedProductIDs = owned
    }

    private func handle(_ result: VerificationResult<Transaction>) async {
        guard case let .verified(transaction) = result else {
            // Unverified: clear it from the queue but grant nothing.
            if case let .unverified(transaction, _) = result {
                await transaction.finish()
            }
            return
        }
        await refreshEntitlements()
        await transaction.finish()
    }
}
