// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionSnodeKit
import SessionMessagingKit
import SessionUtilitiesKit

public final class BackgroundPoller {
    private static var publishers: [AnyPublisher<Void, Error>] = []
    public static var isValid: Bool = false

    public static func poll(completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        Publishers
            .MergeMany(
                [pollForMessages()]
                    .appending(contentsOf: pollForClosedGroupMessages())
                    .appending(
                        contentsOf: Storage.shared
                            .read { db in
                                // The default room promise creates an OpenGroup with an empty
                                // `roomToken` value, we don't want to start a poller for this
                                // as the user hasn't actually joined a room
                                try OpenGroup
                                    .select(.server)
                                    .filter(OpenGroup.Columns.roomToken != "")
                                    .filter(OpenGroup.Columns.isActive)
                                    .distinct()
                                    .asRequest(of: String.self)
                                    .fetchSet(db)
                            }
                            .defaulting(to: [])
                            .map { server -> AnyPublisher<Void, Error> in
                                let poller: OpenGroupAPI.Poller = OpenGroupAPI.Poller(for: server)
                                poller.stop()
                                
                                return poller.poll(
                                    calledFromBackgroundPoller: true,
                                    isBackgroundPollerValid: { BackgroundPoller.isValid },
                                    isPostCapabilitiesRetry: false
                                )
                            }
                    )
            )
            .subscribeOnMain(immediately: true)
            .receiveOnMain(immediately: true)
            .collect()
            .sinkUntilComplete(
                receiveCompletion: { result in
                    // If we have already invalidated the timer then do nothing (we essentially timed out)
                    guard BackgroundPoller.isValid else { return }
                    
                    switch result {
                        case .finished: completionHandler(.newData)
                        case .failure(let error):
                            SNLog("Background poll failed due to error: \(error)")
                            completionHandler(.failed)
                    }
                }
            )
    }
    
    private static func pollForMessages() -> AnyPublisher<Void, Error> {
        let userPublicKey: String = getUserHexEncodedPublicKey()

        return SnodeAPI.getSwarm(for: userPublicKey)
            .subscribeOnMain(immediately: true)
            .receiveOnMain(immediately: true)
            .flatMap { swarm -> AnyPublisher<Void, Error> in
                guard let snode = swarm.randomElement() else {
                    return Fail(error: SnodeAPIError.generic)
                        .eraseToAnyPublisher()
                }
                
                return CurrentUserPoller.poll(
                    namespaces: CurrentUserPoller.namespaces,
                    from: snode,
                    for: userPublicKey,
                    on: DispatchQueue.main,
                    calledFromBackgroundPoller: true,
                    isBackgroundPollValid: { BackgroundPoller.isValid }
                )
            }
            .eraseToAnyPublisher()
    }
    
    private static func pollForClosedGroupMessages() -> [AnyPublisher<Void, Error>] {
        // Fetch all closed groups (excluding any don't contain the current user as a
        // GroupMemeber as the user is no longer a member of those)
        return Storage.shared
            .read { db in
                try ClosedGroup
                    .select(.threadId)
                    .joining(
                        required: ClosedGroup.members
                            .filter(GroupMember.Columns.profileId == getUserHexEncodedPublicKey(db))
                    )
                    .asRequest(of: String.self)
                    .fetchAll(db)
            }
            .defaulting(to: [])
            .map { groupPublicKey in
                SnodeAPI.getSwarm(for: groupPublicKey)
                    .subscribeOnMain(immediately: true)
                    .receiveOnMain(immediately: true)
                    .flatMap { swarm -> AnyPublisher<Void, Error> in
                        guard let snode: Snode = swarm.randomElement() else {
                            return Fail(error: OnionRequestAPIError.insufficientSnodes)
                                .eraseToAnyPublisher()
                        }
                        
                        return ClosedGroupPoller.poll(
                            namespaces: ClosedGroupPoller.namespaces,
                            from: snode,
                            for: groupPublicKey,
                            on: DispatchQueue.main,
                            calledFromBackgroundPoller: true,
                            isBackgroundPollValid: { BackgroundPoller.isValid }
                        )
                    }
                    .eraseToAnyPublisher()
            }
    }
}
