//
//  StripeEntitlementsSource.swift
//  StripeOneTapPurchase
//

import Foundation
import Helium

// MARK: - API Response Types

struct StripeEntitlementResponse: Codable, Sendable {
    let hasActiveEntitlement: Bool
    let subscriptions: [StripeSubscriptionInfo]
    let customerId: String?
}

struct StripeSubscriptionInfo: Codable, Sendable {
    let subscriptionId: String
    let productId: String
    let status: String
    let currentPeriodEnd: String?
    let cancelAtPeriodEnd: Bool?
    let trialEnd: String?

    var isActive: Bool {
        ["active", "trialing"].contains(status)
    }
}

// MARK: - Snapshots

/// A product entitlement with its subscription expiration date.
private struct ProductEntitlement: Codable {
    let productId: String
    /// When the subscription period actually ends (from Stripe's currentPeriodEnd/trialEnd).
    /// Nil for one-time purchases (permanent entitlement).
    let subscriptionExpiresAt: Date?

    var isActive: Bool {
        guard let subscriptionExpiresAt else { return true }
        return Date() < subscriptionExpiresAt
    }
}

/// In-memory cache from the latest server fetch.
private struct CachedSnapshot {
    let products: [ProductEntitlement]
    /// TTL — when to re-fetch from the server. Independent of per-product expiration.
    let refreshAfter: Date

    var needsRefresh: Bool { Date() > refreshAfter }

    var activeProductIds: Set<String> {
        Set(products.filter { $0.isActive }.map { $0.productId })
    }
}

private struct PersistedStripeEntitlements: Codable {
    let products: [ProductEntitlement]
}

// MARK: - StripeEntitlementsSource

open class StripeEntitlementsSource: ThirdPartyEntitlementsSource, @unchecked Sendable {

    private let apiKey: String
    private let lock = NSLock()

    /// Authoritative once set — populated by a successful server fetch.
    private var cached: CachedSnapshot?
    /// Cold-start fallback — loaded from disk, used only until first fetch completes.
    private var persisted: [ProductEntitlement] = []

    private static let cacheTTL: TimeInterval = 60 * 60 // 60 minutes

    private static let heliumBaseURL = "https://api-v2.tryhelium.com/"
    private static let persistenceFileName = "helium_stripe_entitlements.json"

    init(apiKey: String) {
        self.apiKey = apiKey
        loadPersistedData()
        Task { await fetchFromServer() }
    }

    // MARK: - ThirdPartyEntitlementsSource

    open func entitledProductIds() async -> Set<String> {
        await refreshIfNeeded()
        return lock.withLock { currentProductIds }
    }

    open func hasAnyActiveSubscription() async -> Bool {
        await refreshIfNeeded()
        return lock.withLock { !currentProductIds.isEmpty }
    }
    
    open func refreshEntitlements() async {
        await fetchFromServer()
    }
    
    open func didCompletePurchase(productId: String, subscriptionExpiresAt: Date?) {
        let didUpdate: Bool = lock.withLock {
            guard var products = cached?.products else { return false }
            products.removeAll { $0.productId == productId }
            products.append(ProductEntitlement(
                productId: productId,
                subscriptionExpiresAt: subscriptionExpiresAt
            ))
            cached = CachedSnapshot(
                products: products,
                refreshAfter: Date().addingTimeInterval(Self.cacheTTL)
            )
            return true
        }
        if didUpdate { persistData() }
    }
    
    open func clearEntitlements() {
        lock.withLock {
            cached = nil
            persisted = []
        }
        if let fileURL = persistenceFileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    // MARK: - Private

    /// Best available product IDs: cached (authoritative) > persisted (fallback).
    /// Both tiers filter by per-product subscription expiration.
    private var currentProductIds: Set<String> {
        if let cached {
            return cached.activeProductIds
        }
        return Set(persisted.filter { $0.isActive }.map { $0.productId })
    }

    private func refreshIfNeeded() async {
        let needsRefresh: Bool = lock.withLock {
            guard let cached else { return true }
            return cached.needsRefresh
        }
        if needsRefresh {
            await fetchFromServer()
        }
    }

    private func fetchFromServer() async {
        let urlString = Self.heliumBaseURL + "stripe/check-entitlement"
        guard let url = URL(string: urlString) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("gzip, deflate", forHTTPHeaderField: "Accept-Encoding")

        let body: [String: String] = [
            "apiKey": apiKey,
            "userId": Helium.identify.userId ?? HeliumIdentityManager.shared.getHeliumPersistentId(),
            "rcUserId": Helium.identify.revenueCatAppUserId ?? "",
            "stripeCustomerId": HeliumIdentityManager.shared.getStripeCustomerId() ?? "",
            "heliumPersistentId": HeliumIdentityManager.shared.getHeliumPersistentId(),
            "appTransactionId": HeliumIdentityManager.shared.getAppTransactionID() ?? ""
        ]
        guard let bodyData = try? JSONEncoder().encode(body) else { return }
        request.httpBody = bodyData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
                return
            }

            let entitlementResponse = try JSONDecoder().decode(StripeEntitlementResponse.self, from: data)

            let activeSubscriptions = entitlementResponse.subscriptions.filter { $0.isActive }

            // Build per-product entries from subscription expiration dates
            let productEntitlements: [ProductEntitlement] = activeSubscriptions.compactMap { sub in
                let dateString = sub.currentPeriodEnd ?? sub.trialEnd
                guard let expiresAt = parseISODate(dateString) else {
                    return nil
                }
                return ProductEntitlement(productId: sub.productId, subscriptionExpiresAt: expiresAt)
            }

            lock.withLock {
                cached = CachedSnapshot(
                    products: productEntitlements,
                    refreshAfter: Date().addingTimeInterval(Self.cacheTTL)
                )
                persisted = productEntitlements
            }
            persistData()
        } catch {
            // Silently fail — cached/persisted data remains available
        }
    }

    // MARK: - Persistence

    private var persistenceFileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Helium", isDirectory: true)
            .appendingPathComponent(Self.persistenceFileName)
    }

    private func loadPersistedData() {
        guard let fileURL = persistenceFileURL,
              let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(PersistedStripeEntitlements.self, from: data) else {
            return
        }
        let active = decoded.products.filter { $0.isActive }
        lock.withLock {
            persisted = active
        }
    }

    private func persistData() {
        guard let fileURL = persistenceFileURL else { return }

        let encoded: Data? = lock.withLock {
            let snapshot = PersistedStripeEntitlements(products: persisted)
            return try? JSONEncoder().encode(snapshot)
        }
        guard let encoded else { return }

        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try encoded.write(to: fileURL, options: .atomic)
        } catch {
            // Silently fail
        }
    }
}
