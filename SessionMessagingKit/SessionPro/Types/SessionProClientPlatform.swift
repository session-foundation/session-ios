// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

// TODO: [PRO] Move these strings

public extension SessionPro {
    enum ClientPlatform: Sendable, CaseIterable, Equatable, CustomStringConvertible {
        case iOS
        case android
        
        public var store: String {
            switch self {
                case .iOS: return "Apple App"
                case .android: return "Google Play"
            }
        }
        
        public var account: String {
            switch self {
                case .iOS: return "Apple Account"
                case .android: return "Google Account"
            }
        }
        
        public var deviceType: String {
            switch self {
                case .iOS: return "iOS"
                case .android: return "Android"
            }
        }
        
        public var name: String {
            switch self {
                case .iOS: return "Apple"
                case .android: return "Google"
            }
        }
        
        public var description: String {
            switch self {
                case .iOS: return "iOS"
                case .android: return "Android"
            }
        }
    }
}

// MARK: - MockableFeature

public extension FeatureStorage {
    static let mockProOriginatingPlatform: FeatureConfig<MockableFeature<SessionPro.ClientPlatform>> = Dependencies.create(
        identifier: "mockProOriginatingPlatform"
    )
}

extension SessionPro.ClientPlatform: MockableFeatureValue {
    public var title: String { "\(self)" }
    
    public var subtitle: String {
        switch self {
            case .iOS: return "The Session Pro subscription was originally purchased on an iOS device."
            case .android: return "The Session Pro subscription was originally purchased on an Android device."
        }
    }
}
