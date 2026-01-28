// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import Combine
import GRDB
import SessionUIKit
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
    
    public func poll(using dependencies: Dependencies) async -> Bool {
        typealias PollerData = (
            groupIds: Set<String>,
            servers: Set<String>,
            rooms: [String]
        )
        
        let pollStart: TimeInterval = dependencies.dateNow.timeIntervalSince1970
        let maybeData: PollerData? = try? await dependencies[singleton: .storage].readAsync { db in
            (
                try ClosedGroup
                    .select(.threadId)
                    .filter(ClosedGroup.Columns.shouldPoll)
                    .asRequest(of: String.self)
                    .fetchSet(db),
                /// We want to exclude any rooms which have failed to poll too many times in a row from
                /// the background poll as they are likely to fail again
                try OpenGroup
                    .select(.server)
                    .filter(
                        OpenGroup.Columns.shouldPoll == true &&
                        OpenGroup.Columns.pollFailureCount < CommunityPoller.maxRoomFailureCountForBackgroundPoll
                    )
                    .distinct()
                    .asRequest(of: String.self)
                    .fetchSet(db),
                try OpenGroup
                    .select(.roomToken)
                    .filter(
                        OpenGroup.Columns.shouldPoll == true &&
                        OpenGroup.Columns.pollFailureCount < CommunityPoller.maxRoomFailureCountForBackgroundPoll
                    )
                    .distinct()
                    .asRequest(of: String.self)
                    .fetchAll(db)
            )
        }
        
        guard let data: PollerData = maybeData else { return false }
        
        Log.info(.backgroundPoller, "Fetching Users: 1, Groups: \(data.groupIds.count), Communities: \(data.servers.count) (\(data.rooms.count) room(s)).")
        let currentUserPoller: CurrentUserPoller = CurrentUserPoller(
            pollerName: "Background Main Poller",
            pollerQueue: DispatchQueue.main,
            pollerDestination: .swarm(dependencies[cache: .general].sessionId.hexString),
            swarmDrainStrategy: .limitedReuse(count: 6),
            namespaces: CurrentUserPoller.namespaces,
            shouldStoreMessages: true,
            logStartAndStopCalls: false,
            key: nil,
            using: dependencies
        )
        let groupPollers: [GroupPoller] = data.groupIds.map { groupId in
            GroupPoller(
                pollerName: "Background Group poller for: \(groupId)",   // stringlint:ignore
                pollerQueue: DispatchQueue.main,
                pollerDestination: .swarm(groupId),
                swarmDrainStrategy: .alwaysRandom,
                namespaces: GroupPoller.namespaces(swarmPublicKey: groupId),
                shouldStoreMessages: true,
                logStartAndStopCalls: false,
                key: nil,
                using: dependencies
            )
        }
        let communityPollers: [CommunityPoller] = data.servers.map { server in
            CommunityPoller(
                pollerName: "Background Community poller for: \(server)",   // stringlint:ignore
                pollerQueue: DispatchQueue.main,
                pollerDestination: .server(server),
                swarmDrainStrategy: .alwaysRandom,
                failureCount: 0,
                shouldStoreMessages: true,
                logStartAndStopCalls: false,
                using: dependencies
            )
        }
        
        let hadMessages: Bool = await withTaskGroup(of: Bool.self) { group in
            BackgroundPoller.pollUserMessages(
                poller: currentUserPoller,
                in: &group,
                using: dependencies
            )
            BackgroundPoller.poll(
                pollers: groupPollers,
                in: &group,
                using: dependencies
            )
            BackgroundPoller.poll(
                pollerInfo: communityPollers,
                in: &group,
                using: dependencies
            )
            
            return await group.reduce(false) { $0 || $1 }
        }
        
        let endTime: TimeInterval = dependencies.dateNow.timeIntervalSince1970
        let duration: TimeUnit = .seconds(endTime - pollStart)
        Log.info(.backgroundPoller, "Finished polling after \(duration, unit: .s).")
        
        return hadMessages
    }
    
    private static func pollUserMessages(
        poller: CurrentUserPoller,
        in group: inout TaskGroup<Bool>,
        using dependencies: Dependencies
    ) {
        group.addTask {
            let pollStart: TimeInterval = dependencies.dateNow.timeIntervalSince1970
            
            do {
                let validMessageCount: Int = try await poller.pollFromBackground().validMessageCount
                let endTime: TimeInterval = dependencies.dateNow.timeIntervalSince1970
                let duration: TimeUnit = .seconds(endTime - pollStart)
                Log.info(.backgroundPoller, "\(poller.pollerName) received \(validMessageCount) valid message(s) after \(duration, unit: .s).")
                
                return (validMessageCount > 0)
            }
            catch {
                let endTime: TimeInterval = dependencies.dateNow.timeIntervalSince1970
                let duration: TimeUnit = .seconds(endTime - pollStart)
                Log.error(.backgroundPoller, "\(poller.pollerName) failed after \(duration, unit: .s) due to error: \(error).")
                
                return false
            }
        }
    }
    
    private static func poll(
        pollers: [GroupPoller],
        in group: inout TaskGroup<Bool>,
        using dependencies: Dependencies
    ) {
        // Fetch all closed groups (excluding any don't contain the current user as a
        // GroupMemeber as the user is no longer a member of those)
        for poller in pollers {
            group.addTask {
                let pollStart: TimeInterval = dependencies.dateNow.timeIntervalSince1970
                
                do {
                    let validMessageCount: Int = try await poller.pollFromBackground().validMessageCount
                    let endTime: TimeInterval = dependencies.dateNow.timeIntervalSince1970
                    let duration: TimeUnit = .seconds(endTime - pollStart)
                    Log.info(.backgroundPoller, "\(poller.pollerName) received \(validMessageCount) valid message(s) after \(duration, unit: .s).")
                    
                    return (validMessageCount > 0)
                }
                catch {
                    let endTime: TimeInterval = dependencies.dateNow.timeIntervalSince1970
                    let duration: TimeUnit = .seconds(endTime - pollStart)
                    Log.error(.backgroundPoller, "\(poller.pollerName) failed after \(duration, unit: .s) due to error: \(error).")
                    
                    return false
                }
            }
        }
    }
    
    private static func poll(
        pollerInfo: [CommunityPoller],
        in group: inout TaskGroup<Bool>,
        using dependencies: Dependencies
    ) {
        for poller in pollerInfo {
            group.addTask {
                let pollStart: TimeInterval = dependencies.dateNow.timeIntervalSince1970
                
                do {
                    let rawMessageCount: Int = try await poller.pollFromBackground().rawMessageCount
                    let endTime: TimeInterval = dependencies.dateNow.timeIntervalSince1970
                    let duration: TimeUnit = .seconds(endTime - pollStart)
                    Log.info(.backgroundPoller, "\(poller.pollerName) received \(rawMessageCount) message(s) succeeded after \(duration, unit: .s).")
                    
                    return (rawMessageCount > 0)
                }
                catch {
                    let endTime: TimeInterval = dependencies.dateNow.timeIntervalSince1970
                    let duration: TimeUnit = .seconds(endTime - pollStart)
                    Log.error(.backgroundPoller, "\(poller.pollerName) failed after \(duration, unit: .s) due to error: \(error).")
                    
                    return false
                }
            }
        }
    }
}
