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
    ///   - checkoutStyle: Controls how Stripe Checkout is presented. When `nil` (default),
    ///     Apple Pay is used if available, otherwise falls back to `.webView`.
    ///     Set to `.safariInApp` or `.externalBrowser` to always use Stripe Checkout
    ///     (requires `checkoutSuccessURL` and `checkoutCancelURL`).
    ///   - checkoutSuccessURL: Optional HTTPS URL for Stripe to redirect to on successful payment.
    ///     If not provided, a default Helium URL is used. Include `{CHECKOUT_SESSION_ID}` to receive the session ID.
    ///   - checkoutCancelURL: Optional HTTPS URL for Stripe to redirect to on cancellation.
    ///     If not provided, a default Helium URL is used.
    public func initializeWithStripeOneTap(
        apiKey: String,
        stripePublishableKey: String,
        backupPurchaseDelegate: HeliumPaywallDelegate,
        merchantIdentifier: String,
        merchantName: String,
        managementURL: URL,
        paymentProvider: StripeOneTapPaymentProvider? = nil,
        countryCode: String = "US",
        currencyCode: String = "USD",
        checkoutStyle: StripeCheckoutStyle? = nil,
        checkoutSuccessURL: String? = nil,
        checkoutCancelURL: String? = nil
    ) {
        StripeAPI.defaultPublishableKey = stripePublishableKey
        
        let provider = paymentProvider ?? HeliumStripePaymentProvider(apiKey: apiKey, merchantName: merchantName, managementURL: managementURL)
        let entitlementsSource = StripeEntitlementsSource()
        let stripeDelegate = StripeOneTapPurchaseDelegate(
            backupDelegate: backupPurchaseDelegate,
            paymentProvider: provider,
            merchantIdentifier: merchantIdentifier,
            countryCode: countryCode,
            currencyCode: currencyCode,
            entitlementsSource: entitlementsSource,
            checkoutStyle: checkoutStyle,
            checkoutSuccessURL: checkoutSuccessURL,
            checkoutCancelURL: checkoutCancelURL
        )
        Helium.config.purchaseDelegate = stripeDelegate
        Helium.config.thirdPartyEntitlementsSource = entitlementsSource

        ApplePayHelper.shared.setStripeApplePayAvailable(StripeAPI.deviceSupportsApplePay())

        initialize(apiKey: apiKey)
    }

    // Note: Stripe sync now happens automatically when Helium.identify.userId is set.
    // resetStripeEntitlements, createStripePortalSession, and hasActiveStripeEntitlement
    // are provided by the core Helium SDK directly on Helium.shared.
}
