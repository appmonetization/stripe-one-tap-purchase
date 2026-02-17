import StripeApplePay
import PassKit
import Foundation

private let heliumBaseURL = "https://api-v2.tryhelium.com/"

public struct HeliumStripePaymentProvider: StripeOneTapPaymentProvider {

    private let apiKey: String

    public init(apiKey: String) {
        self.apiKey = apiKey
    }

    // MARK: - configurePaymentRequest

    public func configurePaymentRequest(_ request: PKPaymentRequest, for productId: String) {
        // TODO: Fetch product info from Helium's product catalog and configure:
        //   - request.paymentSummaryItems (amount, label)
        //   - request.requiredShippingContactFields (if we need name/email)
        //   - request.requiredBillingContactFields (if we need address)
        //   - request.recurringPaymentRequest (for subscriptions)

        request.requiredShippingContactFields = [.name]//, .emailAddress]
//        request.requiredBillingContactFields = [.postalAddress]

        // Free trial: $0 today, then $9.99/month
        let trialItem = PKPaymentSummaryItem(label: "7-day Free Trial", amount: NSDecimalNumber.zero, type: .final)
        let recurringItem = PKPaymentSummaryItem(label: "Premium Monthly (after trial)", amount: NSDecimalNumber(string: "9.99"), type: .final)
        let total = PKPaymentSummaryItem(label: "Helium", amount: NSDecimalNumber.zero, type: .final)
        request.paymentSummaryItems = [trialItem, recurringItem, total]

        // Recurring payment details shown on the Apple Pay sheet
        let regularBilling = PKRecurringPaymentSummaryItem(label: "Premium Monthly", amount: NSDecimalNumber(string: "9.99"))
        regularBilling.intervalUnit = .month
        regularBilling.startDate = Calendar.current.date(byAdding: .day, value: 7, to: Date())

        let trialBilling = PKRecurringPaymentSummaryItem(label: "7-day Free Trial", amount: NSDecimalNumber.zero)

        // TODO only allow if ios 16 + ???
        if #available(iOS 16.0, *) {
            let recurringRequest = PKRecurringPaymentRequest(
                paymentDescription: "Premium Monthly",
                regularBilling: regularBilling,
                managementURL: URL(string: "https://tryhelium.com/manage")!
            )
            recurringRequest.trialBilling = trialBilling
            recurringRequest.billingAgreement = "You will be charged $9.99/month after your 7-day free trial ends. Cancel anytime."
            request.recurringPaymentRequest = recurringRequest
        }
    }

    // MARK: - fetchClientSecret

    /// POST /stripe/setup-intent
    ///
    /// Creates a Stripe Customer (or finds existing), attaches the payment method,
    /// and creates a SetupIntent for card authorization.
    ///
    /// Request body:
    /// ```json
    /// {
    ///   "product_id": "premium_monthly",
    ///   "payment_method_id": "pm_xxx",
    ///   "name": "John Doe",
    ///   "email": "john@example.com",
    ///   "billing_address": {
    ///     "line1": "123 Main St",
    ///     "city": "San Francisco",
    ///     "state": "CA",
    ///     "postal_code": "94105",
    ///     "country": "US"
    ///   }
    /// }
    /// ```
    ///
    /// Response body:
    /// ```json
    /// {
    ///   "client_secret": "seti_xxx_secret_yyy",
    ///   "customer_id": "cus_xxx"
    /// }
    /// ```
    @MainActor
    public func fetchClientSecret(
        for productId: String,
        paymentMethod: StripeAPI.PaymentMethod,
        paymentInformation: PKPayment
    ) async throws -> String {
        let contact = paymentInformation.billingContact

        let body: [String: Any] = [
            "product_id": productId,
            "payment_method_id": paymentMethod.id ?? "",
            "name": formatName(from: contact?.name),
            "email": contact?.emailAddress ?? "",
            "billing_address": [
                "line1": contact?.postalAddress?.street ?? "",
                "city": contact?.postalAddress?.city ?? "",
                "state": contact?.postalAddress?.state ?? "",
                "postal_code": contact?.postalAddress?.postalCode ?? "",
                "country": contact?.postalAddress?.isoCountryCode ?? ""
            ]
        ]

        let response: SetupIntentResponse = try await post("stripe/setup-intent", body: body)
        return response.clientSecret
    }

    // MARK: - didCompletePayment

    /// POST /stripe/create-subscription
    ///
    /// Called after Apple Pay confirms the SetupIntent. Creates the actual
    /// subscription (or one-time charge) using the now-confirmed payment method.
    ///
    /// Request body:
    /// ```json
    /// {
    ///   "product_id": "premium_monthly"
    /// }
    /// ```
    ///
    /// Response body:
    /// ```json
    /// {
    ///   "subscription_id": "sub_xxx",
    ///   "status": "active"
    /// }
    /// ```
    public func didCompletePayment(for productId: String) async throws {
        let body: [String: Any] = [
            "product_id": productId
        ]

        let _: SubscriptionResponse = try await post("stripe/create-subscription", body: body)
    }

    // MARK: - Networking

    private func post<T: Decodable>(_ path: String, body: [String: Any]) async throws -> T {
        let url = URL(string: heliumBaseURL + path)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            let http = response as? HTTPURLResponse
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw HeliumStripeAPIError.serverError(statusCode: http?.statusCode ?? 0, message: message)
        }

        return try JSONDecoder().decode(T.self, from: data)
    }

    private func formatName(from nameComponents: PersonNameComponents?) -> String {
        [nameComponents?.givenName, nameComponents?.familyName]
            .compactMap { $0 }
            .joined(separator: " ")
    }
}

// MARK: - Response Types

private struct SetupIntentResponse: Decodable {
    let clientSecret: String
    let customerId: String

    enum CodingKeys: String, CodingKey {
        case clientSecret = "client_secret"
        case customerId = "customer_id"
    }
}

private struct SubscriptionResponse: Decodable {
    let subscriptionId: String
    let status: String

    enum CodingKeys: String, CodingKey {
        case subscriptionId = "subscription_id"
        case status
    }
}

// MARK: - Error

enum HeliumStripeAPIError: LocalizedError {
    case serverError(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .serverError(let statusCode, let message):
            return "Helium Stripe API error (\(statusCode)): \(message)"
        }
    }
}
