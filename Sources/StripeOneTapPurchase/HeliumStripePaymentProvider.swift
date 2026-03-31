import StripeApplePay
import PassKit
import Foundation
import Helium

private enum OfferPaymentMode {
    static let freeTrial = "FreeTrial"
    static let payAsYouGo = "PayAsYouGo"
    static let payUpFront = "PayUpFront"
}

public struct HeliumStripePaymentProvider: StripeOneTapPaymentProvider {

    private let apiKey: String
    private let merchantName: String
    private let managementURL: URL

    public init(apiKey: String, merchantName: String, managementURL: URL) {
        self.apiKey = apiKey
        self.merchantName = merchantName
        self.managementURL = managementURL
    }

    // MARK: - configurePaymentRequest

    public func configurePaymentRequest(_ request: PKPaymentRequest, for productId: String) {
        request.requiredShippingContactFields = [.name, .emailAddress]
        request.requiredBillingContactFields = [.name, .emailAddress, .postalAddress]

        guard let priceMap = HeliumFetchedConfigManager.shared.getServerProductsPriceMap(),
              let product = priceMap[productId] else {
            // No product data available — show a pending total so the sheet can still appear
            request.paymentSummaryItems = [
                PKPaymentSummaryItem(label: "Total", amount: NSDecimalNumber.zero, type: .pending)
            ]
            return
        }

        if let productCurrency = product.currency {
            request.currencyCode = productCurrency
        }

        let label = product.localizedTitle ?? productId
        let price = NSDecimalNumber(decimal: product.value ?? 0)

        let localizedPrice = product.toLocalizedPrice()
        if let subInfo = localizedPrice.subscriptionInfo {
            configureSubscription(request, label: label, price: price, product: product, subscription: subInfo)
        } else {
            // One-time purchase
            request.paymentSummaryItems = [
                PKPaymentSummaryItem(label: label, amount: price, type: .final),
                PKPaymentSummaryItem(label: merchantName, amount: price, type: .final)
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

        // Compute the date regular billing starts (end of intro offer)
        let regularStartDate: Date? = introOffer.flatMap { offer in
            let totalOfferDuration = offer.periodValue * offer.periodCount
            return Calendar.current.date(
                byAdding: calendarComponent(from: offer.periodUnit),
                value: totalOfferDuration,
                to: Date()
            )
        }

        if let offer = introOffer {
            let offerPrice = NSDecimalNumber(decimal: offer.price)
            let offerLabel = formatIntroOfferLabel(offer)
            let formattedPrice = product.formattedPrice ?? price.stringValue
            let startDateLabel = regularStartDate.map { formatShortDate($0) } ?? ""
            let regularLabel = "\(formattedPrice)/\(subscription.periodUnit) starting \(startDateLabel)"

            items.append(PKPaymentSummaryItem(label: offerLabel, amount: offerPrice, type: .final))
            items.append(PKPaymentSummaryItem(label: regularLabel, amount: price, type: .final))
            todayAmount = offerPrice
        } else {
            items.append(PKPaymentSummaryItem(label: "\(label) (per \(subscription.periodUnit))", amount: price, type: .final))
        }

        // Last item is the total charged today — label is shown as "PAY TO" on the sheet
        items.append(PKPaymentSummaryItem(label: merchantName, amount: todayAmount, type: .final))
        request.paymentSummaryItems = items

        // PKRecurringPaymentRequest (iOS 16+)
        if #available(iOS 16.0, *) {
            let regularBilling = PKRecurringPaymentSummaryItem(label: label, amount: price)
            regularBilling.intervalUnit = calendarUnit(from: subscription.periodUnit)
            regularBilling.intervalCount = calendarIntervalCount(from: subscription.periodUnit, value: subscription.periodValue)

            if introOffer != nil {
                regularBilling.startDate = regularStartDate
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
                trialBilling.intervalCount = calendarIntervalCount(from: offer.periodUnit, value: offer.periodValue)
                recurringRequest.trialBilling = trialBilling

                recurringRequest.billingAgreement = buildBillingAgreement(
                    product: product, offer: offer
                )
            }

            request.recurringPaymentRequest = recurringRequest
        }
    }

    // MARK: - fetchClientSecret

    /// Creates a Stripe Customer (or finds existing), attaches the payment method,
    /// and creates a SetupIntent for card authorization.
    @MainActor
    public func fetchClientSecret(
        for productId: String,
        paymentMethod: StripeAPI.PaymentMethod,
        paymentInformation: PKPayment
    ) async throws -> String {
        let billing = paymentInformation.billingContact
        let shipping = paymentInformation.shippingContact

        var body = baseRequestBody(productId: productId)
        body["customerInfo"] = [
            "paymentMethodId": paymentMethod.id,
            "name": formatName(from: shipping?.name ?? billing?.name),
            "email": shipping?.emailAddress ?? billing?.emailAddress ?? "",
            "billingAddress": [
                "line1": billing?.postalAddress?.street ?? "",
                "city": billing?.postalAddress?.city ?? "",
                "state": billing?.postalAddress?.state ?? "",
                "postalCode": billing?.postalAddress?.postalCode ?? "",
                "country": billing?.postalAddress?.isoCountryCode ?? ""
            ]
        ]

        let response: SetupIntentResponse = try await post("stripe/create-intent", body: body)
        guard let clientSecret = response.clientSecret else {
            throw HeliumStripeAPIError.serverError(statusCode: 200, message: "No client secret returned from the server.")
        }
        if let stripeCustomerId = response.stripeCustomerId {
            HeliumIdentityManager.shared.setStripeCustomerId(stripeCustomerId)
        }
        return clientSecret
    }

    // MARK: - didCompletePayment

    /// Called after Apple Pay confirms the SetupIntent. Creates the actual
    /// subscription (or one-time charge) using the now-confirmed payment method.
    public func didCompletePayment(for productId: String, paymentMethodId: String) async throws -> PaymentSuccessResponse {
        var body = baseRequestBody(productId: productId)
        body["paymentMethodId"] = paymentMethodId

        let response: ExecutePurchaseResponse = try await post("stripe/execute-purchase", body: body)
        return response.toPaymentSuccessResponse(fallbackProductId: productId)
    }

    // MARK: - Update Customer Metadata

    @discardableResult
    public func updateCustomerMetadata(
        name: String? = nil,
        email: String? = nil,
        phone: String? = nil,
        description: String? = nil
    ) async throws -> Bool {
        let userId = Helium.identify.userId ?? HeliumIdentityManager.shared.getHeliumPersistentId()
        let rcUserId = Helium.identify.revenueCatAppUserId ?? ""
        let heliumPersistentId = HeliumIdentityManager.shared.getHeliumPersistentId()
        let appTransactionId = HeliumIdentityManager.shared.getAppTransactionID() ?? ""

        var body: [String: Any] = [
            "apiKey": apiKey,
            "userId": userId,
            "rcUserId": rcUserId,
            "stripeCustomerId": HeliumIdentityManager.shared.getStripeCustomerId() ?? "",
            "heliumPersistentId": heliumPersistentId,
            "appTransactionId": appTransactionId,
            "metadata": [
                "userId": userId,
                "rcUserId": rcUserId,
                "heliumPersistentId": heliumPersistentId,
                "appTransactionId": appTransactionId
            ]
        ]

        if let name { body["name"] = name }
        if let email { body["email"] = email }
        if let phone { body["phone"] = phone }
        if let description { body["description"] = description }

        let response: UpdateCustomerMetadataResponse = try await post("stripe/update-customer-metadata", body: body)
        if let customerId = response.customerId, HeliumIdentityManager.shared.getStripeCustomerId() == nil {
            HeliumIdentityManager.shared.setStripeCustomerId(customerId)
        }
        return response.updated ?? false
    }

    // MARK: - Portal Session

    public func createPortalSession(returnUrl: String) async throws -> URL {
        let body: [String: Any] = [
            "apiKey": apiKey,
            "userId": Helium.identify.userId ?? HeliumIdentityManager.shared.getHeliumPersistentId(),
            "rcUserId": Helium.identify.revenueCatAppUserId ?? "",
            "stripeCustomerId": HeliumIdentityManager.shared.getStripeCustomerId() ?? "",
            "heliumPersistentId": HeliumIdentityManager.shared.getHeliumPersistentId(),
            "appTransactionId": HeliumIdentityManager.shared.getAppTransactionID() ?? "",
            "returnUrl": returnUrl
        ]

        let response: PortalSessionResponse = try await post("stripe/create-portal-session", body: body)
        guard let portalUrl = response.portalUrl, let url = URL(string: portalUrl) else {
            throw HeliumStripeAPIError.serverError(statusCode: 200, message: "No portal URL returned from the server.")
        }
        return url
    }

    // MARK: - Checkout Session

    /// Creates a Stripe Checkout Session and returns the hosted checkout URL.
    /// Used for the app2web flow when Apple Pay is not available.
    public func createCheckoutSession(
        productPriceId: String,
        successURL: String,
        cancelURL: String
    ) async throws -> (checkoutURL: URL, sessionId: String) {
        var body = baseRequestBody(productId: productPriceId)
        body["successUrl"] = successURL
        body["cancelUrl"] = cancelURL

        let response: CheckoutSessionResponse = try await post("stripe/create-checkout-session", body: body)
        if let stripeCustomerId = response.stripeCustomerId {
            HeliumIdentityManager.shared.setStripeCustomerId(stripeCustomerId)
        }
        guard let checkoutUrlString = response.checkoutURL, let url = URL(string: checkoutUrlString) else {
            throw HeliumStripeAPIError.serverError(statusCode: 200, message: "No checkout URL returned from the server.")
        }
        return (checkoutURL: url, sessionId: response.sessionId ?? "")
    }

    // MARK: - Confirm Checkout

    /// Confirms a completed Stripe Checkout Session and returns the purchase details.
    /// Throws if the session has not been completed yet.
    public func confirmCheckoutSession(sessionId: String) async throws -> PaymentSuccessResponse {
        let body: [String: Any] = [
            "apiKey": apiKey,
            "sessionId": sessionId,
            "userId": Helium.identify.userId ?? HeliumIdentityManager.shared.getHeliumPersistentId(),
            "rcUserId": Helium.identify.revenueCatAppUserId ?? ""
        ]

        let response: ExecutePurchaseResponse = try await post("stripe/confirm-checkout", body: body)

        guard response.status == "complete" || response.transactionId != nil else {
            throw HeliumStripeAPIError.serverError(statusCode: 200, message: "Checkout session not completed")
        }

        return response.toPaymentSuccessResponse()
    }

    // MARK: - Networking

    private func post<T: Decodable>(_ path: String, body: [String: Any]) async throws -> T {
        guard let url = URL(string: heliumBaseURL + path) else {
            throw HeliumStripeAPIError.invalidEndpoint(path: path)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("gzip, deflate", forHTTPHeaderField: "Accept-Encoding")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            let http = response as? HTTPURLResponse
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw HeliumStripeAPIError.serverError(statusCode: http?.statusCode ?? 0, message: message)
        }

        return try JSONDecoder().decode(T.self, from: data)
    }

    private func baseRequestBody(productId: String) -> [String: Any] {
        [
            "apiKey": apiKey,
            "productPriceId": productId,
            "userId": Helium.identify.userId ?? HeliumIdentityManager.shared.getHeliumPersistentId(),
            "rcUserId": Helium.identify.revenueCatAppUserId ?? "",
            "stripeCustomerId": HeliumIdentityManager.shared.getStripeCustomerId() ?? "",
            "heliumPersistentId": HeliumIdentityManager.shared.getHeliumPersistentId(),
            "appTransactionId": HeliumIdentityManager.shared.getAppTransactionID() ?? ""
        ]
    }

    private func formatName(from nameComponents: PersonNameComponents?) -> String {
        [nameComponents?.givenName, nameComponents?.familyName]
            .compactMap { $0 }
            .joined(separator: " ")
    }
}

// MARK: - Response Types

private struct SetupIntentResponse: Decodable {
    let clientSecret: String?
    let setupIntentId: String?
    let stripeCustomerId: String?
}

private struct ExecutePurchaseResponse: Decodable {
    let subscriptionId: String?
    let subscriptionItemId: String?
    let productId: String?
    let priceId: String?
    let paymentIntentId: String?
    let status: String?
    let expiresAt: String?
    let requestId: String?

    /// Canonical transaction ID derivation — used by both execute-purchase and confirm-checkout flows.
    var transactionId: String? {
        subscriptionItemId ?? subscriptionId ?? paymentIntentId
    }

    func toPaymentSuccessResponse(fallbackProductId: String = "") -> PaymentSuccessResponse {
        PaymentSuccessResponse(
            productId: productId ?? fallbackProductId,
            expiresAt: parseISODate(expiresAt),
            transactionId: transactionId
        )
    }
}

private struct UpdateCustomerMetadataResponse: Decodable {
    let customerId: String?
    let updated: Bool?
    let requestId: String?
}

private struct CheckoutSessionResponse: Decodable {
    let checkoutURL: String?
    let sessionId: String?
    let stripeCustomerId: String?
}

private struct PortalSessionResponse: Decodable {
    let portalUrl: String?
    let customerId: String?
    let requestId: String?
}

// MARK: - Helpers

/// Returns a valid `NSCalendar.Unit` for `PKRecurringPaymentSummaryItem`.
/// Apple Pay only supports year, month, day, hour, minute — **not** week.
private func calendarUnit(from periodUnit: String) -> NSCalendar.Unit {
    switch periodUnit.lowercased() {
    case "day": return .day
    case "week": return .day      // weeks → days (multiply intervalCount by 7)
    case "month": return .month
    case "year": return .year
    default: return .month
    }
}

/// Converts the interval count to match `calendarUnit(from:)`.
/// Apple Pay doesn't support "week" as an intervalUnit, so we express it as days.
/// Stripe treats 1 week as exactly 7 days, so hardcoding * 7 is safe.
/// See: https://docs.stripe.com/billing/subscriptions/mixed-interval
private func calendarIntervalCount(from periodUnit: String, value: Int) -> Int {
    periodUnit.lowercased() == "week" ? value * 7 : value
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

/// Hyphenated form for use as an adjective (e.g., "3-month Free Trial")
private func formatPeriodDescription(unit: String, value: Int) -> String {
    switch unit.lowercased() {
    case "day": return value == 1 ? "1-day" : "\(value)-day"
    case "week": return value == 1 ? "1-week" : "\(value)-week"
    case "month": return value == 1 ? "1-month" : "\(value)-month"
    case "year": return value == 1 ? "1-year" : "\(value)-year"
    default: return "\(value) \(unit)"
    }
}

/// Formats a date as "Feb 28" style for display in payment labels
private func formatShortDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "MMM d"
    return formatter.string(from: date)
}

private func buildBillingAgreement(product: ServerProductPrice, offer: SubscriptionOffer) -> String {
    let regularPrice = product.formattedPrice ?? ""
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
    case invalidEndpoint(path: String)

    var errorDescription: String? {
        switch self {
        case .serverError(let statusCode, let message):
            return "Helium Stripe API error (\(statusCode)): \(message)"
        case .invalidEndpoint(let path):
            return "Invalid endpoint \(path)"
        }
    }
}

func parseISODate(_ dateString: String?) -> Date? {
    guard let dateString = dateString else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    // Try without fractional seconds first, then with
    if let date = formatter.date(from: dateString) {
        return date
    }
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: dateString)
}
