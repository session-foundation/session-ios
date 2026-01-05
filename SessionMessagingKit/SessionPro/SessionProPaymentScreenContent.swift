// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SwiftUI
import SessionUIKit
import SessionUtilitiesKit

extension SessionProPaymentScreenContent {
    public class ViewModel: ViewModelType {
        public var dataModel: DataModel
        public var dateNow: Date { dependencies.dateNow }
        public var isRefreshing: Bool = false
        public var errorString: String?
        public var isFromBottomSheet: Bool
        
        private var dependencies: Dependencies
        
        public init(dataModel: DataModel, isFromBottomSheet: Bool, using dependencies: Dependencies) {
            self.dependencies = dependencies
            self.dataModel = dataModel
            self.isFromBottomSheet = isFromBottomSheet
        }
        
        @MainActor public func purchase(planInfo: SessionProPlanInfo) async throws {
            try await Task.detached(priority: .userInitiated) { [dependencies] in
                try await dependencies[singleton: .sessionProManager].purchasePro(
                    productId: planInfo.id
                )
            }.value
        }
        
        @MainActor public func cancelPro(scene: UIWindowScene?) async throws {
            guard let scene else {
                Log.error(.sessionPro, "Failed to being refund request: Unable to get UIWindowScene")
                throw SessionProError.windowSceneRequired
            }
            
            try await dependencies[singleton: .sessionProManager].cancelPro(scene: scene)
        }
        
        @MainActor public func requestRefund(scene: UIWindowScene?) async throws {
            guard let scene else {
                Log.error(.sessionPro, "Failed to being refund request: Unable to get UIWindowScene")
                throw SessionProError.windowSceneRequired
            }
            
            try await dependencies[singleton: .sessionProManager].requestRefund(scene: scene)
        }
    }
}
