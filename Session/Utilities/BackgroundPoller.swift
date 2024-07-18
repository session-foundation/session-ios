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

    public static func poll(
        completionHandler: @escaping (UIBackgroundFetchResult) -> Void,
        using dependencies: Dependencies = Dependencies()
    ) {
        let (groupIds, servers): (Set<String>, Set<String>) = Storage.shared.read { db in
                (
                    try ClosedGroup
                        .select(.threadId)
                        .joining(
                            required: ClosedGroup.members
                                .filter(GroupMember.Columns.profileId == getUserHexEncodedPublicKey(db))
                        )
                        .asRequest(of: String.self)
                        .fetchSet(db),
                    /// The default room promise creates an OpenGroup with an empty `roomToken` value, we
                    /// don't want to start a poller for this as the user hasn't actually joined a room
                    ///
                    /// We also want to exclude any rooms which have failed to poll too many times in a row from
                    /// the background poll as they are likely to fail again
                    try OpenGroup
                        .select(.server)
                        .filter(
                            OpenGroup.Columns.roomToken != "" &&
                            OpenGroup.Columns.isActive &&
                            OpenGroup.Columns.pollFailureCount < OpenGroupAPI.Poller.maxRoomFailureCountForBackgroundPoll
                        )
                        .distinct()
                        .asRequest(of: String.self)
                        .fetchSet(db)
                )
            }
            .defaulting(to: ([], []))
        
        let pollStart: TimeInterval = dependencies.dateNow.timeIntervalSince1970
        Log.info("[BackgroundPoller] Fetching Users: 1, Groups: \(groupIds.count), Communities: \(servers.count).")
        Publishers
            .MergeMany(
                [pollForMessages(using: dependencies)]
                    .appending(contentsOf: pollForClosedGroupMessages(groupIds: groupIds, using: dependencies))
                    .appending(contentsOf: pollForCommunityMessages(servers: servers, using: dependencies))
            )
            .subscribe(on: DispatchQueue.global(qos: .background), using: dependencies)
            .receive(on: DispatchQueue.main, using: dependencies)
            .collect()
            .handleEvents(
                receiveOutput: { _ in
                    let endTime: TimeInterval = dependencies.dateNow.timeIntervalSince1970
                    let duration: TimeUnit = .seconds(endTime - pollStart)
                    Log.info("[BackgroundPoller] Finished polling after \(duration, unit: .s).")
                }
            )
            .sinkUntilComplete(
                receiveCompletion: { result in
                    // If we have already invalidated the timer then do nothing (we essentially timed out)
                    guard BackgroundPoller.isValid else { return }
                    
                    switch result {
                        case .finished: completionHandler(.newData)
                        case .failure(let error):
                            let endTime: TimeInterval = dependencies.dateNow.timeIntervalSince1970
                            let duration: TimeUnit = .seconds(endTime - pollStart)
                            Log.error("[BackgroundPoller] Failed due to error: \(error) after \(duration, unit: .s).")
                            completionHandler(.failed)
                    }
                }
            )
    }
    
    private static func pollForMessages(
        using dependencies: Dependencies
    ) -> AnyPublisher<Void, Never> {
        let userPublicKey: String = getUserHexEncodedPublicKey(using: dependencies)
        
        let poller: Poller = CurrentUserPoller()
        let pollerName: String = poller.pollerName(for: userPublicKey)
        let pollStart: TimeInterval = dependencies.dateNow.timeIntervalSince1970
        
        return poller.poll(
            namespaces: CurrentUserPoller.namespaces,
            for: userPublicKey,
            calledFromBackgroundPoller: true,
            isBackgroundPollValid: { BackgroundPoller.isValid },
            drainBehaviour: .alwaysRandom,
            using: dependencies
        )
        .handleEvents(
            receiveOutput: { _, _, validMessageCount, _ in
                let endTime: TimeInterval = dependencies.dateNow.timeIntervalSince1970
                let duration: TimeUnit = .seconds(endTime - pollStart)
                Log.info("[BackgroundPoller] \(pollerName) received \(validMessageCount) valid message(s) after \(duration, unit: .s).")
            },
            receiveCompletion: { result in
                switch result {
                    case .finished: break
                    case .failure(let error):
                        let endTime: TimeInterval = dependencies.dateNow.timeIntervalSince1970
                        let duration: TimeUnit = .seconds(endTime - pollStart)
                        Log.error("[BackgroundPoller] \(pollerName) failed after \(duration, unit: .s) due to error: \(error).")
                }
            }
        )
        .map { _ in () }
        .catch { _ in Just(()).eraseToAnyPublisher() }
        .eraseToAnyPublisher()
    }
    
    private static func pollForClosedGroupMessages(
        groupIds: Set<String>,
        using dependencies: Dependencies
    ) -> [AnyPublisher<Void, Never>] {
        // Fetch all closed groups (excluding any don't contain the current user as a
        // GroupMemeber as the user is no longer a member of those)
        return groupIds.map { groupPublicKey in
            let poller: Poller = ClosedGroupPoller()
            let pollerName: String = poller.pollerName(for: groupPublicKey)
            let pollStart: TimeInterval = dependencies.dateNow.timeIntervalSince1970
            
            return poller
                .poll(
                    namespaces: ClosedGroupPoller.namespaces,
                    for: groupPublicKey,
                    calledFromBackgroundPoller: true,
                    isBackgroundPollValid: { BackgroundPoller.isValid },
                    drainBehaviour: .alwaysRandom,
                    using: dependencies
                )
                .handleEvents(
                    receiveOutput: { _, _, validMessageCount, _ in
                        let endTime: TimeInterval = dependencies.dateNow.timeIntervalSince1970
                        let duration: TimeUnit = .seconds(endTime - pollStart)
                        Log.info("[BackgroundPoller] \(pollerName) received \(validMessageCount) valid message(s) after \(duration, unit: .s).")
                    },
                    receiveCompletion: { result in
                        switch result {
                            case .finished: break
                            case .failure(let error):
                                let endTime: TimeInterval = dependencies.dateNow.timeIntervalSince1970
                                let duration: TimeUnit = .seconds(endTime - pollStart)
                                Log.error("[BackgroundPoller] \(pollerName) failed after \(duration, unit: .s) due to error: \(error).")
                        }
                    }
                )
                .map { _ in () }
                .catch { _ in Just(()).eraseToAnyPublisher() }
                .eraseToAnyPublisher()
        }
    }
    
    private static func pollForCommunityMessages(
        servers: Set<String>,
        using dependencies: Dependencies
    ) -> [AnyPublisher<Void, Never>] {
        return servers.map { server -> AnyPublisher<Void, Never> in
            let poller: OpenGroupAPI.Poller = OpenGroupAPI.Poller(for: server)
            let pollerName: String = "Community poller for server: \(server)"
            let pollStart: TimeInterval = dependencies.dateNow.timeIntervalSince1970
            poller.stop()
            
            return poller.poll(
                calledFromBackgroundPoller: true,
                isBackgroundPollerValid: { BackgroundPoller.isValid },
                isPostCapabilitiesRetry: false,
                using: dependencies
            )
            .handleEvents(
                receiveOutput: { _ in
                    let endTime: TimeInterval = dependencies.dateNow.timeIntervalSince1970
                    let duration: TimeUnit = .seconds(endTime - pollStart)
                    Log.info("[BackgroundPoller] \(pollerName) succeeded after \(duration, unit: .s).")
                },
                receiveCompletion: { result in
                    switch result {
                        case .finished: break
                        case .failure(let error):
                            let endTime: TimeInterval = dependencies.dateNow.timeIntervalSince1970
                            let duration: TimeUnit = .seconds(endTime - pollStart)
                            Log.error("[BackgroundPoller] \(pollerName) failed after \(duration, unit: .s) due to error: \(error).")
                    }
                }
            )
            .map { _ in () }
            .catch { _ in Just(()).eraseToAnyPublisher() }
            .eraseToAnyPublisher()
        }
    }
}
