import StripeApplePay
import PassKit
import Foundation
import Helium

private let heliumBaseURL = "https://api-v2.tryhelium.com/"

private enum OfferPaymentMode {
    static let freeTrial = "FreeTrial"
    static let payAsYouGo = "PayAsYouGo"
    static let payUpFront = "PayUpFront"
}

public struct HeliumStripePaymentProvider: StripeOneTapPaymentProvider {

    private let apiKey: String
    private let managementURL: URL?

    public init(apiKey: String, managementURL: URL? = nil) {
        self.apiKey = apiKey
        self.managementURL = managementURL
    }

    // MARK: - configurePaymentRequest

    public func configurePaymentRequest(_ request: PKPaymentRequest, for productId: String) {
        request.requiredBillingContactFields = [.name, .emailAddress, .postalAddress]

        guard let priceMap = HeliumFetchedConfigManager.shared.getServerProductsPriceMap(),
              let product = priceMap[productId] else {
            // No product data available — show a pending total so the sheet can still appear
            request.paymentSummaryItems = [
                PKPaymentSummaryItem(label: "Total", amount: NSDecimalNumber.zero, type: .pending)
            ]
            return
        }

        request.currencyCode = product.currency

        let label = product.localizedTitle ?? productId
        let price = NSDecimalNumber(decimal: product.value)

        if let sub = product.subscription {
            configureSubscription(request, label: label, price: price, product: product, subscription: sub)
        } else {
            // One-time purchase
            request.paymentSummaryItems = [
                PKPaymentSummaryItem(label: label, amount: price, type: .final),
                PKPaymentSummaryItem(label: label, amount: price, type: .final)
            ]
        }
    }

    // MARK: - Subscription Configuration

    private func configureSubscription(
        _ request: PKPaymentRequest,
        label: String,
        price: NSDecimalNumber,
        product: ServerProductPrice,
        subscription: SubscriptionInfo
    ) {
        let introOffer = subscription.introOfferEligible ? subscription.introOffer : nil
        var items: [PKPaymentSummaryItem] = []
        var todayAmount = price

        if let offer = introOffer {
            let offerPrice = NSDecimalNumber(decimal: offer.price)
            let offerLabel = formatIntroOfferLabel(offer)
            let duration = formatPeriodDescription(unit: offer.periodUnit, value: offer.periodValue * offer.periodCount)

            items.append(PKPaymentSummaryItem(label: offerLabel, amount: offerPrice, type: .final))
            items.append(PKPaymentSummaryItem(label: "\(label) (after \(duration))", amount: price, type: .final))
            todayAmount = offerPrice
        } else {
            items.append(PKPaymentSummaryItem(label: label, amount: price, type: .final))
        }

        // Last item is the total charged today
        items.append(PKPaymentSummaryItem(label: label, amount: todayAmount, type: .final))
        request.paymentSummaryItems = items

        // PKRecurringPaymentRequest (iOS 16+) — only if a management URL is provided
        if #available(iOS 16.0, *), let managementURL {
            let regularBilling = PKRecurringPaymentSummaryItem(label: label, amount: price)
            regularBilling.intervalUnit = calendarUnit(from: subscription.periodUnit)
            regularBilling.intervalCount = subscription.periodValue

            if let offer = introOffer {
                let totalOfferDuration = offer.periodValue * offer.periodCount
                regularBilling.startDate = Calendar.current.date(
                    byAdding: calendarComponent(from: offer.periodUnit),
                    value: totalOfferDuration,
                    to: Date()
                )
            }

            let recurringRequest = PKRecurringPaymentRequest(
                paymentDescription: label,
                regularBilling: regularBilling,
                managementURL: managementURL
            )

            if let offer = introOffer {
                let trialBilling = PKRecurringPaymentSummaryItem(
                    label: formatIntroOfferLabel(offer),
                    amount: NSDecimalNumber(decimal: offer.price)
                )
                trialBilling.intervalUnit = calendarUnit(from: offer.periodUnit)
                trialBilling.intervalCount = offer.periodValue
                recurringRequest.trialBilling = trialBilling

                recurringRequest.billingAgreement = buildBillingAgreement(
                    product: product, offer: offer
                )
            }

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

// MARK: - Helpers

private func calendarUnit(from periodUnit: String) -> NSCalendar.Unit {
    switch periodUnit.lowercased() {
    case "day": return .day
    case "week": return .weekOfMonth
    case "month": return .month
    case "year": return .year
    default: return .month
    }
}

private func calendarComponent(from periodUnit: String) -> Calendar.Component {
    switch periodUnit.lowercased() {
    case "day": return .day
    case "week": return .weekOfMonth
    case "month": return .month
    case "year": return .year
    default: return .month
    }
}

private func formatIntroOfferLabel(_ offer: SubscriptionOffer) -> String {
    let duration = formatPeriodDescription(unit: offer.periodUnit, value: offer.periodValue * offer.periodCount)
    if offer.paymentMode == OfferPaymentMode.freeTrial {
        return "\(duration) Free Trial"
    }
    return "\(duration) at \(offer.displayPrice)"
}

private func formatPeriodDescription(unit: String, value: Int) -> String {
    switch unit.lowercased() {
    case "day": return value == 1 ? "1-day" : "\(value)-day"
    case "week": return value == 1 ? "1-week" : "\(value)-week"
    case "month": return value == 1 ? "1-month" : "\(value)-month"
    case "year": return value == 1 ? "1-year" : "\(value)-year"
    default: return "\(value) \(unit)"
    }
}

private func buildBillingAgreement(product: ServerProductPrice, offer: SubscriptionOffer) -> String {
    let regularPrice = product.formattedPrice
    let period = product.subscription?.periodUnit ?? "month"
    let duration = formatPeriodDescription(unit: offer.periodUnit, value: offer.periodValue * offer.periodCount)

    if offer.paymentMode == OfferPaymentMode.freeTrial {
        return "You will be charged \(regularPrice)/\(period) after your \(duration) free trial ends. Cancel anytime."
    }
    return "You will be charged \(offer.displayPrice)/\(offer.periodUnit) during the introductory period, then \(regularPrice)/\(period). Cancel anytime."
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
