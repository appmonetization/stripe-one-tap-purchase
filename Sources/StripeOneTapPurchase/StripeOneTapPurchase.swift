import Helium
import StripeApplePay
import PassKit
import UIKit
import SafariServices

// MARK: - Helium Base URL

let defaultHeliumBaseURL = "https://api-v2.tryhelium.com/"
var heliumBaseURL: String {
    guard let custom = Helium.config.customAPIEndpoint,
          let url = URL(string: custom),
          let scheme = url.scheme,
          let host = url.host else {
        return defaultHeliumBaseURL
    }
    let port = url.port.map { ":\($0)" } ?? ""
    return "\(scheme)://\(host)\(port)/"
}

// MARK: - Checkout Style

/// Controls how Stripe Checkout is presented when Apple Pay is not used.
public enum StripeCheckoutStyle: Sendable {
    /// Embedded WKWebView (default). No deep link setup required.
    case webView
    /// SFSafariViewController. The SDK automatically detects when the user returns.
    case safariInApp
    /// Opens in the default browser. The SDK automatically detects when the user returns.
    case externalBrowser
}

// MARK: - Pending Checkout Persistence

/// Persisted state for checkout sessions that survive app termination.
private struct PendingCheckout: Codable {
    let productId: String
    let sessionId: String
    let timestamp: Date

    var isExpired: Bool {
        Date().timeIntervalSince(timestamp) > 24 * 60 * 60 // Stripe sessions expire after max 24h
    }

    private static let key = "helium_pending_stripe_checkout"

    static func save(_ checkout: PendingCheckout) {
        guard let data = try? JSONEncoder().encode(checkout) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func load() -> PendingCheckout? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(PendingCheckout.self, from: data)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

// MARK: - Payment Provider Protocol

public protocol StripeOneTapPaymentProvider: Sendable {

    /// Configure the payment request before presenting Apple Pay.
    /// Set payment summary items, recurring payment info, required contact fields, etc.
    /// Called with a base request that already has merchantIdentifier, country, and currency set.
    func configurePaymentRequest(_ request: PKPaymentRequest, for productId: String)

    /// Called after the customer authorizes Apple Pay. Create a PaymentIntent or SetupIntent
    /// on your server and return the client secret.
    @MainActor func fetchClientSecret(
        for productId: String,
        paymentMethod: StripeAPI.PaymentMethod,
        paymentInformation: PKPayment
    ) async throws -> String

    /// Called after successful payment confirmation, before reporting `.purchased` to Helium.
    /// Use this for post-payment work like creating a subscription after a SetupIntent confirms.
    /// Throwing here will report `.failed(error)` instead of `.purchased`.
    func didCompletePayment(for productId: String, paymentMethodId: String) async throws -> PaymentSuccessResponse
}

public struct PaymentSuccessResponse: Sendable {
    let productId: String
    let expiresAt: Date?
    let transactionId: String?
}

// MARK: - Default Implementations

extension StripeOneTapPaymentProvider {

    public func configurePaymentRequest(_ request: PKPaymentRequest, for productId: String) {}

    public func didCompletePayment(for productId: String, paymentMethodId: String) async throws -> PaymentSuccessResponse? { nil }
}

// MARK: - StripeOneTapPurchaseDelegate

open class StripeOneTapPurchaseDelegate: NSObject, HeliumPaywallDelegate, HeliumDelegateReturnsTransaction, @unchecked Sendable {

    public var delegateType: String { "h_stripe_w_" + backupDelegate.delegateType }

    private let backupDelegate: HeliumPaywallDelegate
    private let paymentProvider: StripeOneTapPaymentProvider
    private let merchantIdentifier: String
    private let countryCode: String
    private let currencyCode: String
    private let entitlementsSource: StripeEntitlementsSource?
    private let checkoutStyle: StripeCheckoutStyle?
    private let checkoutSuccessURL: String?
    private let checkoutCancelURL: String?

    private var currentProductId: String?
    private var currentClientSecret: String?
    private var currentPaymentMethodId: String?
    private var currentSessionId: String?
    private var purchaseContinuation: CheckedContinuation<HeliumPaywallTransactionStatus, Never>?
    private var latestTransactionResult: HeliumTransactionIdResult?
    private var foregroundObserver: NSObjectProtocol?

    public init(
        backupDelegate: HeliumPaywallDelegate,
        paymentProvider: StripeOneTapPaymentProvider,
        merchantIdentifier: String,
        countryCode: String = "US",
        currencyCode: String = "USD",
        entitlementsSource: StripeEntitlementsSource?,
        checkoutStyle: StripeCheckoutStyle? = nil,
        checkoutSuccessURL: String? = nil,
        checkoutCancelURL: String? = nil
    ) {
        self.backupDelegate = backupDelegate
        self.paymentProvider = paymentProvider
        self.merchantIdentifier = merchantIdentifier
        self.countryCode = countryCode
        self.currencyCode = currencyCode
        self.entitlementsSource = entitlementsSource
        self.checkoutStyle = checkoutStyle
        self.checkoutSuccessURL = checkoutSuccessURL
        self.checkoutCancelURL = checkoutCancelURL
        super.init()
        resolvePendingCheckoutIfNeeded()
    }

    deinit {
        purchaseContinuation?.resume(returning: .cancelled)
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
        }
    }

    open func makePurchase(productId: String) async -> HeliumPaywallTransactionStatus {
        let allStripeProductIds = Array((HeliumFetchedConfigManager.shared.getServerProductsPriceMap() ?? [:]).keys)
        if !allStripeProductIds.contains(productId) {
            return await backupDelegate.makePurchase(productId: productId)
        }

        currentProductId = productId
        currentClientSecret = nil

        if checkoutStyle == nil && StripeAPI.deviceSupportsApplePay() {
            return await presentApplePayFlow(for: productId)
        } else {
            return await presentStripeCheckoutFlow(for: productId)
        }
    }

    /// Runs the entire Apple Pay flow on the main actor so that
    /// STPApplePayContext and PKPaymentRequest never cross isolation boundaries.
    /// Returns nil if STPApplePayContext could not be created.
    @MainActor
    private func presentApplePayFlow(for productId: String) async -> sending HeliumPaywallTransactionStatus {
        let paymentRequest = StripeAPI.paymentRequest(
            withMerchantIdentifier: merchantIdentifier,
            country: countryCode,
            currency: currencyCode
        )

        // Set a default summary item; the provider can override in configurePaymentRequest
        paymentRequest.paymentSummaryItems = [
            PKPaymentSummaryItem(label: "Total", amount: NSDecimalNumber.zero, type: .pending)
        ]

        paymentProvider.configurePaymentRequest(paymentRequest, for: productId)

        guard let applePayContext = STPApplePayContext(paymentRequest: paymentRequest, delegate: self) else {
            return .failed(StripeOneTapError.stripeApplePayContextError)
        }

        return await withCheckedContinuation { continuation in
            self.purchaseContinuation = continuation
            applePayContext.presentApplePay()
        }
    }

    /// Opens Stripe Hosted Checkout using the configured checkout style.
    @MainActor
    private func presentStripeCheckoutFlow(for productId: String) async -> sending HeliumPaywallTransactionStatus {
        guard let provider = paymentProvider as? HeliumStripePaymentProvider else {
            return .failed(StripeOneTapError.noStripePaymentProvider)
        }

        let style = checkoutStyle ?? .webView
        let successURL = checkoutSuccessURL ?? StripeCheckoutRedirect.successURL
        let cancelURL = checkoutCancelURL ?? StripeCheckoutRedirect.cancelURL

        let checkoutURL: URL
        let sessionId: String
        do {
            let result = try await provider.createCheckoutSession(
                productPriceId: productId,
                successURL: successURL,
                cancelURL: cancelURL
            )
            checkoutURL = result.checkoutURL
            sessionId = result.sessionId
        } catch {
            return .failed(error)
        }

        currentSessionId = sessionId

        switch style {
        case .webView:
            return await presentWebViewCheckout(checkoutURL: checkoutURL)
        case .safariInApp:
            PendingCheckout.save(PendingCheckout(productId: productId, sessionId: sessionId, timestamp: Date()))
            return await presentSafariCheckout(checkoutURL: checkoutURL)
        case .externalBrowser:
            PendingCheckout.save(PendingCheckout(productId: productId, sessionId: sessionId, timestamp: Date()))
            return await presentExternalBrowserCheckout(checkoutURL: checkoutURL)
        }
    }

    @MainActor
    private func presentWebViewCheckout(checkoutURL: URL) async -> sending HeliumPaywallTransactionStatus {
        guard let topVC = Self.topViewController() else {
            return .failed(StripeOneTapError.checkoutWebViewFailed)
        }

        return await withCheckedContinuation { continuation in
            self.purchaseContinuation = continuation
            let checkoutVC = StripeCheckoutViewController(checkoutURL: checkoutURL) { [weak self] result in
                guard let self else { return }
                completeCheckout(result: result)
            }
            topVC.present(checkoutVC, animated: true)
        }
    }

    @MainActor
    private func presentSafariCheckout(checkoutURL: URL) async -> sending HeliumPaywallTransactionStatus {
        guard let topVC = Self.topViewController() else {
            return .failed(StripeOneTapError.checkoutWebViewFailed)
        }

        let safariVC = SFSafariViewController(url: checkoutURL)
        safariVC.delegate = self

        return await withCheckedContinuation { continuation in
            self.purchaseContinuation = continuation
            startForegroundObserver()
            topVC.present(safariVC, animated: true)
        }
    }

    @MainActor
    private func presentExternalBrowserCheckout(checkoutURL: URL) async -> sending HeliumPaywallTransactionStatus {
        await UIApplication.shared.open(checkoutURL)

        return await withCheckedContinuation { continuation in
            self.purchaseContinuation = continuation
            startForegroundObserver()
        }
    }

    // MARK: - Foreground Observer

    private func startForegroundObserver() {
        stopForegroundObserver()
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.onReturnedToForeground()
        }
    }

    private func stopForegroundObserver() {
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
        }
        foregroundObserver = nil
    }

    private func onReturnedToForeground() {
        guard let sessionId = currentSessionId, purchaseContinuation != nil else { return }
        stopForegroundObserver()

        guard let provider = paymentProvider as? HeliumStripePaymentProvider else {
            resumePurchase(with: .failed(StripeOneTapError.noStripePaymentProvider))
            return
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                let confirmation = try await provider.confirmCheckoutSession(sessionId: sessionId)
                PendingCheckout.clear()
                // Dismiss SFSafariViewController if present
                await MainActor.run {
                    if let topVC = Self.topViewController(), topVC is SFSafariViewController {
                        topVC.dismiss(animated: true)
                    }
                }
                let txnId = confirmation.transactionId ?? sessionId
                let productId = currentProductId ?? confirmation.productId
                latestTransactionResult = HeliumTransactionIdResult(
                    productId: productId,
                    transactionId: txnId,
                    originalTransactionId: txnId
                )
                entitlementsSource?.didCompletePurchase(
                    heliumProductId: productId,
                    subscriptionExpiresAt: confirmation.expiresAt
                )
                resumePurchase(with: .purchased)
            } catch HeliumStripeAPIError.checkoutSessionNotCompleted {
                // Session not completed — user came back without paying
                PendingCheckout.clear()
                resumePurchase(with: .cancelled)
            } catch {
                // Network/server error — don't clear pending state, keep it for retry
                resumePurchase(with: .failed(error))
            }
        }
    }

    // MARK: - Pending Checkout Recovery (app terminated)

    private func resolvePendingCheckoutIfNeeded() {
        guard let pending = PendingCheckout.load() else { return }
        PendingCheckout.clear()

        guard !pending.isExpired else { return }
        guard let provider = paymentProvider as? HeliumStripePaymentProvider else { return }

        Task { [weak self] in
            guard let self else { return }
            do {
                let confirmation = try await provider.confirmCheckoutSession(sessionId: pending.sessionId)
                let txnId = confirmation.transactionId ?? pending.sessionId
                let productId = confirmation.productId.isEmpty ? pending.productId : confirmation.productId
                latestTransactionResult = HeliumTransactionIdResult(
                    productId: productId,
                    transactionId: txnId,
                    originalTransactionId: txnId
                )
                entitlementsSource?.didCompletePurchase(
                    heliumProductId: pending.productId,
                    subscriptionExpiresAt: confirmation.expiresAt
                )
            } catch {
                // Session wasn't completed — nothing to recover
            }
        }
    }

    // MARK: - Checkout Completion

    private func completeCheckout(result: StripeCheckoutResult) {
        guard let productId = currentProductId else { return }
        let sessionId = currentSessionId ?? ""

        switch result {
        case .success(let returnedSessionId):
            let resolvedSessionId = returnedSessionId ?? sessionId
            guard let provider = paymentProvider as? HeliumStripePaymentProvider else {
                resumePurchase(with: .failed(StripeOneTapError.noStripePaymentProvider))
                return
            }
            Task { [weak self] in
                guard let self else { return }
                do {
                    let confirmation = try await provider.confirmCheckoutSession(sessionId: resolvedSessionId)
                    let txnId = confirmation.transactionId ?? resolvedSessionId
                    latestTransactionResult = HeliumTransactionIdResult(
                        productId: confirmation.productId.isEmpty ? productId : confirmation.productId,
                        transactionId: txnId,
                        originalTransactionId: txnId
                    )
                    entitlementsSource?.didCompletePurchase(
                        heliumProductId: productId,
                        subscriptionExpiresAt: confirmation.expiresAt
                    )
                    resumePurchase(with: .purchased)
                } catch {
                    resumePurchase(with: .failed(error))
                }
            }
        case .cancelled:
            resumePurchase(with: .cancelled)
        case .failed(let error):
            resumePurchase(with: .failed(error))
        }
    }

    @MainActor
    private static func topViewController() -> UIViewController? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }?
            .rootViewController?
            .topMostViewController()
    }

    open func restorePurchases() async -> Bool {
        // Refresh both StoreKit (via backup delegate) and Stripe entitlements in parallel
        async let stripeRefresh: Void = entitlementsSource?.refreshEntitlements() ?? ()
        async let backupRestore: Bool = backupDelegate.restorePurchases()
        _ = await backupRestore
        await stripeRefresh
        // hasAny() checks both StoreKit and third-party source
        return await Helium.entitlements.hasAny()
    }

    open func getLatestCompletedTransactionIdResult() -> HeliumTransactionIdResult? {
        return latestTransactionResult
    }
    
    func syncCustomerMetadata() async {
        guard let provider = paymentProvider as? HeliumStripePaymentProvider else { return }
        let _ = try? await provider.updateCustomerMetadata()
    }
    
    func refreshEntitlements() async {
        await entitlementsSource?.refreshEntitlements()
    }

    func createPortalSession(returnUrl: String) async throws -> URL {
        guard let provider = paymentProvider as? HeliumStripePaymentProvider else {
            throw StripeOneTapError.noStripePaymentProvider
        }
        return try await provider.createPortalSession(returnUrl: returnUrl)
    }

    private func isPaymentIntentSecret(_ clientSecret: String) -> Bool {
        clientSecret.hasPrefix("pi_")
    }

    private func extractIntentId(from clientSecret: String) -> String? {
        // Client secret format: pi_xxx_secret_yyy → pi_xxx, seti_xxx_secret_yyy → seti_xxx
        let components = clientSecret.components(separatedBy: "_secret_")
        return components.first
    }

    private func resumePurchase(with status: sending HeliumPaywallTransactionStatus) {
        stopForegroundObserver()
        purchaseContinuation?.resume(returning: status)
        purchaseContinuation = nil
        currentProductId = nil
        currentClientSecret = nil
        currentPaymentMethodId = nil
        currentSessionId = nil
    }
    
    public func onPaywallEvent(_ event: any HeliumEvent) {
        backupDelegate.onPaywallEvent(event)
    }
    
}

// MARK: - ApplePayContextDelegate

extension StripeOneTapPurchaseDelegate: ApplePayContextDelegate {

    public func applePayContext(
        _ context: STPApplePayContext,
        didCreatePaymentMethod paymentMethod: StripeAPI.PaymentMethod,
        paymentInformation: PKPayment
    ) async throws -> String {
        guard let productId = currentProductId else {
            throw StripeOneTapError.noProductId
        }

        currentPaymentMethodId = paymentMethod.id

        let clientSecret = try await paymentProvider.fetchClientSecret(
            for: productId,
            paymentMethod: paymentMethod,
            paymentInformation: paymentInformation
        )
        currentClientSecret = clientSecret
        return clientSecret
    }

    public func applePayContext(
        _ context: STPApplePayContext,
        didCompleteWith status: STPApplePayContext.PaymentStatus,
        error: Error?
    ) {
        switch status {
        case .success:
            let productId = currentProductId
            let clientSecret = currentClientSecret
            let paymentMethodId = currentPaymentMethodId
            let provider = paymentProvider
            Task { [weak self] in
                guard let self else { return }
                do {
                    if let productId {
                        let transactionId: String?
                        if let clientSecret, isPaymentIntentSecret(clientSecret) == true {
                            // Payment intent flow: payment already confirmed, skip didCompletePayment
                            transactionId = extractIntentId(from: clientSecret)
                        } else {
                            // Setup intent flow: need to create subscription/charge
                            let paymentSuccessResponse = try await provider.didCompletePayment(for: productId, paymentMethodId: paymentMethodId ?? "")
                            transactionId = paymentSuccessResponse.transactionId
                            entitlementsSource?.didCompletePurchase(heliumProductId: productId, subscriptionExpiresAt: paymentSuccessResponse.expiresAt)
                        }
                        if let transactionId {
                            latestTransactionResult = HeliumTransactionIdResult(
                                productId: productId,
                                transactionId: transactionId,
                                originalTransactionId: transactionId
                            )
                        }
                    }
                    resumePurchase(with: .purchased)
                } catch {
                    resumePurchase(with: .failed(error))
                }
            }

        case .userCancellation:
            resumePurchase(with: .cancelled)

        case .error:
            resumePurchase(with: .failed(error ?? StripeOneTapError.unknownError))

        @unknown default:
            resumePurchase(with: .failed(error ?? StripeOneTapError.unknownError))
        }
    }
}

// MARK: - SFSafariViewControllerDelegate

extension StripeOneTapPurchaseDelegate: SFSafariViewControllerDelegate {
    public func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
        // User tapped "Done" — they may have completed payment first.
        // Check with the server before deciding.
        onReturnedToForeground()
    }
}

// MARK: - Error

enum StripeOneTapError: LocalizedError {
    case noProductId
    case unknownError
    case stripeApplePayNotAvailable
    case stripeApplePayContextError
    case noStripePaymentProvider
    case stripeOneTapNotInitialized
    case checkoutSessionCreationFailed
    case checkoutWebViewFailed

    var errorDescription: String? {
        switch self {
        case .noProductId:
            return "No product ID set for the current purchase"
        case .unknownError:
            return "An unknown Apple Pay error occurred"
        case .stripeApplePayNotAvailable:
            return "Stripe Apple Pay not available on this device"
        case .stripeApplePayContextError:
            return "Could not create Stripe Apple Pay context"
        case .noStripePaymentProvider:
            return "Portal session requires HeliumStripePaymentProvider"
        case .stripeOneTapNotInitialized:
            return "Call initializeWithStripeOneTap() before using this method"
        case .checkoutSessionCreationFailed:
            return "Failed to create Stripe Checkout session"
        case .checkoutWebViewFailed:
            return "Could not present the checkout web view"
        }
    }
}

// MARK: - UIViewController Helper

private extension UIViewController {
    func topMostViewController() -> UIViewController {
        if let presented = presentedViewController {
            return presented.topMostViewController()
        }
        if let nav = self as? UINavigationController, let visible = nav.visibleViewController {
            return visible.topMostViewController()
        }
        if let tab = self as? UITabBarController, let selected = tab.selectedViewController {
            return selected.topMostViewController()
        }
        return self
    }
}
