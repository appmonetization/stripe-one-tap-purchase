import Foundation

/// The Stripe identifiers encoded in a Helium product key.
///
/// Helium keys Stripe products as `"<productId>:<priceId>"` (e.g. `"prod_ABC:price_123"`).
public struct StripeProductIdentifiers: Sendable, Equatable {

    /// The Stripe product ID, e.g. `"prod_ABC"`.
    public let productId: String

    /// The Stripe price ID, e.g. `"price_123"`.
    public let priceId: String

    /// Deconstructs a Helium product key into its Stripe product and price IDs.
    /// - Throws: ``StripeOneTapError/invalidProductKey(_:)`` if either ID is missing.
    public init(heliumProductKey: String) throws {
        let parts = heliumProductKey.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
            throw StripeOneTapError.invalidProductKey(heliumProductKey)
        }
        self.productId = String(parts[0])
        self.priceId = String(parts[1])
    }
}
