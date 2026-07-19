// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUIKit
import SessionUtil
import SessionUtilitiesKit

public extension Constants {
    static let urls: GeneralUrls = GeneralUrls(SESSION_PROTOCOL_STRINGS)
    static let buildVariants: BuildVariants = BuildVariants(SESSION_PROTOCOL_STRINGS, PaymentProvider.appStore)
    
    enum PaymentProvider {
        /// libsession no longer ships provider display metadata — only the per-provider support/management
        /// URLs (identical for every user), which we read from `session_pro_backend_get_provider_urls`. The
        /// human-readable provider/store NAMES are translation data owned by the client.
        ///
        /// TODO: [PRO] route the display names through Crowdin (deferred display/i18n work); the English
        /// placeholders below keep the app building in the meantime. The provider-code slugs mirror
        /// `Network.SessionPro.PaymentProvider.code` (kept as literals to avoid a module dependency here).
        public static let appStore: Info = Info(
            device: "iOS",                          // stringlint:ignore
            store: "Apple App Store",               // stringlint:ignore
            platform: "Apple",                      // stringlint:ignore
            platformAccount: "Apple Account",       // stringlint:ignore
            urls: session_pro_backend_get_provider_urls("app_store")     // stringlint:ignore
        )
        public static let playStore: Info = Info(
            device: "Android",                      // stringlint:ignore
            store: "Google Play",                   // stringlint:ignore
            platform: "Google",                     // stringlint:ignore
            platformAccount: "Google Account",      // stringlint:ignore
            urls: session_pro_backend_get_provider_urls("google_play")   // stringlint:ignore
        )
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
        public var appStore: String
        public var development: String
        public let fDroid: String
        public let huawei: String
        public let ipa: String
        public var testFlight: String
        
        fileprivate init(_ libSessionValue: session_protocol_strings, _ iOSPaymentProvider: PaymentProvider.Info) {
            self.apk = libSessionValue.get(\.build_variant_apk)
            self.appStore = iOSPaymentProvider.store
            self.development = "Development"    // stringlint:ignore
            self.fDroid = libSessionValue.get(\.build_variant_fdroid)
            self.huawei = libSessionValue.get(\.build_variant_huawei)
            self.ipa = libSessionValue.get(\.build_variant_ipa)
            self.testFlight = "TestFlight"    // stringlint:ignore
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
        
        fileprivate init(
            device: String,
            store: String,
            platform: String,
            platformAccount: String,
            urls: session_pro_backend_provider_urls
        ) {
            self.device = device
            self.store = store
            self.platform = platform
            self.platformAccount = platformAccount

            /// The `provider_urls` fields are static, null-terminated C strings (NULL when not applicable)
            func string(_ pointer: UnsafePointer<CChar>?) -> String { pointer.map { String(cString: $0) } ?? "" }
            self.refundPlatformUrl = string(urls.refund_platform_url)
            self.refundSupportUrl = string(urls.refund_support_url)
            self.refundStatusUrl = string(urls.refund_status_url)
            self.updateSubscriptionUrl = string(urls.update_subscription_url)
            self.cancelSubscriptionUrl = string(urls.cancel_subscription_url)
        }
    }
}

extension session_protocol_strings: @retroactive CAccessible {}
