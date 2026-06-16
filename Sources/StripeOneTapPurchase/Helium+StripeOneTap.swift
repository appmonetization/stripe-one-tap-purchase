import Foundation
import Helium
@preconcurrency import StripeApplePay

extension Helium {
    
    /// Configure in-app Stripe Apple Pay with Helium and (soon) Stripe external browser flow.
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
    ///     is created.
    ///   - checkoutSuccessURL: (External browser flow only) URL to redirect to after a successful payment.
    ///   - checkoutCancelURL: (External browser flow only) URL the provider redirects to when the user cancels checkout.
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
        checkoutSuccessURL: String? = nil,
        checkoutCancelURL: String? = nil,
        countryCode: String = "US",
        currencyCode: String = "USD"
    ) {
        StripeAPI.defaultPublishableKey = stripePublishableKey
        
        Helium.config.enableExternalWebCheckout(
            successURL: checkoutSuccessURL ?? "externalnotsupportedyet://openapp",
            cancelURL: checkoutCancelURL ?? "externalnotsupportedyet://openapp",
            paymentProcessors: .stripe
        )
        
        let provider = paymentProvider ?? HeliumStripePaymentProvider(merchantName: merchantName, managementURL: managementURL)
        let stripeDelegate = StripeOneTapPurchaseDelegate(
            backupDelegate: backupPurchaseDelegate,
            paymentProvider: provider,
            merchantIdentifier: merchantIdentifier,
            countryCode: countryCode,
            currencyCode: currencyCode
        )
        Helium.config.purchaseDelegate = stripeDelegate

        ApplePayHelper.shared.setStripeApplePayAvailable(StripeAPI.deviceSupportsApplePay())

        initialize(apiKey: apiKey)
    }
    
}
