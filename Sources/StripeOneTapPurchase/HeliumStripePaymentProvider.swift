import StripeApplePay
import PassKit
import Foundation
import Helium

private enum OfferPaymentMode {
    static let freeTrial = "FreeTrial"
    static let payAsYouGo = "PayAsYouGo"
    static let payUpFront = "PayUpFront"
}

/// Customer contact details sent to the create-intent endpoint.
public struct StripeCustomerContact: Sendable {
    public var name: String?
    public var email: String?
    public var phone: String?

    public init(name: String? = nil, email: String? = nil, phone: String? = nil) {
        self.name = name
        self.email = email
        self.phone = phone
    }
}

/// The result of preparing a Stripe intent: the client secret plus the Helium
/// identity metadata stamped on the customer/SetupIntent. Forward `metadata` onto
/// any Stripe subscription created in `finalizePurchase` so Helium lookups resolve.
public struct StripeClientSecretResult: Sendable {
    public let clientSecret: String
    public let metadata: [String: String]

    public init(clientSecret: String, metadata: [String: String] = [:]) {
        self.clientSecret = clientSecret
        self.metadata = metadata
    }
}

/// Free or paid trial terms forwarded to an overridden `finalizePurchase` so the
/// Stripe subscription it creates matches what the paywall displayed.
public struct StripeTrialInfo: Sendable {
    public let paid: Bool
    public let days: Int
    /// Intro charge in the smallest currency unit (e.g. cents); nil when free.
    public let amount: Int?
    public let currency: String?
}

extension StripeTrialInfo {
    /// JSON-safe representation for request bodies. Optional fields are omitted when nil.
    public func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "paid": paid,
            "days": days
        ]
        if let amount {
            dict["amount"] = amount
        }
        if let currency {
            dict["currency"] = currency
        }
        return dict
    }
}

extension StripeTrialInfo {
    /// Derives trial terms from the on-launch offer for `heliumProductKey` — the same
    /// `introOffer` the paywall renders. Nil when there is no eligible trial.
    init?(heliumProductKey: String) {
        guard let product = HeliumFetchedConfigManager.shared.getStripeProductsPriceMap()?[heliumProductKey],
              let subscription = product.toLocalizedPrice().subscriptionInfo,
              subscription.introOfferEligible,
              let offer = subscription.introOffer else {
            return nil
        }
        let paid = offer.paymentMode != OfferPaymentMode.freeTrial
        self.init(
            paid: paid,
            days: offer.periodValue * offer.periodCount * trialDaysPerUnit(offer.periodUnit),
            amount: paid ? smallestCurrencyUnit(offer.price, currency: product.currency) : nil,
            currency: product.currency
        )
    }
}

open class HeliumStripePaymentProvider: StripeOneTapPaymentProvider, @unchecked Sendable {

    private let merchantName: String
    private let managementURL: URL

    public init(merchantName: String, managementURL: URL) {
        self.merchantName = merchantName
        self.managementURL = managementURL
    }

    // MARK: - configurePaymentRequest

    open func configurePaymentRequest(_ request: PKPaymentRequest, for productKey: String) {
        request.requiredShippingContactFields = [.name, .emailAddress]
        request.requiredBillingContactFields = [.name, .emailAddress, .postalAddress]

        guard let priceMap = HeliumFetchedConfigManager.shared.getStripeProductsPriceMap(),
              let product = priceMap[productKey] else {
            // No product data available — show a pending total so the sheet can still appear
            request.paymentSummaryItems = [
                PKPaymentSummaryItem(label: "Total", amount: NSDecimalNumber.zero, type: .pending)
            ]
            return
        }

        if let productCurrency = product.currency {
            request.currencyCode = productCurrency
        }

        let label = product.localizedTitle ?? productKey
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
            Calendar.current.date(byAdding: .day, value: trialDays(offer), to: Date())
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
                // Apple renders trialBilling as a separate row with its own cadence label
                // ("per week"/"per month") — we accept that wording in exchange for clearly
                // showing the offer and the recurring subscription as distinct rows.
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
    open func fetchClientSecret(
        for heliumProductKey: String,
        paymentMethod: StripeAPI.PaymentMethod,
        paymentInformation: PKPayment
    ) async throws -> StripeClientSecretResult {
        let billing = paymentInformation.billingContact
        let contact = stripeCustomerInfo(for: heliumProductKey, paymentInformation: paymentInformation)

        var customerInfo: [String: Any] = [
            "paymentMethodId": paymentMethod.id,
            "name": contact.name ?? "",
            "email": contact.email ?? "",
            "billingAddress": [
                "line1": billing?.postalAddress?.street ?? "",
                "city": billing?.postalAddress?.city ?? "",
                "state": billing?.postalAddress?.state ?? "",
                "postalCode": billing?.postalAddress?.postalCode ?? "",
                "country": billing?.postalAddress?.isoCountryCode ?? ""
            ]
        ]
        if let phone = contact.phone {
            customerInfo["phone"] = phone
        }

        var body = try HeliumStripeAPIClient.shared.baseRequestBody(productId: heliumProductKey)
        body["customerInfo"] = customerInfo

        let response: SetupIntentResponse = try await HeliumStripeAPIClient.shared.post("stripe/create-intent", body: body)
        guard let clientSecret = response.clientSecret else {
            throw HeliumPaymentAPIError.serverError(statusCode: 200, message: "No client secret returned from the server.")
        }
        if let stripeCustomerId = response.stripeCustomerId {
            HeliumIdentityManager.shared.setStripeCustomerId(stripeCustomerId)
        }
        return StripeClientSecretResult(clientSecret: clientSecret, metadata: response.metadata ?? [:])
    }

    // MARK: - stripeCustomerInfo

    /// Override to supply customer contact details (e.g. your app's logged-in user).
    /// Default derives name and email from the Apple Pay contact; phone is nil.
    @MainActor
    open func stripeCustomerInfo(for heliumProductKey: String, paymentInformation: PKPayment) -> StripeCustomerContact {
        let billing = paymentInformation.billingContact
        let shipping = paymentInformation.shippingContact
        return StripeCustomerContact(
            name: formatName(from: shipping?.name ?? billing?.name),
            email: shipping?.emailAddress ?? billing?.emailAddress
        )
    }

    // MARK: - finalizePurchase

    /// Called after Apple Pay confirms the SetupIntent. Creates the actual
    /// subscription (or one-time charge) using the now-confirmed payment method.
    /// The default ignores `metadata` and `trial` (the server applies them); overrides must
    /// copy `metadata` and honor `trial` on the Stripe subscription they create.
    @MainActor
    open func finalizePurchase(for heliumProductKey: String, paymentMethod: StripeAPI.PaymentMethod, metadata: [String: String], trial: StripeTrialInfo?) async throws -> PaymentSuccessResponse {
        var body = try HeliumStripeAPIClient.shared.baseRequestBody(productId: heliumProductKey)
        body["paymentMethodId"] = paymentMethod.id

        let response: ExecutePurchaseResponse = try await HeliumStripeAPIClient.shared.post("stripe/execute-purchase", body: body)
        return response.toPaymentSuccessResponse()
    }


    private func formatName(from nameComponents: PersonNameComponents?) -> String {
        [nameComponents?.givenName, nameComponents?.familyName]
            .compactMap { $0 }
            .joined(separator: " ")
    }
}

// MARK: - Response Types (Apple Pay specific)

private struct SetupIntentResponse: Decodable {
    let clientSecret: String?
    let setupIntentId: String?
    let stripeCustomerId: String?
    let metadata: [String: String]?
}


// MARK: - Helpers

/// Days per offer period unit. month/year are nominal (30/365) until the offer model carries exact days.
private func trialDaysPerUnit(_ periodUnit: String) -> Int {
    switch periodUnit.lowercased() {
    case "day": return 1
    case "week": return 7
    case "month": return 30
    case "year": return 365
    default: return 1
    }
}

/// Total intro/trial length in days. Used for sheet wording so trials read as "30 days" rather than "1 month".
private func trialDays(_ offer: SubscriptionOffer) -> Int {
    offer.periodValue * offer.periodCount * trialDaysPerUnit(offer.periodUnit)
}

private func formatDayDuration(_ days: Int) -> String {
    days == 1 ? "1 day" : "\(days) days"
}

/// Converts a price to the smallest currency unit (e.g. 0.99 USD → 99), using the currency's fraction digits.
private func smallestCurrencyUnit(_ amount: Decimal, currency: String?) -> Int {
    var scaled = Decimal()
    var value = amount
    NSDecimalMultiplyByPowerOf10(&scaled, &value, Int16(currencyFractionDigits(currency)), .plain)
    return NSDecimalNumber(decimal: scaled).intValue
}

private func currencyFractionDigits(_ currency: String?) -> Int {
    guard let currency else { return 2 }
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = currency
    return formatter.maximumFractionDigits
}

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


private func formatIntroOfferLabel(_ offer: SubscriptionOffer) -> String {
    let days = trialDays(offer)
    if offer.paymentMode == OfferPaymentMode.freeTrial {
        return "\(days)-day Free Trial"
    }
    return "\(offer.displayPrice) for \(formatDayDuration(days))"
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
    let days = trialDays(offer)

    if offer.paymentMode == OfferPaymentMode.freeTrial {
        return "You will be charged \(regularPrice)/\(period) after your \(days)-day free trial ends. Cancel anytime."
    }
    return "You will be charged \(offer.displayPrice) for the first \(formatDayDuration(days)), then \(regularPrice)/\(period). Cancel anytime."
}
