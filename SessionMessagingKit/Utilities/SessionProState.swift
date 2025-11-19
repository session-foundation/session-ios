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
    public var sessionProPlans: [SessionProPlan] {
        dependencies[feature: .mockInstalledFromIPA] ? [] : SessionProPlan.Variant.allCases.map { SessionProPlan(variant: $0) }
    }
    
    public var shouldAnimateImageSubject: CurrentValueSubject<Bool, Never>
    public var shouldAnimateImagePublisher: AnyPublisher<Bool, Never> {
        shouldAnimateImageSubject
            .compactMap { $0 }
            .eraseToAnyPublisher()
    }
    
    public init(using dependencies: Dependencies) {
        self.dependencies = dependencies
        let originatingPlatform: ClientPlatform = dependencies[feature: .proPlanOriginatingPlatform]
        let expiryInSeconds = dependencies[feature: .mockCurrentUserSessionProExpiry].durationInSeconds ?? 3 * 30 * 24 * 60 * 60
        switch dependencies[feature: .mockCurrentUserSessionProState] {
            case .none:
                self.sessionProStateSubject = CurrentValueSubject(SessionProPlanState.none)
            case .active:
                self.sessionProStateSubject = CurrentValueSubject(
                        SessionProPlanState.active(
                            currentPlan: SessionProPlan(variant: .threeMonths),
                            expiredOn: Calendar.current.date(byAdding: .second, value: Int(expiryInSeconds), to: Date())!,
                            isAutoRenewing: true,
                            originatingPlatform: originatingPlatform
                        )
                )
            case .expiring:
                self.sessionProStateSubject = CurrentValueSubject(
                        SessionProPlanState.active(
                            currentPlan: SessionProPlan(variant: .threeMonths),
                            expiredOn: Calendar.current.date(byAdding: .second, value: Int(expiryInSeconds), to: Date())!,
                            isAutoRenewing: false,
                            originatingPlatform: originatingPlatform
                        )
                )
            case .expired:
                self.sessionProStateSubject = CurrentValueSubject(
                    SessionProPlanState.expired(
                        expiredOn: Date(),
                        originatingPlatform: originatingPlatform
                    )
                )
            case .refunding:
                self.sessionProStateSubject = CurrentValueSubject(
                    SessionProPlanState.refunding(
                        originatingPlatform: originatingPlatform,
                        requestedAt: Calendar.current.date(byAdding: .hour, value: -1, to: Date())!
                    )
                )
        }
        
        self.shouldAnimateImageSubject = CurrentValueSubject(
            dependencies[cache: .libSession].isSessionPro
        )
    }
    
    public func upgradeToPro(plan: SessionProPlan, originatingPlatform: ClientPlatform, completion: ((_ result: Bool) -> Void)?) {
        dependencies.set(feature: .mockCurrentUserSessionProState, to: .active)
        dependencies[defaults: .standard, key: .hasShownProExpiringCTA] = false
        dependencies[defaults: .standard, key: .hasShownProExpiredCTA] = false
        self.sessionProStateSubject.send(
            SessionProPlanState.active(
                currentPlan: plan,
                expiredOn: Calendar.current.date(byAdding: .month, value: plan.variant.duration, to: Date())!,
                isAutoRenewing: true,
                originatingPlatform: originatingPlatform
            )
        )
        self.shouldAnimateImageSubject.send(true)
        dependencies.setAsync(.isProBadgeEnabled, true)
        completion?(true)
    }
    
    public func cancelPro(completion: ((_ result: Bool) -> Void)?) {
        guard case .active(let currentPlan, let expiredOn, _, let originatingPlatform) = self.sessionProStateSubject.value else {
            return
        }
        dependencies.set(feature: .mockCurrentUserSessionProState, to: .expiring)
        self.sessionProStateSubject.send(
            SessionProPlanState.active(
                currentPlan: currentPlan,
                expiredOn: expiredOn,
                isAutoRenewing: false,
                originatingPlatform: originatingPlatform
            )
        )
        self.shouldAnimateImageSubject.send(true)
        completion?(true)
    }
    
    public func requestRefund(completion: ((_ result: Bool) -> Void)?) {
        dependencies.set(feature: .mockCurrentUserSessionProState, to: .refunding)
        self.sessionProStateSubject.send(
            SessionProPlanState.refunding(
                originatingPlatform: dependencies[feature: .proPlanOriginatingPlatform],
                requestedAt: Date()
            )
        )
        self.shouldAnimateImageSubject.send(true)
        completion?(true)
    }
    
    public func expirePro(completion: ((_ result: Bool) -> Void)?) {
        dependencies.set(feature: .mockCurrentUserSessionProState, to: .expired)
        self.sessionProStateSubject.send(
            SessionProPlanState.expired(
                expiredOn: Date(),
                originatingPlatform: dependencies[feature: .proPlanOriginatingPlatform]
            )
        )
        self.shouldAnimateImageSubject.send(false)
        completion?(true)
    }
    
    public func recoverPro(completion: ((_ result: Bool) -> Void)?) {
        guard dependencies[feature: .proPlanToRecover] == true && dependencies[feature: .mockCurrentUserSessionProLoadingState] == .success else {
            completion?(false)
            return
        }
        upgradeToPro(
            plan: SessionProPlan(variant: .threeMonths),
            originatingPlatform: dependencies[feature: .proPlanOriginatingPlatform],
            completion: completion
        )
    }
    
    @discardableResult @MainActor public func showSessionProCTAIfNeeded(
        _ variant: ProCTAModal.Variant,
        dismissType: Modal.DismissType,
        beforePresented: (() -> Void)?,
        afterClosed: (() -> Void)?,
        presenting: ((UIViewController) -> Void)?
    ) -> Bool {
        let shouldShowProCTA: Bool = {
            guard dependencies[feature: .sessionProEnabled] else { return false }
            switch variant {
                case .expiring, .groupLimit:
                    return true
                default:
                    switch sessionProStateSubject.value {
                        case .active, .refunding: return false
                        case .none, .expired: return true
                    }
            }
        }()
        
        guard shouldShowProCTA else {
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
    
    // These functions are only for QA purpose
    public func updateOriginatingPlatform(_ newValue: ClientPlatform) {
        self.sessionProStateSubject.send(
            self.sessionProStateSubject.value
                .with(originatingPlatform: newValue)
        )
    }
    
    public func updateProExpiry(_ expiryInSeconds: TimeInterval?) {
        guard case .active(let currentPlan, _, let isAutoRenewing, let originatingPlatform) = self.sessionProStateSubject.value else {
            return
        }
        let expiryInSeconds = expiryInSeconds ?? TimeInterval(currentPlan.variant.duration * 30 * 24 * 60 * 60)
        
        self.sessionProStateSubject.send(
            SessionProPlanState.active(
                currentPlan: currentPlan,
                expiredOn: Calendar.current.date(byAdding: .second, value: Int(expiryInSeconds), to: Date())!,
                isAutoRenewing: isAutoRenewing,
                originatingPlatform: originatingPlatform
            )
        )
    }
}
