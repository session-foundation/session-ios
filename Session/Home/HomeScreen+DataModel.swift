// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import DifferenceKit
import SignalUtilitiesKit
import SessionMessagingKit
import SessionUtilitiesKit

extension HomeScreen {
    public class DataModel {
        public typealias SectionModel = ArraySection<Section, SessionThreadViewModel>
        
        // MARK: - Section
        
        public enum Section: Differentiable {
            case messageRequests
            case threads
            case loadMore
        }
        
        // MARK: - Variables
        
        public static let pageSize: Int = (UIDevice.current.isIPad ? 20 : 15)
        
        public struct State: Equatable {
            let showViewedSeedBanner: Bool
            let hasHiddenMessageRequests: Bool
            let unreadMessageRequestThreadCount: Int
            let userProfile: Profile
        }
        
        public static func retrieveState(_ db: Database) throws -> State {
            let hasViewedSeed: Bool = db[.hasViewedSeed]
            let hasHiddenMessageRequests: Bool = db[.hasHiddenMessageRequests]
            let userProfile: Profile = Profile.fetchOrCreateCurrentUser(db)
            let unreadMessageRequestThreadCount: Int = try SessionThread
                .unreadMessageRequestsCountQuery(userPublicKey: userProfile.id)
                .fetchOne(db)
                .defaulting(to: 0)
            
            return State(
                showViewedSeedBanner: !hasViewedSeed,
                hasHiddenMessageRequests: hasHiddenMessageRequests,
                unreadMessageRequestThreadCount: unreadMessageRequestThreadCount,
                userProfile: userProfile
            )
        }
    }
}
