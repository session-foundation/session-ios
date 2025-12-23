// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public enum StringProvider {}

// MARK: - String Providers

public extension StringProvider {
    protocol Url {
        var donations: String { get }
        var donationsApp: String { get }
        var download: String { get }
        var faq: String { get }
        var feedback: String { get }
        var network: String { get }
        var privacyPolicy: String { get }
        var proAccessNotFound: String { get }
        var proFaq: String { get }
        var proPrivacyPolicy: String { get }
        var proRoadmap: String { get }
        var proSupport: String { get }
        var proTermsOfService: String { get }
        var staking: String { get }
        var support: String { get }
        var survey: String { get }
        var termsOfService: String { get }
        var token: String { get }
        var translate: String { get }
    }
    
    protocol BuildVariant {
        var apk: String { get }
        var appStore: String { get }
        var development: String { get }
        var fDroid: String { get }
        var huawei: String { get }
        var ipa: String { get }
        var testFlight: String { get }
    }
    
    protocol ClientPlatform {
        var device: String { get }
        var store: String { get }
        var platform: String { get }
        var platformAccount: String { get }
        
        var refundPlatformUrl: String { get }
        var refundSupportUrl: String { get }
        var refundStatusUrl: String { get }
        var updateSubscriptionUrl: String { get }
        var cancelSubscriptionUrl: String { get }
    }
}

// MARK: - String Provider Fallbacks

// stringlint:ignore_contents
internal extension StringProvider {
    /// This type should not be used where possible as it's values aren't maintained (proper values are sourced from `libSession`)
    struct FallbackUrlStringProvider: StringProvider.Url {
        let donations: String = "https://getsession.org/donate"
        let donationsApp: String = "https://getsession.org/donate#app"
        let download: String = "https://getsession.org/download"
        let faq: String = "https://getsession.org/faq"
        let feedback: String = "https://getsession.org/feedback"
        let network: String = "https://docs.getsession.org/session-network"
        let privacyPolicy: String = "https://getsession.org/privacy-policy"
        let proAccessNotFound: String = "https://sessionapp.zendesk.com/hc/sections/4416517450649-Support"
        let proFaq: String = "https://getsession.org/faq#pro"
        let proPrivacyPolicy: String = "https://getsession.org/pro/privacy"
        let proRoadmap: String = "https://getsession.org/pro-roadmap"
        let proSupport: String = "https://getsession.org/pro-form"
        let proTermsOfService: String = "https://getsession.org/pro/terms"
        let staking: String = "https://docs.getsession.org/session-network/staking"
        let support: String = "https://getsession.org/support"
        let survey: String = "https://getsession.org/survey"
        let termsOfService: String = "https://getsession.org/terms-of-service"
        let token: String = "https://token.getsession.org"
        let translate: String = "https://getsession.org/translate"
    }
    
    /// This type should not be used where possible as it's values aren't maintained (proper values are sourced from `libSession`)
    struct FallbackBuildVariantStringProvider: StringProvider.BuildVariant {
        let apk: String = "APK"
        let appStore: String = "Apple App Store"
        let development: String = "Development"
        let fDroid: String = "F-Droid Store"
        let huawei: String = "Huawei App Gallery"
        let ipa: String = "IPA"
        let testFlight: String = "TestFlight"
    }
    
    /// This type should not be used where possible as it's values aren't maintained (proper values are sourced from `libSession`)
    struct FallbackClientPlatformStringProvider: StringProvider.ClientPlatform {
        let device: String = "iOS"
        let store: String = "Apple App Store"
        let platform: String = "Apple"
        let platformAccount: String = "Apple Account"
        
        let refundPlatformUrl: String = "https://support.apple.com/118223"
        let refundSupportUrl: String = "https://support.apple.com/118223"
        let refundStatusUrl: String = "https://support.apple.com/118224"
        let updateSubscriptionUrl: String = "https://apps.apple.com/account/subscriptions"
        let cancelSubscriptionUrl: String = "https://account.apple.com/account/manage/section/subscriptions"
    }
}
