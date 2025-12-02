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
        
        private var dependencies: Dependencies
        
        init(dataModel: DataModel, dependencies: Dependencies) {
            self.dependencies = dependencies
            self.dataModel = dataModel
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
                    success?()
                }
                catch {
                    failure?()
                }
            }
        }
        
        @MainActor public func cancelPro(
            success: (@MainActor () -> Void)?,
            failure: (@MainActor () -> Void)?
        ) {
            // TODO: [PRO] Need to add this in
//            dependencies[singleton: .sessionProState].cancelPro { result in
//                if result {
//                    success?()
//                } else {
//                    failure?()
//                }
//            }
        }
        
        @MainActor public func requestRefund(
            success: (@MainActor () -> Void)?,
            failure: (@MainActor () -> Void)?
        ) {
            guard let scene: UIWindowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene else {
                return Log.error(.sessionPro, "Failed to being refund request: Unable to get UIWindowScene")
            }
            
            Task(priority: .userInitiated) {
                do {
                    try await dependencies[singleton: .sessionProManager].requestRefund(scene: scene)
                    success?()
                }
                catch {
                    failure?()
                }
            }
        }
        
        public func openURL(_ url: URL) {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
    }
}
