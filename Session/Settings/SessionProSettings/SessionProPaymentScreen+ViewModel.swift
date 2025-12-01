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
        
        private var dependencies: Dependencies
        
        init(dataModel: DataModel, dependencies: Dependencies) {
            self.dependencies = dependencies
            self.dataModel = dataModel
        }
        
        public func purchase(planInfo: SessionProPlanInfo, success: (() -> Void)?, failure: (() -> Void)?) {
            let plan: SessionProPlan = SessionProPlan.from(planInfo)
            dependencies[singleton: .sessionProState].upgradeToPro(
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
        
        public func cancelPro(success: (() -> Void)?, failure: (() -> Void)?) {
            dependencies[singleton: .sessionProState].cancelPro { result in
                if result {
                    success?()
                } else {
                    failure?()
                }
            }
        }
        
        public func requestRefund(success: (() -> Void)?, failure: (() -> Void)?) {
            dependencies[singleton: .sessionProState].requestRefund { result in
                if result {
                    success?()
                } else {
                    failure?()
                }
            }
        }
        
        public func openURL(_ url: URL) {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
    }
}
