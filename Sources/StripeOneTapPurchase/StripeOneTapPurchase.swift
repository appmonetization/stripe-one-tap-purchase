import Helium
import StripeApplePay
import PassKit
import UIKit

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

    private var currentProductId: String?
    private var currentClientSecret: String?
    private var currentPaymentMethodId: String?
    private var purchaseContinuation: CheckedContinuation<HeliumPaywallTransactionStatus, Never>?
    private var latestTransactionResult: HeliumTransactionIdResult?

    public init(
        backupDelegate: HeliumPaywallDelegate,
        paymentProvider: StripeOneTapPaymentProvider,
        merchantIdentifier: String,
        countryCode: String = "US",
        currencyCode: String = "USD"
    ) {
        self.backupDelegate = backupDelegate
        self.paymentProvider = paymentProvider
        self.merchantIdentifier = merchantIdentifier
        self.countryCode = countryCode
        self.currencyCode = currencyCode
        super.init()
    }

    deinit {
        purchaseContinuation?.resume(returning: .cancelled)
    }

    open func makePurchase(productId: String) async -> HeliumPaywallTransactionStatus {
        let allStripeProductIds = Array((HeliumFetchedConfigManager.shared.getStripeProductsPriceMap() ?? [:]).keys)
        if !allStripeProductIds.contains(productId) {
            return await backupDelegate.makePurchase(productId: productId)
        }

        currentProductId = productId
        currentClientSecret = nil

        return await presentApplePayFlow(for: productId)
    }

    /// Runs the entire Apple Pay flow on the main actor so that
    /// STPApplePayContext and PKPaymentRequest never cross isolation boundaries.
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

    open func restorePurchases() async -> Bool {
        return await backupDelegate.restorePurchases()
    }

    open func getLatestCompletedTransactionIdResult() -> HeliumTransactionIdResult? {
        return latestTransactionResult
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
        purchaseContinuation?.resume(returning: status)
        purchaseContinuation = nil
        currentProductId = nil
        currentClientSecret = nil
        currentPaymentMethodId = nil
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
                            StripeCheckoutManager.shared.handleNewPurchase(productId: productId, priceId: paymentSuccessResponse.priceId, subscriptionExpiresAt: paymentSuccessResponse.expiresAt)
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

// MARK: - Error

enum StripeOneTapError: LocalizedError {
    case noProductId
    case unknownError
    case stripeApplePayNotAvailable
    case stripeApplePayContextError
    case noStripePaymentProvider
    case stripeOneTapNotInitialized

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
        }
    }
}
