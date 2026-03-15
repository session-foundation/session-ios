// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SwiftUI
import SessionUIKit
import SessionUtilitiesKit

extension SessionProPaymentScreenContent {
    public class ViewModel: ObservableObject, ViewModelType {
        @Published public var dataModel: DataModel
        public var dateNow: Date { dependencies.dateNow }
        public var errorString: String?
        public var isFromBottomSheet: Bool
        
        private var dependencies: Dependencies
        
        public init(dataModel: DataModel, isFromBottomSheet: Bool, using dependencies: Dependencies) {
            self.dependencies = dependencies
            self.dataModel = dataModel
            self.isFromBottomSheet = isFromBottomSheet
        }
        
        @MainActor public func purchase(planInfo: SessionProPlanInfo) async throws -> PaymentStatus {
            do {
                try await Task.detached(priority: .userInitiated) { [dependencies] in
                    try await dependencies[singleton: .sessionProManager].purchasePro(
                        productId: planInfo.id
                    )
                }.value
                
                if case .purchase = dataModel.flow {
                    let profile: Profile = dependencies.mutate(cache: .libSession) { $0.profile }
                    var proFeatures: SessionPro.ProfileFeatures = profile.proFeatures.inserting(.proBadge)
                    
                    if
                        let explicitPath: String = try? dependencies[singleton: .displayPictureManager].path(for: profile.displayPictureUrl),
                        let explicitURL: URL = URL(string: explicitPath),
                        let imageFrameBuffer: ImageDataManager.FrameBuffer = await dependencies[singleton: .imageDataManager].load(.url(explicitURL)),
                        imageFrameBuffer.frameCount > 1
                    {
                        proFeatures = proFeatures.inserting(.animatedAvatar)
                    }
                    
                    
                    try await Profile.updateLocal(
                        proFeatures: proFeatures,
                        using: dependencies
                    )
                }
                
                guard !dependencies[feature: .fakeAppleSubscriptionForDev] else { return .dev }
                return .success(expirationTimestampMs: dependencies[singleton: .sessionProManager].currentUserCurrentProState.accessExpiryTimestampMs)
            } catch {
                switch error {
                    case SessionProError.purchasePending: return .pending
                    case SessionProError.purchaseCancelled: return .cancelled
                    default: throw error
                }
            }
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
            
            let updatedProState: SessionPro.State = dependencies[singleton: .sessionProManager].currentUserCurrentProState
            self.dataModel = DataModel(
                flow: .init(state: updatedProState),
                plans: updatedProState.plans.map { SessionProPlanInfo(plan: $0) }
            )
        }
        
        public func openURL(_ url: URL) {
            dependencies[singleton: .appContext].openUrl(url)
        }
    }
}
