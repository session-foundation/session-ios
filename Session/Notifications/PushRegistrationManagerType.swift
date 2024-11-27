// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine

// FIXME: Remove this in Groups Rebuild (redundant with the updated dependency management)
public protocol PushRegistrationManagerType {
    func createVoipRegistryIfNecessary()
    func didReceiveVanillaPushToken(_ tokenData: Data)
    func didFailToReceiveVanillaPushToken(error: Error)
    
    func requestPushTokens() -> AnyPublisher<(pushToken: String, voipToken: String), Error>
}

// MARK: - NoopPushRegistrationManager

public class NoopPushRegistrationManager: PushRegistrationManagerType {
    public func createVoipRegistryIfNecessary() {}
    public func didReceiveVanillaPushToken(_ tokenData: Data) {}
    public func didFailToReceiveVanillaPushToken(error: Error) {}
    
    public func requestPushTokens() -> AnyPublisher<(pushToken: String, voipToken: String), Error> {
        return Fail(
            error: PushRegistrationError.assertionError(
                description: "Attempted to register with NoopPushRegistrationManager"   // stringlint:ignore
            )
        ).eraseToAnyPublisher()
    }
}
