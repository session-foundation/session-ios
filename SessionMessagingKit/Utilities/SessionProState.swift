// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SessionUIKit
import SessionUtilitiesKit
import Combine

// MARK: - Singleton

public extension Singleton {
    static let sessionProState: SingletonConfig<SessionProManagerType & ProfilePictureAnimationManagerType & SessionProCTAManagerType> = Dependencies.create(
        identifier: "sessionProState",
        createInstance: { dependencies in SessionProState(using: dependencies) }
    )
}

// MARK: - SessionProState

public class SessionProState: SessionProManagerType, ProfilePictureAnimationManagerType, SessionProCTAManagerType {
    public let dependencies: Dependencies
    public var sessionProStateSubject: CurrentValueSubject<SessionProPlanState, Never>
    public var sessionProStatePublisher: AnyPublisher<SessionProPlanState, Never> {
        sessionProStateSubject
            .compactMap { $0 }
            .eraseToAnyPublisher()
    }
    public var sessionProPlans: [SessionProPlan]
    
    public var shouldAnimateImageSubject: CurrentValueSubject<Bool, Never>
    public var shouldAnimateImagePublisher: AnyPublisher<Bool, Never> {
        shouldAnimateImageSubject
            .filter { $0 }
            .eraseToAnyPublisher()
    }
    
    public init(using dependencies: Dependencies) {
        self.dependencies = dependencies
        self.sessionProStateSubject = CurrentValueSubject(
            dependencies[cache: .libSession].isSessionPro ?
                SessionProPlanState.active(
                    currentPlan: SessionProPlan(
                        variant: .threeMonths,
                        price: SessionProPlan.Variant.threeMonths.price,
                        discountPercent: SessionProPlan.Variant.threeMonths.discountPercent
                    ),
                    expiredOn: Calendar.current.date(byAdding: .month, value: 1, to: Date())!,
                    isAutoRenewing: true,
                    originatingPlatform: .Android
                ) :
                SessionProPlanState.none
        )
        self.sessionProPlans = SessionProPlan.Variant.allCases.map {
            SessionProPlan(
                variant: $0,
                price: $0.price,
                discountPercent: $0.discountPercent
            )
        }
        self.shouldAnimateImageSubject = CurrentValueSubject(
            dependencies[cache: .libSession].isSessionPro
        )
    }
    
    public func upgradeToPro(completion: ((_ result: Bool) -> Void)?) {
        dependencies.set(feature: .mockCurrentUserSessionProState, to: .active)
        self.sessionProStateSubject.send(
            SessionProPlanState.active(
                currentPlan: SessionProPlan(
                    variant: .threeMonths,
                    price: SessionProPlan.Variant.threeMonths.price,
                    discountPercent: SessionProPlan.Variant.threeMonths.discountPercent
                ),
                expiredOn: Calendar.current.date(byAdding: .month, value: 1, to: Date())!,
                isAutoRenewing: true,
                originatingPlatform: .iOS
            )
        )
        self.shouldAnimateImageSubject.send(true)
        completion?(true)
    }
    
    public func cancelPro(completion: ((_ result: Bool) -> Void)?) {
        dependencies.set(feature: .mockCurrentUserSessionProState, to: SessionProStateMock.none)
        self.sessionProStateSubject.send(.none)
        self.shouldAnimateImageSubject.send(false)
        completion?(true)
    }
    
    public func requestRefund(completion: ((_ result: Bool) -> Void)?) {
        dependencies.set(feature: .mockCurrentUserSessionProState, to: .refunding)
        self.sessionProStateSubject.send(
            SessionProPlanState.refunding(
                originatingPlatform: .iOS,
                requestedAt: Date()
            )
        )
        self.shouldAnimateImageSubject.send(true)
        completion?(true)
    }
    
    public func expirePro(completion: ((_ result: Bool) -> Void)?) {
        dependencies.set(feature: .mockCurrentUserSessionProState, to: .expired)
        self.sessionProStateSubject.send(.expired)
        self.shouldAnimateImageSubject.send(false)
        completion?(true)
    }
    
    @discardableResult @MainActor public func showSessionProCTAIfNeeded(
        _ variant: ProCTAModal.Variant,
        dismissType: Modal.DismissType,
        beforePresented: (() -> Void)?,
        afterClosed: (() -> Void)?,
        presenting: ((UIViewController) -> Void)?
    ) -> Bool {
        guard dependencies[feature: .sessionProEnabled], case .active = sessionProStateSubject.value else {
            return false
        }
        beforePresented?()
        let sessionProModal: ModalHostingViewController = ModalHostingViewController(
            modal: ProCTAModal(
                variant: variant,
                dataManager: dependencies[singleton: .imageDataManager],
                dismissType: dismissType,
                afterClosed: afterClosed
            )
        )
        presenting?(sessionProModal)
        
        return true
    }
}
