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
        
        @MainActor public func purchase(
            planInfo: SessionProPlanInfo,
            success: (@MainActor () -> Void)?,
            failure: (@MainActor () -> Void)?
        ) {
            Task(priority: .userInitiated) {
                do {
                    try await dependencies[singleton: .sessionProManager].purchasePro(
                        productId: planInfo.id
                    )
                    await MainActor.run {
                        success?()
                    }
                }
                catch {
                    await MainActor.run {
                        failure?()
                    }
                }
            }
        }
        
        @MainActor public func cancelPro(
            success: (@MainActor () -> Void)?,
            failure: (@MainActor () -> Void)?
        ) {
            do {
                guard let scene: UIWindowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene else {
                    failure?()
                    return Log.error(.sessionPro, "Failed to being refund request: Unable to get UIWindowScene")
                }
                
                try await dependencies[singleton: .sessionProManager].cancelPro(scene: scene)
                success?()
            }
            catch {
                failure?()
            }
        }
        
        @MainActor public func requestRefund(
            success: (@MainActor () -> Void)?,
            failure: (@MainActor () -> Void)?
        ) {
            guard let scene: UIWindowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene else {
                failure?()
                return Log.error(.sessionPro, "Failed to being refund request: Unable to get UIWindowScene")
            }
            
            do {
                try await dependencies[singleton: .sessionProManager].requestRefund(scene: scene)
                success?()
            }
            catch {
                failure?()
            }
        }
    }
}
