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

    enum CodingKeys: String, CodingKey {
        case hasActiveEntitlement = "has_active_entitlement"
        case subscriptions
        case customerId = "customer_id"
    }
}

struct StripeSubscriptionInfo: Codable, Sendable {
    let subscriptionId: String
    let productId: String
    let status: String
    let currentPeriodEnd: String?
    let cancelAtPeriodEnd: Bool?
    let trialEnd: String?

    enum CodingKeys: String, CodingKey {
        case subscriptionId = "subscription_id"
        case productId = "product_id"
        case status
        case currentPeriodEnd = "current_period_end"
        case cancelAtPeriodEnd = "cancel_at_period_end"
        case trialEnd = "trial_end"
    }

    var isActive: Bool {
        ["active", "trialing"].contains(status)
    }
}

// MARK: - Persisted Data

private struct PersistedStripeEntitlements: Codable {
    let productIds: [String]
    let hasActiveSubscription: Bool
    let savedAt: Date
}

// MARK: - StripeEntitlementsSource

final class StripeEntitlementsSource: ThirdPartyEntitlementsSource, @unchecked Sendable {

    private let apiKey: String
    private let lock = NSLock()

    // In-memory cache
    private var cachedProductIds: Set<String> = []
    private var cachedHasActiveSubscription: Bool = false
    private var lastFetchTime: Date?
    private let cacheTTL: TimeInterval = 60 * 15 // 15 minutes

    private static let heliumBaseURL = "https://api-v2.tryhelium.com/"
    private static let persistenceFileName = "helium_stripe_entitlements.json"

    init(apiKey: String) {
        self.apiKey = apiKey
        loadPersistedData()
    }

    // MARK: - ThirdPartyEntitlementsSource

    func entitledProductIds() async -> Set<String> {
        await refreshIfNeeded()
        return lock.withLock { cachedProductIds }
    }

    func hasAnyActiveSubscription(includeNonRenewing: Bool) async -> Bool {
        await refreshIfNeeded()
        return lock.withLock { cachedHasActiveSubscription }
    }

    func refreshEntitlements() async {
        await fetchFromServer()
    }

    func didCompletePurchase(productId: String) async {
        // Optimistically add to cache
        lock.withLock {
            cachedProductIds.insert(productId)
            cachedHasActiveSubscription = true
        }
        persistData()

        // Then verify with server
        await fetchFromServer()
    }

    // MARK: - Private

    private func refreshIfNeeded() async {
        let needsRefresh: Bool = lock.withLock {
            guard let lastFetch = lastFetchTime else { return true }
            return Date().timeIntervalSince(lastFetch) > cacheTTL
        }
        if needsRefresh {
            await fetchFromServer()
        }
    }

    private func fetchFromServer() async {
        //
        guard let userId = Helium.identify.userId, !userId.isEmpty else { return }

        let urlString = Self.heliumBaseURL + "api/stripe/check-entitlement"
        guard let url = URL(string: urlString) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let body: [String: String] = ["rc_user_id": userId]
        guard let bodyData = try? JSONEncoder().encode(body) else { return }
        request.httpBody = bodyData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
                return
            }

            let decoder = JSONDecoder()
            let entitlementResponse = try decoder.decode(StripeEntitlementResponse.self, from: data)

            let activeProductIds = Set(
                entitlementResponse.subscriptions
                    .filter { $0.isActive }
                    .map { $0.productId }
            )
            let hasActive = entitlementResponse.hasActiveEntitlement

            lock.withLock {
                cachedProductIds = activeProductIds
                cachedHasActiveSubscription = hasActive
                lastFetchTime = Date()
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
        lock.withLock {
            cachedProductIds = Set(decoded.productIds)
            cachedHasActiveSubscription = decoded.hasActiveSubscription
        }
    }

    private func persistData() {
        guard let fileURL = persistenceFileURL else { return }

        let snapshot: PersistedStripeEntitlements = lock.withLock {
            PersistedStripeEntitlements(
                productIds: Array(cachedProductIds),
                hasActiveSubscription: cachedHasActiveSubscription,
                savedAt: Date()
            )
        }

        guard let encoded = try? JSONEncoder().encode(snapshot) else { return }

        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try encoded.write(to: fileURL, options: .atomic)
        } catch {
            // Silently fail
        }
    }
}
