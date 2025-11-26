// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUIKit
import SessionUtil
import SessionUtilitiesKit

public extension SessionPro {
    enum Metadata {
        private static let providerMetadata: [session_pro_backend_payment_provider_metadata] = [
            SESSION_PRO_BACKEND_PAYMENT_PROVIDER_METADATA.0,    /// Empty
            SESSION_PRO_BACKEND_PAYMENT_PROVIDER_METADATA.1,    /// Google
            SESSION_PRO_BACKEND_PAYMENT_PROVIDER_METADATA.2     /// Apple
        ]
        
        public static let urls: GeneralUrls = GeneralUrls(SESSION_PRO_URLS)
        public static let appStore: PaymentProvider = PaymentProvider(providerMetadata[Int(SESSION_PRO_BACKEND_PAYMENT_PROVIDER_IOS_APP_STORE.rawValue)])
        public static let playStore: PaymentProvider = PaymentProvider(providerMetadata[Int(SESSION_PRO_BACKEND_PAYMENT_PROVIDER_GOOGLE_PLAY_STORE.rawValue)])
    }
}

public extension SessionPro.Metadata {
    struct GeneralUrls: SessionProUI.UrlStringProvider {
        public let roadmap: String
        public let privacyPolicy: String
        public let termsOfService: String
        public let proAccessNotFound: String
        public let support: String
        
        fileprivate init(_ libSessionValue: session_pro_urls) {
            self.roadmap = libSessionValue.get(\.roadmap)
            self.privacyPolicy = libSessionValue.get(\.privacy_policy)
            self.termsOfService = libSessionValue.get(\.terms_of_service)
            self.proAccessNotFound = libSessionValue.get(\.pro_access_not_found)
            self.support = libSessionValue.get(\.support_url)
        }
    }
    
    struct PaymentProvider: SessionProUI.ClientPlatformStringProvider {
        public let device: String
        public let store: String
        public let platform: String
        public let platformAccount: String
        public let refundPlatformUrl: String

        /// Some platforms disallow a refund via their native support channels after some time period
        /// (e.g. 48 hours after a purchase on Google, refunds must be dealt by the developers
        /// themselves). If a platform does not have this restriction, this URL is typically the same as
        /// the `refund_platform_url`.
        public let refundSupportUrl: String

        public let refundStatusUrl: String
        public let updateSubscriptionUrl: String
        public let cancelSubscriptionUrl: String
        
        fileprivate init(_ libSessionValue: session_pro_backend_payment_provider_metadata) {
            self.device = libSessionValue.get(\.device)
            self.store = libSessionValue.get(\.store)
            self.platform = libSessionValue.get(\.platform)
            self.platformAccount = libSessionValue.get(\.platform_account)
            self.refundPlatformUrl = libSessionValue.get(\.refund_platform_url)
            
            self.refundSupportUrl = libSessionValue.get(\.refund_support_url)
            
            self.refundStatusUrl = libSessionValue.get(\.refund_status_url)
            self.updateSubscriptionUrl = libSessionValue.get(\.update_subscription_url)
            self.cancelSubscriptionUrl = libSessionValue.get(\.cancel_subscription_url)
        }
    }
}

extension session_pro_urls: @retroactive CAccessible {}
extension session_pro_backend_payment_provider_metadata: @retroactive CAccessible {}
