// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionUtilitiesKit

public extension SessionPro {
    enum LoadingState: Sendable, CaseIterable, Equatable, CustomStringConvertible {
        case loading
        case error
        case success
        
        public var description: String {
            switch self {
                case .loading: return "Loading"
                case .error: return "Error"
                case .success: return "Success"
            }
        }
    }
}

// MARK: - MockableFeature

public extension FeatureStorage {
    static let mockCurrentUserSessionProLoadingState: FeatureConfig<MockableFeature<SessionPro.LoadingState>> = Dependencies.create(
        identifier: "mockCurrentUserSessionProLoadingState"
    )
}

extension SessionPro.LoadingState: MockableFeatureValue {
    public var title: String { "\(self)" }
    
    public var subtitle: String {
        switch self {
            case .loading: return "The UI state while we are waiting on the network response."
            case .error: return "The UI state when there was an error retrieving the users Pro status."
            case .success: return "The UI state once we have successfully retrieved the users Pro status."
        }
    }
}
