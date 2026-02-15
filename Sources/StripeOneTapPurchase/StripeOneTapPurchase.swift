import Helium
import StripeApplePay
import PassKit

// MARK: - Payment Provider Protocol

public protocol StripeOneTapPaymentProvider: Sendable {
    /// Called during Apple Pay flow to get the PaymentIntent client secret from your server.
    /// The productId is provided so you can create the correct PaymentIntent server-side.
    func fetchPaymentIntentClientSecret(for productId: String) async throws -> String
}

// MARK: - StripeOneTapPurchaseDelegate

open class StripeOneTapPurchaseDelegate: NSObject, HeliumPaywallDelegate, HeliumDelegateReturnsTransaction {

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

    open func makePurchase(productId: String) async -> HeliumPaywallTransactionStatus {
        guard StripeAPI.deviceSupportsApplePay() else {
            return await backupDelegate.makePurchase(productId: productId)
        }

        currentProductId = productId
        currentClientSecret = nil

        let paymentRequest = StripeAPI.paymentRequest(
            withMerchantIdentifier: merchantIdentifier,
            country: countryCode,
            currency: currencyCode
        )
        paymentRequest.paymentSummaryItems = [
            PKPaymentSummaryItem(label: "Total", amount: NSDecimalNumber.zero, type: .pending)
        ]

        guard let applePayContext = STPApplePayContext(paymentRequest: paymentRequest, delegate: self) else {
            return await backupDelegate.makePurchase(productId: productId)
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

        let clientSecret = try await paymentProvider.fetchPaymentIntentClientSecret(for: productId)
        currentClientSecret = clientSecret
        return clientSecret
    }

    public func applePayContext(
        _ context: STPApplePayContext,
        didCompleteWith status: STPApplePayContext.PaymentStatus,
        error: Error?
    ) {
        let transactionStatus: HeliumPaywallTransactionStatus

        switch status {
        case .success:
            if let clientSecret = currentClientSecret,
               let paymentIntentId = extractPaymentIntentId(from: clientSecret),
               let productId = currentProductId {
                latestTransactionResult = HeliumTransactionIdResult(
                    productId: productId,
                    transactionId: paymentIntentId,
                    originalTransactionId: paymentIntentId
                )
            }
            transactionStatus = .purchased
        case .userCancellation:
            transactionStatus = .cancelled
        case .error:
            transactionStatus = .failed(error ?? StripeOneTapError.unknownError)
        @unknown default:
            transactionStatus = .failed(error ?? StripeOneTapError.unknownError)
        }

        purchaseContinuation?.resume(returning: transactionStatus)
        purchaseContinuation = nil
        currentProductId = nil
        currentClientSecret = nil
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
