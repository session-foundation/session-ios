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
            .filter { $0 }
            .eraseToAnyPublisher()
    }
    
    public init(using dependencies: Dependencies) {
        self.dependencies = dependencies
        let originatingPlatform: ClientPlatform = dependencies[feature: .proPlanOriginatingPlatform]
        switch dependencies[feature: .mockCurrentUserSessionProState] {
            case .none:
                self.sessionProStateSubject = CurrentValueSubject(SessionProPlanState.none)
            case .active:
                self.sessionProStateSubject = CurrentValueSubject(
                        SessionProPlanState.active(
                            currentPlan: SessionProPlan(variant: .threeMonths),
                            expiredOn: Calendar.current.date(byAdding: .month, value: 1, to: Date())!,
                            isAutoRenewing: true,
                            originatingPlatform: originatingPlatform
                        )
                )
            case .expired:
                self.sessionProStateSubject = CurrentValueSubject(
                    SessionProPlanState.expired(
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
        self.sessionProStateSubject.send(.none)
        self.shouldAnimateImageSubject.send(false)
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
    
    // This function is only for QA purpose
    public func updateOriginatingPlatform(_ newValue: ClientPlatform) {
        self.sessionProStateSubject.send(
            self.sessionProStateSubject.value
                .with(originatingPlatform: newValue)
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
        afterClosed: (() -> Void)?,
        presenting: ((UIViewController) -> Void)?
    ) -> Bool {
        guard dependencies[feature: .sessionProEnabled] else { return false }
        if case .active = sessionProStateSubject.value { return false }
        
        beforePresented?()
        let sessionProModal: ModalHostingViewController = ModalHostingViewController(
            modal: ProCTAModal(
                variant: variant,
                dataManager: dependencies[singleton: .imageDataManager],
                dismissType: dismissType,
                afterClosed: afterClosed,
                onConfirm: onConfirm
            )
        )
        presenting?(sessionProModal)
        
        return true
    }
    
    @MainActor public func showSessionProBottomSheetIfNeeded(
        showLoadingModal: ((String, String) -> Void)?,
        showErrorModal: ((String, ThemedAttributedString) -> Void)?,
        openUrl: ((URL) -> Void)?,
        presenting: ((UIViewController) -> Void)?
    ) {
        let viewModel = SessionProBottomSheetViewModel(using: dependencies)
        let sessionProBottomSheet: BottomSheetHostingViewController = BottomSheetHostingViewController(
            bottomSheet: BottomSheet(hasCloseButton: true) {
                SessionListScreen(viewModel: viewModel)
            }
        )
        presenting?(sessionProBottomSheet)
    }
}
