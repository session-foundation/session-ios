// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import Combine
import GRDB
import SessionNetworkingKit
import SessionMessagingKit
import SessionUtilitiesKit

// MARK: - Log.Category

public extension Log.Category {
    static let backgroundPoller: Log.Category = .create("BackgroundPoller", defaultLevel: .info)
}

// MARK: - BackgroundPoller

public final class BackgroundPoller {
    typealias Pollers = (
        currentUser: CurrentUserPoller,
        groups: [GroupPoller],
        communities: [CommunityPoller]
    )
    
    public func poll(using dependencies: Dependencies) -> AnyPublisher<Void, Never> {
        let pollStart: TimeInterval = dependencies.dateNow.timeIntervalSince1970
        
        return dependencies[singleton: .storage]
            .readPublisher { db -> (Set<String>, Set<String>, [String]) in
                (
                    try ClosedGroup
                        .select(.threadId)
                        .joining(
                            required: ClosedGroup.members
                                .filter(GroupMember.Columns.profileId == dependencies[cache: .general].sessionId.hexString)
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
                            OpenGroup.Columns.pollFailureCount < CommunityPoller.maxRoomFailureCountForBackgroundPoll
                        )
                        .distinct()
                        .asRequest(of: String.self)
                        .fetchSet(db),
                    try OpenGroup
                        .select(.roomToken)
                        .filter(
                            OpenGroup.Columns.roomToken != "" &&
                            OpenGroup.Columns.isActive &&
                            OpenGroup.Columns.pollFailureCount < CommunityPoller.maxRoomFailureCountForBackgroundPoll
                        )
                        .distinct()
                        .asRequest(of: String.self)
                        .fetchAll(db)
                )
            }
            .catch { _ in Just(([], [], [])).eraseToAnyPublisher() }
            .handleEvents(
                receiveOutput: { groupIds, servers, rooms in
                    Log.info(.backgroundPoller, "Fetching Users: 1, Groups: \(groupIds.count), Communities: \(servers.count) (\(rooms.count) room(s)).")
                }
            )
            .map { groupIds, servers, _ -> Pollers in
                let currentUserPoller: CurrentUserPoller = CurrentUserPoller(
                    pollerName: "Background Main Poller",
                    pollerQueue: DispatchQueue.main,
                    pollerDestination: .swarm(dependencies[cache: .general].sessionId.hexString),
                    pollerDrainBehaviour: .limitedReuse(count: 6),
                    namespaces: CurrentUserPoller.namespaces,
                    shouldStoreMessages: true,
                    logStartAndStopCalls: false,
                    using: dependencies
                )
                let groupPollers: [GroupPoller] = groupIds.map { groupId in
                    GroupPoller(
                        pollerName: "Background Group poller for: \(groupId)",   // stringlint:ignore
                        pollerQueue: DispatchQueue.main,
                        pollerDestination: .swarm(groupId),
                        pollerDrainBehaviour: .alwaysRandom,
                        namespaces: GroupPoller.namespaces(swarmPublicKey: groupId),
                        shouldStoreMessages: true,
                        logStartAndStopCalls: false,
                        using: dependencies
                    )
                }
                let communityPollers: [CommunityPoller] = servers.map { server in
                    CommunityPoller(
                        pollerName: "Background Community poller for: \(server)",   // stringlint:ignore
                        pollerQueue: DispatchQueue.main,
                        pollerDestination: .server(server),
                        failureCount: 0,
                        shouldStoreMessages: true,
                        logStartAndStopCalls: false,
                        using: dependencies
                    )
                }
                
                return (currentUserPoller, groupPollers, communityPollers)
            }
            .flatMap { currentUserPoller, groupPollers, communityPollers in
                /// Need to map back to the pollers to ensure they don't get released until after the polling finishes
                Publishers.MergeMany(
                    [BackgroundPoller.pollUserMessages(poller: currentUserPoller, using: dependencies)]
                        .appending(contentsOf: BackgroundPoller.poll(pollers: groupPollers, using: dependencies))
                        .appending(contentsOf: BackgroundPoller.poll(pollerInfo: communityPollers, using: dependencies))
                )
                .collect()
                .map { _ in (currentUserPoller, groupPollers, communityPollers) }
            }
            .map { _ in () }
            .handleEvents(
                receiveOutput: { _ in
                    let endTime: TimeInterval = dependencies.dateNow.timeIntervalSince1970
                    let duration: TimeUnit = .seconds(endTime - pollStart)
                    Log.info(.backgroundPoller, "Finished polling after \(duration, unit: .s).")
                }
            )
            .eraseToAnyPublisher()
    }
    
    private static func pollUserMessages(
        poller: CurrentUserPoller,
        using dependencies: Dependencies
    ) -> AnyPublisher<Void, Never> {
        let pollStart: TimeInterval = dependencies.dateNow.timeIntervalSince1970
        
        return poller
            .pollFromBackground()
            .handleEvents(
                receiveOutput: { [pollerName = poller.pollerName] _, _, validMessageCount, _ in
                    let endTime: TimeInterval = dependencies.dateNow.timeIntervalSince1970
                    let duration: TimeUnit = .seconds(endTime - pollStart)
                    Log.info(.backgroundPoller, "\(pollerName) received \(validMessageCount) valid message(s) after \(duration, unit: .s).")
                },
                receiveCompletion: { [pollerName = poller.pollerName] result in
                    switch result {
                        case .finished: break
                        case .failure(let error):
                            let endTime: TimeInterval = dependencies.dateNow.timeIntervalSince1970
                            let duration: TimeUnit = .seconds(endTime - pollStart)
                            Log.error(.backgroundPoller, "\(pollerName) failed after \(duration, unit: .s) due to error: \(error).")
                    }
                }
            )
            .map { _ in () }
            .catch { _ in Just(()).eraseToAnyPublisher() }
            .eraseToAnyPublisher()
    }
    
    private static func poll(
        pollers: [GroupPoller],
        using dependencies: Dependencies
    ) -> [AnyPublisher<Void, Never>] {
        // Fetch all closed groups (excluding any don't contain the current user as a
        // GroupMemeber as the user is no longer a member of those)
        return pollers.map { poller in
            let pollStart: TimeInterval = dependencies.dateNow.timeIntervalSince1970
            
            return poller
                .pollFromBackground()
                .handleEvents(
                    receiveOutput: { [pollerName = poller.pollerName] _, _, validMessageCount, _ in
                        let endTime: TimeInterval = dependencies.dateNow.timeIntervalSince1970
                        let duration: TimeUnit = .seconds(endTime - pollStart)
                        Log.info(.backgroundPoller, "\(pollerName) received \(validMessageCount) valid message(s) after \(duration, unit: .s).")
                    },
                    receiveCompletion: { [pollerName = poller.pollerName] result in
                        switch result {
                            case .finished: break
                            case .failure(let error):
                                let endTime: TimeInterval = dependencies.dateNow.timeIntervalSince1970
                                let duration: TimeUnit = .seconds(endTime - pollStart)
                                Log.error(.backgroundPoller, "\(pollerName) failed after \(duration, unit: .s) due to error: \(error).")
                        }
                    }
                )
                .map { _ in () }
                .catch { _ in Just(()).eraseToAnyPublisher() }
                .eraseToAnyPublisher()
        }
    }
    
    private static func poll(
        pollerInfo: [CommunityPoller],
        using dependencies: Dependencies
    ) -> [AnyPublisher<Void, Never>] {
        return pollerInfo.map { poller -> AnyPublisher<Void, Never> in
            let pollStart: TimeInterval = dependencies.dateNow.timeIntervalSince1970
            
            return poller
                .pollFromBackground()
                .handleEvents(
                    receiveOutput: { [pollerName = poller.pollerName] _, _, rawMessageCount, _ in
                        let endTime: TimeInterval = dependencies.dateNow.timeIntervalSince1970
                        let duration: TimeUnit = .seconds(endTime - pollStart)
                        Log.info(.backgroundPoller, "\(pollerName) received \(rawMessageCount) message(s) succeeded after \(duration, unit: .s).")
                    },
                    receiveCompletion: { [pollerName = poller.pollerName] result in
                        switch result {
                            case .finished: break
                            case .failure(let error):
                                let endTime: TimeInterval = dependencies.dateNow.timeIntervalSince1970
                                let duration: TimeUnit = .seconds(endTime - pollStart)
                                Log.error(.backgroundPoller, "\(pollerName) failed after \(duration, unit: .s) due to error: \(error).")
                        }
                    }
                )
                .map { _ in () }
                .catch { _ in Just(()).eraseToAnyPublisher() }
                .eraseToAnyPublisher()
        }
    }
}
