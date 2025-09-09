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
    public var sessionProPlans: [SessionProPlan]
    public var isAutoRenewEnabled: Bool
    public var originatingPlatform: ClientPlatform
    public var currentPlan: SessionProPlan?
    public var currentPlanExpiredOn: Date?
    
    public init(using dependencies: Dependencies) {
        self.dependencies = dependencies
        self.isSessionProSubject = CurrentValueSubject(dependencies[cache: .libSession].isSessionPro)
        self.sessionProPlans = SessionProPlan.Variant.allCases.map {
            SessionProPlan(
                variant: $0,
                price: $0.price,
                discountPercent: $0.discountPercent
            )
        }
        self.currentPlan = SessionProPlan(
            variant: .threeMonths,
            price: SessionProPlan.Variant.threeMonths.price,
            discountPercent: SessionProPlan.Variant.threeMonths.discountPercent
        )
        self.isAutoRenewEnabled = true
        self.originatingPlatform = .iOS
        self.currentPlanExpiredOn = Calendar.current.date(byAdding: .month, value: 1, to: Date())
    }
    
    public func upgradeToPro(completion: ((_ result: Bool) -> Void)?) {
        dependencies.set(feature: .mockCurrentUserSessionPro, to: true)
        self.isSessionProSubject.send(true)
        completion?(true)
    }
}
