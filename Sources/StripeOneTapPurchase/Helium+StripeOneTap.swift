import Foundation
import Helium
import StripeApplePay

extension Helium {
    
    /// Creates a `StripeOneTapPurchaseDelegate`, sets it as the purchase delegate,
    /// adds the Apple Pay user trait, and initializes Helium.
    ///
    /// This is the all-in-one setup for Stripe Apple Pay with Helium.
    ///
    /// - Parameters:
    ///   - apiKey: Your Helium API key.
    ///   - backupPurchaseDelegate: Backup delegate used when the device does not support Apple Pay.
    ///   - paymentProvider: Custom payment provider. When `nil`, a default ``HeliumStripePaymentProvider``
    ///     is created using `apiKey` and `managementURL`.
    ///   - merchantIdentifier: Your Apple Pay merchant identifier (e.g. `"merchant.com.example"`).
    ///   - countryCode: Two-letter ISO country code for the merchant. Defaults to `"US"`.
    ///   - currencyCode: Three-letter ISO currency code. Defaults to `"USD"`.
    ///   - managementURL: Optional URL where users can manage their subscription
    ///     (e.g. a Stripe Customer Portal link). When provided, the Apple Pay sheet shows
    ///     a recurring payment disclosure with a link to this URL. When `nil`, the
    ///     disclosure is omitted. Only used when `paymentProvider` is `nil`.
    public func initializeWithStripeOneTap(
        apiKey: String,
        backupPurchaseDelegate: HeliumPaywallDelegate,
        paymentProvider: StripeOneTapPaymentProvider? = nil,
        merchantIdentifier: String,
        countryCode: String = "US",
        currencyCode: String = "USD",
        managementURL: URL? = nil
    ) {
        let provider = paymentProvider ?? HeliumStripePaymentProvider(apiKey: apiKey, managementURL: managementURL)
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
        Helium.entitlements.setThirdPartySource(entitlementsSource)
        
        initializeWithApplePayTrait(apiKey: apiKey)
    }
    
    func initializeWithApplePayTrait(apiKey: String) {
        Helium.identify.addUserTraits(HeliumUserTraits([
            "hlm_device_supports_stripe_apple_pay": StripeAPI.deviceSupportsApplePay()
        ]))
        // hmm include apple merchant id too??
        // and should these be in custom user traits or at helium traits level?
        initialize(apiKey: apiKey)
    }
    
}
