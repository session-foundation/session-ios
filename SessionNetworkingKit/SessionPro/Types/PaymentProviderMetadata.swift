// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtil
import SessionUtilitiesKit

public extension Network.SessionPro {
    struct PaymentProviderMetadata: Equatable {
        let device: String
        let store: String
        let platform: String
        let platformAccount: String
        let refundUrl: String
        
        /// Some platforms disallow a refund via their native support channels after some time period
        /// (e.g. 48 hours after a purchase on Google, refunds must be dealt by the developers
        /// themselves). If a platform does not have this restriction, this URL is typically the same as
        /// the `refund_url`.
        let refundAfterPlatformDeadlineUrl: String
        
        let refundSupportUrl: String
        let updateSubscriptionUrl: String
        let cancelSubscriptionUrl: String
        
        init?(_ pointer: UnsafePointer<session_pro_backend_payment_provider_metadata>?) {
            guard let libSessionValue: session_pro_backend_payment_provider_metadata = pointer?.pointee else {
                return nil
            }
            
            device = libSessionValue.get(\.device)
            store = libSessionValue.get(\.store)
            platform = libSessionValue.get(\.platform)
            platformAccount = libSessionValue.get(\.platform_account)
            refundUrl = libSessionValue.get(\.refund_url)
            refundAfterPlatformDeadlineUrl = libSessionValue.get(\.refund_after_platform_deadline_url)
            refundSupportUrl = libSessionValue.get(\.refund_support_url)
            updateSubscriptionUrl = libSessionValue.get(\.update_subscription_url)
            cancelSubscriptionUrl = libSessionValue.get(\.cancel_subscription_url)
        }
    }
}

extension session_pro_backend_payment_provider_metadata: @retroactive CAccessible {}
