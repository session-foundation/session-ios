// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public enum StringProvider {}

// MARK: - String Providers

public extension StringProvider {
    protocol Url {
        var proRoadmap: String { get }
        var proPrivacyPolicy: String { get }
        var proTermsOfService: String { get }
        var proAccessNotFound: String { get }
        var support: String { get }
        var network: String { get }
        var staking: String { get }
        var token: String { get }
        var donations: String { get }
        var donationsApp: String { get }
        var feedback: String { get }
    }
    
    protocol BuildVariant {
        var apk: String { get }
        var fDroid: String { get }
        var huawei: String { get }
        var ipa: String { get }
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
        let proRoadmap: String = "https://getsession.org/pro-roadmap"
        let proPrivacyPolicy: String = "https://getsession.org/pro/privacy"
        let proTermsOfService: String = "https://getsession.org/pro/terms"
        let proAccessNotFound: String = "https://sessionapp.zendesk.com/hc/sections/4416517450649-Support"
        let support: String = "https://getsession.org/pro-form"
        let network: String = "https://docs.getsession.org/session-network"
        let staking: String = "https://docs.getsession.org/session-network/staking"
        let token: String = "https://token.getsession.org"
        let donations: String = "https://getsession.org/donate"
        let donationsApp: String = "https://getsession.org/donate#app"
        let feedback: String = "https://getsession.org/feedback"
    }
    
    /// This type should not be used where possible as it's values aren't maintained (proper values are sourced from `libSession`)
    struct FallbackBuildVariantStringProvider: StringProvider.BuildVariant {
        let apk: String = "APK"
        let fDroid: String = "F-Droid Store"
        let huawei: String = "Huawei App Gallery"
        let ipa: String = "IPA"
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
