import Helium

open class StripeOneTapPurchaseDelegate: HeliumPaywallDelegate, HeliumDelegateReturnsTransaction {
    
    public var delegateType: String { "stripe_one_tap" }
    
    open func makePurchase(productId: String) async -> HeliumPaywallTransactionStatus {
        // todo
        return .cancelled
    }
    
    open func restorePurchases() async -> Bool {
        // todo
        return true
    }
    
    open func getLatestCompletedTransactionIdResult() -> HeliumTransactionIdResult? {
        // todo
        return nil
    }
    
}
