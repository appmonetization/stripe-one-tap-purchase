import StripeApplePay
import PassKit

public struct HeliumStripePaymentProvider: StripeOneTapPaymentProvider {

    public init() {}

    public func configurePaymentRequest(_ request: PKPaymentRequest, for productId: String) {
        // TODO: Configure the payment request for this product.
        // Examples:
        //   request.paymentSummaryItems = [
        //       PKPaymentSummaryItem(label: "Monthly Plan", amount: NSDecimalNumber(string: "9.99")),
        //       PKPaymentSummaryItem(label: "Your App", amount: NSDecimalNumber(string: "9.99"))
        //   ]
        //   request.requiredShippingContactFields = [.name, .emailAddress]
        //   request.requiredBillingContactFields = [.postalAddress]
        //   request.recurringPaymentRequest = PKRecurringPaymentRequest(...)
    }

    @MainActor
    public func fetchClientSecret(
        for productId: String,
        paymentMethod: StripeAPI.PaymentMethod,
        paymentInformation: PKPayment
    ) async throws -> String {
        // TODO: Call your server to create a PaymentIntent or SetupIntent.
        // Return the client secret (e.g. "pi_xxx_secret_yyy" or "seti_xxx_secret_yyy").
        //
        // You have access to:
        //   - productId: the product being purchased
        //   - paymentMethod.id: Stripe payment method ID to attach server-side
        //   - paymentInformation.billingContact: name, email, postal address
        //   - paymentInformation.shippingContact: shipping info if requested
        fatalError("HeliumStripePaymentProvider.fetchClientSecret is not implemented")
    }

    public func didCompletePayment(for productId: String) async throws {
        // TODO: (Optional) Perform post-payment work after Stripe confirms the payment.
        // For example, create a subscription after a SetupIntent confirms:
        //   try await yourServer.createSubscription(for: productId)
    }
}
