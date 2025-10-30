// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SessionUIKit
import SessionUtilitiesKit
import Combine

// MARK: - Singleton

public extension Singleton {
    static let sessionProState: SingletonConfig<SessionProManagerType> = Dependencies.create(
        identifier: "sessionProState",
        createInstance: { dependencies in SessionProState(using: dependencies) }
    )
}

// MARK: - SessionProState

public class SessionProState: SessionProManagerType {
    public let dependencies: Dependencies
    public var isSessionProSubject: CurrentValueSubject<Bool, Never>
    public var isSessionProPublisher: AnyPublisher<Bool, Never> {
        isSessionProSubject
            .filter { $0 }
            .eraseToAnyPublisher()
    }
    
    public init(using dependencies: Dependencies) {
        self.dependencies = dependencies
        self.isSessionProSubject = CurrentValueSubject(dependencies[cache: .libSession].isSessionPro)
    }
    
    public func upgradeToPro(completion: ((_ result: Bool) -> Void)?) {
        dependencies.set(feature: .mockCurrentUserSessionPro, to: true)
        self.isSessionProSubject.send(true)
        completion?(true)
    }
    
    @discardableResult @MainActor public func showSessionProCTAIfNeeded(
        _ variant: ProCTAModal.Variant,
        dismissType: Modal.DismissType,
        afterClosed: (() -> Void)?,
        presenting: ((UIViewController) -> Void)?
    ) -> Bool {
        guard dependencies[feature: .sessionProEnabled] && (!isSessionProSubject.value) else {
            return false
        }
        let sessionProModal: ModalHostingViewController = ModalHostingViewController(
            modal: ProCTAModal(
                delegate: dependencies[singleton: .sessionProState],
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
