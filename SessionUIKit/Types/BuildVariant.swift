// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public enum BuildVariant: Sendable, Equatable, CaseIterable, CustomStringConvertible {
    case appStore
    case development
    case testFlight
    case ipa
    
    /// Non-iOS variants (may be used for copy)
    case apk
    case fDroid
    case huawei
    
    public static var current: BuildVariant {
#if DEBUG
        return .development
#else
    
        let hasProvisioningProfile: Bool = (Bundle.main.path(forResource: "embedded", ofType: "mobileprovision") != nil)
        let receiptUrl: URL? = Bundle.main.appStoreReceiptURL
        let hasSandboxReceipt: Bool = (receiptURL?.lastPathComponent == "sandboxReceipt")
        
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
}
