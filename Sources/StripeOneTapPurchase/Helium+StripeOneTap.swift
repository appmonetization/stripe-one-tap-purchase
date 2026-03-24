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
    ///   - checkoutSuccessURL: Deep link URL for Stripe to redirect to on successful payment.
    ///     Required for `.safariInApp` and `.externalBrowser` styles. Include `{CHECKOUT_SESSION_ID}`
    ///     in the URL to receive the session ID (e.g. `"myapp://checkout/success?session_id={CHECKOUT_SESSION_ID}"`).
    ///   - checkoutCancelURL: Deep link URL for Stripe to redirect to on cancellation.
    ///     Required for `.safariInApp` and `.externalBrowser` styles.
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
        let entitlementsSource = StripeEntitlementsSource(apiKey: apiKey)
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
    
    /// If your custom user ID can change AFTER Helium is initialized, make sure to call this
    /// instead of setting `Helium.identify.userId` directly.
    public func setUserIdAndSyncStripeIfNeeded(userId: String) {
        let previousUserId = Helium.identify.userId
        Helium.identify.userId = userId
        
        guard userId != previousUserId else {
            return
        }
        guard let delegate = Helium.config.purchaseDelegate as? StripeOneTapPurchaseDelegate else {
            return
        }
        guard Helium.shared.getDownloadStatus() != .notDownloadedYet else {
            return
        }
        
        Task {
            if HeliumIdentityManager.shared.getStripeCustomerId() == nil {
                // See if entitlements are changed for new user ID
                await delegate.refreshEntitlements()
                return
            }
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
    
    /// Call this from your app's deep link handler (`application(_:open:options:)` or
    /// `scene(_:openURLContexts:)`) to complete a Stripe Checkout purchase.
    /// Required when using `.safariInApp` or `.externalBrowser` checkout styles.
    ///
    /// ```swift
    /// func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    ///     if let url = URLContexts.first?.url {
    ///         Helium.shared.handleStripeCheckoutRedirect(url: url)
    ///     }
    /// }
    /// ```
    public func handleStripeCheckoutRedirect(url: URL) {
        guard let delegate = Helium.config.purchaseDelegate as? StripeOneTapPurchaseDelegate else {
            return
        }
        delegate.handleCheckoutRedirect(url: url)
    }

    /// Returns `true` if the user has any active Stripe entitlement (e.g. an active subscription).
    public func hasActiveStripeEntitlement() async -> Bool {
        guard let source = Helium.config.thirdPartyEntitlementsSource as? StripeEntitlementsSource else {
            return false
        }
        let productIds = await source.entitledProductIds()
        return !productIds.isEmpty
    }
    
}
