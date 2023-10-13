// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import SessionSnodeKit
import SessionUtilitiesKit

@testable import SessionMessagingKit

class MockPoller: Mock<PollerType>, PollerType {
    func start(using dependencies: Dependencies) {
        accept(args: [dependencies])
    }
    
    func startIfNeeded(for publicKey: String, using dependencies: Dependencies) {
        accept(args: [publicKey, dependencies])
    }
    
    func stopAllPollers() {
        accept(args: [])
    }
    
    func stopPolling(for publicKey: String) {
        accept(args: [publicKey])
    }
    
    
    func poll(
        namespaces: [SnodeAPI.Namespace],
        for publicKey: String,
        calledFromBackgroundPoller: Bool,
        isBackgroundPollValid: @escaping () -> Bool,
        drainBehaviour: Atomic<SwarmDrainBehaviour>,
        using dependencies: Dependencies
    ) -> AnyPublisher<[ProcessedMessage], Error> {
        accept(args: [
            namespaces,
            publicKey,
            calledFromBackgroundPoller,
            isBackgroundPollValid,
            drainBehaviour,
            dependencies
        ]) as! AnyPublisher<[ProcessedMessage], Error>
    }
}
