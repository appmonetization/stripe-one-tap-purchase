import Helium
import StripeApplePay

extension Helium {
    
    /// Creates a `StripeOneTapPurchaseDelegate`, sets it as the purchase delegate,
    /// adds the Apple Pay user trait, and initializes Helium.
    ///
    /// This is the all-in-one setup for Stripe Apple Pay with Helium.
    public func initializeWithStripeOneTap(
        apiKey: String,
        backupPurchaseDelegate: HeliumPaywallDelegate,
        paymentProvider: StripeOneTapPaymentProvider? = nil,
        merchantIdentifier: String,
        countryCode: String = "US",
        currencyCode: String = "USD"
    ) {
        let provider = paymentProvider ?? HeliumStripePaymentProvider(apiKey: apiKey)
        let stripeDelegate = StripeOneTapPurchaseDelegate(
            backupDelegate: backupPurchaseDelegate,
            paymentProvider: provider,
            merchantIdentifier: merchantIdentifier,
            countryCode: countryCode,
            currencyCode: currencyCode
        )
        Helium.config.purchaseDelegate = stripeDelegate
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
