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
    public var sessionProStateSubject: CurrentValueSubject<SessionProPlanState, Never>
    public var sessionProStatePublisher: AnyPublisher<SessionProPlanState, Never> {
        sessionProStateSubject
            .compactMap { $0 }
            .eraseToAnyPublisher()
    }
    public var sessionProPlans: [SessionProPlan]
    
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
                    originatingPlatform: .iOS
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
    }
    
    public func upgradeToPro(completion: ((_ result: Bool) -> Void)?) {
        dependencies.set(feature: .mockCurrentUserSessionPro, to: true)
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
        completion?(true)
    }
}
