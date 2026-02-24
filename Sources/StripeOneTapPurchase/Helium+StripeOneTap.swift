import Foundation
import Helium
@preconcurrency import StripeApplePay

extension Helium {
    
    /// Creates a `StripeOneTapPurchaseDelegate`, sets it as the purchase delegate,
    /// adds the Apple Pay user trait, and initializes Helium.
    ///
    /// This is the all-in-one setup for Stripe Apple Pay with Helium.
    ///
    /// - Parameters:
    ///   - apiKey: Your Helium API key.
    ///   - stripePublishableKey: Your Stripe publishable key (e.g. `"pk_live_..."` or `"pk_test_..."`).
    ///   - backupPurchaseDelegate: Backup delegate used when the device does not support Apple Pay.
    ///   - merchantIdentifier: Your Apple Pay merchant identifier (e.g. `"merchant.com.example"`).
    ///   - merchantName: Your company or app name, displayed as the "PAY TO" label on the Apple Pay sheet.
    ///     Only used when `paymentProvider` is `nil`.
    ///   - managementURL: URL where users can manage their subscription
    ///     (e.g. a Stripe Customer Portal link). The Apple Pay sheet shows
    ///     a recurring payment disclosure with a link to this URL.
    ///     Only used when `paymentProvider` is `nil`.
    ///   - paymentProvider: Custom payment provider. When `nil`, a default ``HeliumStripePaymentProvider``
    ///     is created using `apiKey` and `managementURL`.
    ///   - countryCode: Two-letter ISO country code for the merchant. Defaults to `"US"`.
    ///   - currencyCode: Three-letter ISO currency code. Defaults to `"USD"`.   
    public func initializeWithStripeOneTap(
        apiKey: String,
        stripePublishableKey: String,
        backupPurchaseDelegate: HeliumPaywallDelegate,
        merchantIdentifier: String,
        merchantName: String,
        managementURL: URL,
        paymentProvider: StripeOneTapPaymentProvider? = nil,
        countryCode: String = "US",
        currencyCode: String = "USD"
    ) {
        StripeAPI.defaultPublishableKey = stripePublishableKey
        
        let provider = paymentProvider ?? HeliumStripePaymentProvider(apiKey: apiKey, merchantName: merchantName, managementURL: managementURL)
        let entitlementsSource = StripeEntitlementsSource(apiKey: apiKey)
        let stripeDelegate = StripeOneTapPurchaseDelegate(
            backupDelegate: backupPurchaseDelegate,
            paymentProvider: provider,
            merchantIdentifier: merchantIdentifier,
            countryCode: countryCode,
            currencyCode: currencyCode,
            entitlementsSource: entitlementsSource
        )
        Helium.config.purchaseDelegate = stripeDelegate
        Helium.config.thirdPartyEntitlementsSource = entitlementsSource
        
        ApplePayHelper.shared.setStripeApplePayAvailable(StripeAPI.deviceSupportsApplePay())
        
        initialize(apiKey: apiKey)
    }
    
    /// If your custom user ID can change AFTER a paywall is shown and potential purchase made, make sure to call this instead of setting
    /// `Helium.identify.userId` directly.
    public func setUserIdAndSyncStripeIfNeeded(userId: String) {
        let previousUserId = Helium.identify.userId
        Helium.identify.userId = userId
        
        guard userId != previousUserId,
              HeliumIdentityManager.shared.getStripeCustomerId() != nil else {
            return
        }
        
        Task {
            guard let delegate = Helium.config.purchaseDelegate as? StripeOneTapPurchaseDelegate else { return }
            await delegate.syncCustomerMetadata()
        }
    }
    
    /// If you app can potentially support multiple Stripe users on the same device, you'll want to call this to effectively "log out" a Stripe user.
    public func resetStripeEntitlements(clearUserId: Bool) {
        if clearUserId {
            Helium.identify.userId = nil
        }
        (Helium.config.thirdPartyEntitlementsSource as? StripeEntitlementsSource)?.clearEntitlements()
        HeliumIdentityManager.shared.setStripeCustomerId(nil)
    }
    
    /// Creates a Stripe Customer Portal session and returns the portal URL.
    /// The host app can open this URL in a browser or in-app webview to let
    /// the user manage their subscriptions, payment methods, and invoices.
    ///
    /// - Parameter returnUrl: The URL Stripe redirects to after the user finishes in the portal.
    /// - Returns: The portal session URL.
    ///
    /// ## Example
    /// ```swift
    /// do {
    ///     let portalURL = try await Helium.shared.createStripePortalSession(returnUrl: "myapp://settings")
    ///     await UIApplication.shared.open(portalURL)
    /// } catch {
    ///     print("Failed to create portal session: \(error)")
    /// }
    /// ```
    public func createStripePortalSession(returnUrl: String) async throws -> URL {
        guard let delegate = Helium.config.purchaseDelegate as? StripeOneTapPurchaseDelegate else {
            throw StripeOneTapError.stripeOneTapNotInitialized
        }
        return try await delegate.createPortalSession(returnUrl: returnUrl)
    }
    
}
