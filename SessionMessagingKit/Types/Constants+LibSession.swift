// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUIKit
import SessionUtil
import SessionUtilitiesKit

public extension Constants {
    static let urls: GeneralUrls = GeneralUrls(SESSION_PROTOCOL_STRINGS)
    static let buildVariants: BuildVariants = BuildVariants(SESSION_PROTOCOL_STRINGS)
    
    enum PaymentProvider {
        private static let metadata: [session_pro_backend_payment_provider_metadata] = [
            SESSION_PRO_BACKEND_PAYMENT_PROVIDER_METADATA.0,    /// Empty
            SESSION_PRO_BACKEND_PAYMENT_PROVIDER_METADATA.1,    /// Google
            SESSION_PRO_BACKEND_PAYMENT_PROVIDER_METADATA.2     /// Apple
        ]
        
        public static let appStore: Info = Info(metadata[Int(SESSION_PRO_BACKEND_PAYMENT_PROVIDER_IOS_APP_STORE.rawValue)])
        public static let playStore: Info = Info(metadata[Int(SESSION_PRO_BACKEND_PAYMENT_PROVIDER_GOOGLE_PLAY_STORE.rawValue)])
    }
}

public extension Constants {
    struct GeneralUrls: StringProvider.Url {
        public let donations: String
        public let donationsApp: String
        public let download: String
        public let faq: String
        public let feedback: String
        public let network: String
        public let privacyPolicy: String
        public let proAccessNotFound: String
        public let proFaq: String
        public let proPrivacyPolicy: String
        public let proRoadmap: String
        public let proSupport: String
        public let proTermsOfService: String
        public let staking: String
        public let support: String
        public let survey: String
        public let termsOfService: String
        public let token: String
        public let translate: String
        
        fileprivate init(_ libSessionValue: session_protocol_strings) {
            self.donations = libSessionValue.get(\.url_donations)
            self.donationsApp = libSessionValue.get(\.url_donations_app)
            self.download = libSessionValue.get(\.url_download)
            self.faq = libSessionValue.get(\.url_faq)
            self.feedback = libSessionValue.get(\.url_feedback)
            self.network = libSessionValue.get(\.url_network)
            self.privacyPolicy = libSessionValue.get(\.url_privacy_policy)
            self.proAccessNotFound = libSessionValue.get(\.url_pro_access_not_found)
            self.proFaq = libSessionValue.get(\.url_pro_faq)
            self.proPrivacyPolicy = libSessionValue.get(\.url_pro_privacy_policy)
            self.proRoadmap = libSessionValue.get(\.url_pro_roadmap)
            self.proSupport = libSessionValue.get(\.url_pro_support)
            self.proTermsOfService = libSessionValue.get(\.url_pro_terms_of_service)
            self.staking = libSessionValue.get(\.url_staking)
            self.support = libSessionValue.get(\.url_support)
            self.survey = libSessionValue.get(\.url_survey)
            self.termsOfService = libSessionValue.get(\.url_terms_of_service)
            self.token = libSessionValue.get(\.url_token)
            self.translate = libSessionValue.get(\.url_translate)
        }
    }
    
    struct BuildVariants: StringProvider.BuildVariant {
        public let apk: String
        public let fDroid: String
        public let huawei: String
        public let ipa: String
        
        fileprivate init(_ libSessionValue: session_protocol_strings) {
            self.apk = libSessionValue.get(\.build_variant_apk)
            self.fDroid = libSessionValue.get(\.build_variant_fdroid)
            self.huawei = libSessionValue.get(\.build_variant_huawei)
            self.ipa = libSessionValue.get(\.build_variant_ipa)
        }
    }
}

public extension Constants.PaymentProvider {
    struct Info: StringProvider.ClientPlatform {
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

extension session_protocol_strings: @retroactive CAccessible {}
extension session_pro_backend_payment_provider_metadata: @retroactive CAccessible {}
