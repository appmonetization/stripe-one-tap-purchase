import Helium
import StripeApplePay

extension Helium {

    /// Adds `"device_supports_apple_pay"` user trait and initializes Helium.
    /// Call this instead of `Helium.shared.initialize(apiKey:)` to automatically
    /// report Apple Pay availability for targeting.
    public func initializeWithApplePayTrait(apiKey: String) {
        Helium.identify.addUserTraits(HeliumUserTraits([
            "device_supports_stripe_apple_pay": StripeAPI.deviceSupportsApplePay()
        ]))
        initialize(apiKey: apiKey)
    }

    /// Creates a `StripeOneTapPurchaseDelegate`, sets it as the purchase delegate,
    /// adds the Apple Pay user trait, and initializes Helium.
    ///
    /// This is the all-in-one setup for Stripe Apple Pay with Helium.
    public func initializeWithStripeOneTap(
        apiKey: String,
        backupDelegate: HeliumPaywallDelegate,
        paymentProvider: StripeOneTapPaymentProvider = HeliumStripePaymentProvider(),
        merchantIdentifier: String,
        countryCode: String = "US",
        currencyCode: String = "USD"
    ) {
        let stripeDelegate = StripeOneTapPurchaseDelegate(
            backupDelegate: backupDelegate,
            paymentProvider: paymentProvider,
            merchantIdentifier: merchantIdentifier,
            countryCode: countryCode,
            currencyCode: currencyCode
        )
        Helium.config.purchaseDelegate = stripeDelegate
        initializeWithApplePayTrait(apiKey: apiKey)
    }
}
