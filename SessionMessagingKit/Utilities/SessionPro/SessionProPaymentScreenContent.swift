// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SwiftUI
import SessionUIKit
import SessionUtilitiesKit

extension SessionProPaymentScreenContent {
    public class ViewModel: ViewModelType {
        public var dataModel: DataModel
        public var isRefreshing: Bool = false
        public var errorString: String?
        public var isFromBottomSheet: Bool
        
        private var dependencies: Dependencies
        
        public init(dependencies: Dependencies, dataModel: DataModel, isFromBottomSheet: Bool) {
            self.dependencies = dependencies
            self.dataModel = dataModel
            self.isFromBottomSheet = isFromBottomSheet
        }
        
        public func purchase(planInfo: SessionProPlanInfo, success: (() -> Void)?, failure: (() -> Void)?) async {
            let plan: SessionProPlan = SessionProPlan.from(planInfo)
            await dependencies[singleton: .sessionProState].upgradeToPro(
                plan: plan,
                originatingPlatform: .iOS
            ) { result in
                if result {
                    success?()
                } else {
                    failure?()
                }
            }
        }
        
        public func cancelPro(success: (() -> Void)?, failure: (() -> Void)?) async {
            await dependencies[singleton: .sessionProState].cancelPro { result in
                if result {
                    success?()
                } else {
                    failure?()
                }
            }
        }
    }
}
