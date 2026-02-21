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
