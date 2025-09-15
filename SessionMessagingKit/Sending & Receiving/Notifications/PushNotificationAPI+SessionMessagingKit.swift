// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionNetworkingKit
import SessionUtilitiesKit

public extension Network.PushNotification {
    static func subscribeAll(
        token: Data,
        isForcedUpdate: Bool,
        using dependencies: Dependencies
    ) -> AnyPublisher<Void, Error> {
        let hexEncodedToken: String = token.toHexString()
        let oldToken: String? = dependencies[defaults: .standard, key: .deviceToken]
        let lastUploadTime: Double = dependencies[defaults: .standard, key: .lastDeviceTokenUpload]
        let now: TimeInterval = dependencies.dateNow.timeIntervalSince1970
        
        guard isForcedUpdate || hexEncodedToken != oldToken || now - lastUploadTime > tokenExpirationInterval else {
            Log.info(.pushNotificationAPI, "Device token hasn't changed or expired; no need to re-upload.")
            return Just(())
                .setFailureType(to: Error.self)
                .eraseToAnyPublisher()
        }
        
        return dependencies[singleton: .storage]
            .readPublisher { db -> Network.PreparedRequest<Network.PushNotification.SubscribeResponse> in
                let userSessionId: SessionId = dependencies[cache: .general].sessionId
                let userAuthMethod: AuthenticationMethod = try Authentication.with(
                    db,
                    swarmPublicKey: userSessionId.hexString,
                    using: dependencies
                )
                
                return try Network.PushNotification
                    .preparedSubscribe(
                        token: token,
                        swarms: [(userSessionId, userAuthMethod)]
                            .appending(contentsOf: try ClosedGroup
                                .select(.threadId)
                                .filter(
                                    ClosedGroup.Columns.threadId > SessionId.Prefix.group.rawValue &&
                                    ClosedGroup.Columns.threadId < SessionId.Prefix.group.endOfRangeString
                                )
                                .filter(ClosedGroup.Columns.shouldPoll)
                                .asRequest(of: String.self)
                                .fetchSet(db)
                                .map { threadId in
                                    (
                                        SessionId(.group, hex: threadId),
                                        try Authentication.with(
                                            db,
                                            swarmPublicKey: threadId,
                                            using: dependencies
                                        )
                                    )
                                }
                            ),
                        using: dependencies
                    )
                    .handleEvents(
                        receiveOutput: { _, response in
                            guard response.subResponses.first?.success == true else { return }
                            
                            dependencies[defaults: .standard, key: .deviceToken] = hexEncodedToken
                            dependencies[defaults: .standard, key: .lastDeviceTokenUpload] = now
                            dependencies[defaults: .standard, key: .isUsingFullAPNs] = true
                        }
                    )
            }
            .flatMap { $0.send(using: dependencies) }
            .map { _ in () }
            .eraseToAnyPublisher()
    }
    
    public static func unsubscribeAll(
        token: Data,
        using dependencies: Dependencies
    ) -> AnyPublisher<Void, Error> {
        return dependencies[singleton: .storage]
            .readPublisher { db -> Network.PreparedRequest<Network.PushNotification.UnsubscribeResponse> in
                let userSessionId: SessionId = dependencies[cache: .general].sessionId
                let userAuthMethod: AuthenticationMethod = try Authentication.with(
                    db,
                    swarmPublicKey: userSessionId.hexString,
                    using: dependencies
                )
                
                return try Network.PushNotification
                    .preparedUnsubscribe(
                        token: token,
                        swarms: [(userSessionId, userAuthMethod)]
                            .appending(contentsOf: (try? ClosedGroup
                                .select(.threadId)
                                .filter(
                                    ClosedGroup.Columns.threadId > SessionId.Prefix.group.rawValue &&
                                    ClosedGroup.Columns.threadId < SessionId.Prefix.group.endOfRangeString
                                )
                                .asRequest(of: String.self)
                                .fetchSet(db))
                                .defaulting(to: [])
                                .map { threadId in
                                    (
                                        SessionId(.group, hex: threadId),
                                        try Authentication.with(
                                            db,
                                            swarmPublicKey: threadId,
                                            using: dependencies
                                        )
                                    )
                                }),
                        using: dependencies
                    )
                    .handleEvents(
                        receiveOutput: { _, response in
                            guard response.subResponses.first?.success == true else { return }
                            
                            dependencies[defaults: .standard, key: .deviceToken] = nil
                        }
                    )
            }
            .flatMap { $0.send(using: dependencies) }
            .map { _ in () }
            .eraseToAnyPublisher()
    }
}
