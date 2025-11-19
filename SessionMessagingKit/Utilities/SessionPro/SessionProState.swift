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

public class SessionProState: SessionProManagerType, ProfilePictureAnimationManagerType {
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
        // TODO: [PRO] Get the pro state of current user
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
    
    public func upgradeToPro(plan: SessionProPlan, originatingPlatform: ClientPlatform, completion: ((_ result: Bool) -> Void)?) async {
        // TODO: [PRO] Upgrade to Pro
        Task {
            try await Task.sleep(for: .seconds(5))
            dependencies[defaults: .standard, key: .hasShownProExpiringCTA] = false
            dependencies[defaults: .standard, key: .hasShownProExpiredCTA] = false
            dependencies.set(feature: .mockCurrentUserSessionProState, to: .active)
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
    }
    
    public func cancelPro(completion: ((_ result: Bool) -> Void)?) async {
        // TODO: [PRO] Cancel Pro: This is more like just cancel subscription
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
    
    public func requestRefund(completion: ((_ result: Bool) -> Void)?) async {
        // TODO: [PRO] Request refund
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
    
    public func expirePro(completion: ((_ result: Bool) -> Void)?) async {
        // TODO: [PRO] Mannualy expire pro state, maybe just for QA as we have backend to determine if pro is expired
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
    
    public func recoverPro(completion: ((_ result: Bool) -> Void)?) async {
        // TODO: [PRO] Recover from an existing pro plan
        guard dependencies[feature: .proPlanToRecover] == true && dependencies[feature: .mockCurrentUserSessionProLoadingState] == .success else {
            completion?(false)
            return
        }
        await upgradeToPro(
            plan: SessionProPlan(variant: .threeMonths),
            originatingPlatform: dependencies[feature: .proPlanOriginatingPlatform],
            completion: completion
        )
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

// MARK: - SessionProCTAManagerType

extension SessionProState: SessionProCTAManagerType {
    @discardableResult @MainActor public func showSessionProCTAIfNeeded(
        _ variant: ProCTAModal.Variant,
        dismissType: Modal.DismissType,
        beforePresented: (() -> Void)?,
        onConfirm: (() -> Void)?,
        onCancel: (() -> Void)?,
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
                afterClosed: afterClosed,
                onConfirm: onConfirm,
                onCancel: onCancel
            )
        )
        presenting?(sessionProModal)
        
        return true
    }
    
    @MainActor public func showSessionProBottomSheetIfNeeded(
        beforePresented: (() -> Void)?,
        afterClosed: (() -> Void)?,
        presenting: ((UIViewController) -> Void)?
    ) {
        let viewModel = SessionProBottomSheetViewModel(using: dependencies)
        let sessionProBottomSheet: BottomSheetHostingViewController = BottomSheetHostingViewController(
            bottomSheet: BottomSheet(
                hasCloseButton: true,
                afterClosed: afterClosed
            ) {
                SessionListScreen(viewModel: viewModel, scrollable: false)
            }
        )
        beforePresented?()
        presenting?(sessionProBottomSheet)
    }
}
