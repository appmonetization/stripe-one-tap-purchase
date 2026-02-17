import Helium
import StripeApplePay
import PassKit

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
    func didCompletePayment(for productId: String) async throws
}

// MARK: - Default Implementations

extension StripeOneTapPaymentProvider {

    public func configurePaymentRequest(_ request: PKPaymentRequest, for productId: String) {}

    public func didCompletePayment(for productId: String) async throws {}
}

// MARK: - StripeOneTapPurchaseDelegate

open class StripeOneTapPurchaseDelegate: NSObject, HeliumPaywallDelegate, HeliumDelegateReturnsTransaction, @unchecked Sendable {

    public var delegateType: String { "stripe_one_tap" }

    private let backupDelegate: HeliumPaywallDelegate
    private let paymentProvider: StripeOneTapPaymentProvider
    private let merchantIdentifier: String
    private let countryCode: String
    private let currencyCode: String

    private var currentProductId: String?
    private var currentClientSecret: String?
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
        guard StripeAPI.deviceSupportsApplePay() else {
            return await backupDelegate.makePurchase(productId: productId)
        }

        currentProductId = productId
        currentClientSecret = nil

        if let status = await presentApplePayFlow(for: productId) {
            return status
        }

        return await backupDelegate.makePurchase(productId: productId)
    }

    /// Runs the entire Apple Pay flow on the main actor so that
    /// STPApplePayContext and PKPaymentRequest never cross isolation boundaries.
    /// Returns nil if STPApplePayContext could not be created.
    @MainActor
    private func presentApplePayFlow(for productId: String) async -> sending HeliumPaywallTransactionStatus? {
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
            return nil
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

    private func extractPaymentIntentId(from clientSecret: String) -> String? {
        // Client secret format: pi_xxx_secret_yyy → pi_xxx
        let components = clientSecret.components(separatedBy: "_secret_")
        return components.first
    }

    private func resumePurchase(with status: sending HeliumPaywallTransactionStatus) {
        purchaseContinuation?.resume(returning: status)
        purchaseContinuation = nil
        currentProductId = nil
        currentClientSecret = nil
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
            if let clientSecret = currentClientSecret,
               let intentId = extractPaymentIntentId(from: clientSecret),
               let productId = currentProductId {
                latestTransactionResult = HeliumTransactionIdResult(
                    productId: productId,
                    transactionId: intentId,
                    originalTransactionId: intentId
                )
            }

            let productId = currentProductId
            let provider = paymentProvider
            Task { [weak self] in
                do {
                    if let productId {
                        try await provider.didCompletePayment(for: productId)
                    }
                    self?.resumePurchase(with: .purchased)
                } catch {
                    self?.resumePurchase(with: .failed(error))
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

    var errorDescription: String? {
        switch self {
        case .noProductId:
            return "No product ID set for the current purchase"
        case .unknownError:
            return "An unknown Apple Pay error occurred"
        }
    }
}
