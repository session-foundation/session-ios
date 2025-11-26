// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public enum SessionProUI {}

// MARK: - String Providers

public extension SessionProUI {
    protocol UrlStringProvider {
        var roadmap: String { get }
        var privacyPolicy: String { get }
        var termsOfService: String { get }
        var proAccessNotFound: String { get }
        var support: String { get }
    }
    
    protocol ClientPlatformStringProvider {
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
internal extension SessionProUI {
    /// This type should not be used where possible as it's values aren't maintained (proper values are sourced from `libSession`)
    struct FallbackUrlStringProvider: UrlStringProvider {
        let roadmap: String = "https://getsession.org/pro-roadmap"
        let privacyPolicy: String = "https://getsession.org/pro/privacy"
        let termsOfService: String = "https://getsession.org/pro/terms"
        let proAccessNotFound: String = "https://sessionapp.zendesk.com/hc/sections/4416517450649-Support"
        let support: String = "https://getsession.org/pro-form"
    }
    
    /// This type should not be used where possible as it's values aren't maintained (proper values are sourced from `libSession`)
    struct FallbackClientPlatformStringProvider: ClientPlatformStringProvider {
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

// MARK: - ClientPlatform

public extension SessionProUI {
    enum ClientPlatform: Sendable, Equatable, CaseIterable {
        case iOS
        case android
        
        public var device: String { SNUIKit.proClientPlatformStringProvider(for: self).device }
        public var store: String { SNUIKit.proClientPlatformStringProvider(for: self).store }
        public var platform: String { SNUIKit.proClientPlatformStringProvider(for: self).platform }
        public var platformAccount: String { SNUIKit.proClientPlatformStringProvider(for: self).platformAccount }
    }
}
