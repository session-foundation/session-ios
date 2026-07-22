// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public enum BuildVariant: Sendable, Equatable, CaseIterable, CustomStringConvertible, CustomDebugStringConvertible {
    case appStore
    case development
    case testFlight
    case ipa
    
    /// Non-iOS variants (may be used for copy)
    case apk
    case fDroid
    case huawei
    
    // stringlint:ignore_contents
    public static var current: BuildVariant {
#if DEBUG || targetEnvironment(simulator)
        return .development
#else
    
        let hasProvisioningProfile: Bool = (Bundle.main.path(forResource: "embedded", ofType: "mobileprovision") != nil)
        let receiptUrl: URL? = Bundle.main.appStoreReceiptURL
        let hasSandboxReceipt: Bool = (receiptUrl?.lastPathComponent == "sandboxReceipt")
        
        if !hasProvisioningProfile {
            return .appStore
        }
        
        if hasSandboxReceipt {
            return .testFlight
        }
        
        return .ipa
#endif
    }
    
    public var description: String {
        switch self {
            case .appStore: return SNUIKit.buildVariantStringProvider().appStore
            case .development: return SNUIKit.buildVariantStringProvider().development
            case .testFlight: return SNUIKit.buildVariantStringProvider().testFlight
            case .ipa: return SNUIKit.buildVariantStringProvider().ipa

            case .apk: return SNUIKit.buildVariantStringProvider().apk
            case .fDroid: return SNUIKit.buildVariantStringProvider().fDroid
            case .huawei: return SNUIKit.buildVariantStringProvider().huawei
        }
    }

    /// A stable, non-localised identifier. `description` resolves *localized* display strings via
    /// `buildVariantStringProvider()`, which acquires the SNUIKit config lock and can be re-entered from
    /// low-level feature bookkeeping (`MockableFeatureValue.rawValue` uses `String(reflecting:)`) —
    /// resolving localization there deadlocks. Providing `debugDescription` makes `String(reflecting:)`
    /// use these plain names instead of `description`.
    public var debugDescription: String {
        switch self {                          // stringlint:ignore_contents
            case .appStore: return "appStore"
            case .development: return "development"
            case .testFlight: return "testFlight"
            case .ipa: return "ipa"
            case .apk: return "apk"
            case .fDroid: return "fDroid"
            case .huawei: return "huawei"
        }
    }
    
    public var billingAccess: Bool {
        switch self {
            case .appStore, .testFlight: return true
            case .ipa, .development, .apk, .fDroid, .huawei: return false
        }
    }
}
