#if canImport(StoreKit)
import Foundation
import RetentionEngine
import StoreKit

// The app sees a redeemed retention offer through StoreKit 2 before the server's notification
// arrives. Mapping it into the same `SubscriptionFact` vocabulary lets the app confirm the
// redemption immediately (refresh entitlements, thank the subscriber) and report it to the server,
// where the attribution join treats it exactly like the notification — including deduplicating
// the two, because classification depends only on which facts exist.

@available(iOS 17.2, macOS 14.2, *)
public extension SubscriptionFact {
    /// A fact for a promotional-offer redemption, or `nil` if the transaction is not one.
    /// Feed it from the app's existing `Transaction.updates` loop; this does not finish transactions.
    init?(transaction: Transaction) {
        guard let offer = transaction.offer, offer.type == .promotional, let offerId = offer.id else { return nil }
        self.init(
            notificationUUID: "storekit-transaction-\(transaction.id)",
            signedDate: Self.milliseconds(transaction.signedDate),
            originalTransactionId: String(transaction.originalID),
            productId: transaction.productID,
            kind: .offerRedeemed(offerId: offerId)
        )
    }
}

public extension SubscriptionFact {
    /// Facts from a renewal-info update: auto-renew state, and a pending plan switch if the next
    /// renewal is for a different product.
    static func facts(from renewalInfo: Product.SubscriptionInfo.RenewalInfo) -> [SubscriptionFact] {
        let signed = milliseconds(renewalInfo.signedDate)
        let original = String(renewalInfo.originalTransactionID)
        var facts = [SubscriptionFact(
            notificationUUID: "storekit-renewal-\(original)-\(signed)-\(renewalInfo.willAutoRenew ? "on" : "off")",
            signedDate: signed,
            originalTransactionId: original,
            productId: renewalInfo.currentProductID,
            kind: .autoRenewChanged(enabled: renewalInfo.willAutoRenew)
        )]
        if let next = renewalInfo.autoRenewPreference, next != renewalInfo.currentProductID {
            facts.append(SubscriptionFact(
                notificationUUID: "storekit-renewal-pref-\(original)-\(signed)-\(next)",
                signedDate: signed,
                originalTransactionId: original,
                productId: renewalInfo.currentProductID,
                kind: .renewalPreferenceChanged(productId: next)
            ))
        }
        return facts
    }

    static func milliseconds(_ date: Date) -> Int64 {
        Saturating.int64((date.timeIntervalSince1970 * 1_000).rounded())
    }
}
#endif
