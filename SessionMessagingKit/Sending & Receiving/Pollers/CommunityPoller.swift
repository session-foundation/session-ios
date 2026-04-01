// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionUIKit
import SessionNetworkingKit
import SessionUtilitiesKit

// MARK: - Cache

public extension Singleton {
    static let communityPollerManager: SingletonConfig<CommunityPollerManagerType> = Dependencies.create(
        identifier: "communityPollers",
        createInstance: { dependencies, _ in CommunityPollerManager(using: dependencies) }
    )
}

// MARK: - CommunityPoller Convenience

public extension PollerType where PollResponse == CommunityPoller.PollResponse {
    init(
        pollerName: String,
        destination: PollerDestination,
        failureCount: Int = 0,
        numConsecutiveEmptyPolls: Int = 0,
        shouldStoreMessages: Bool,
        logStartAndStopCalls: Bool,
        customAuthMethod: AuthenticationMethod? = nil,
        using dependencies: Dependencies
    ) {
        self.init(
            pollerName: pollerName,
            destination: destination,
            swarmDrainStrategy: .alwaysRandom,
            namespaces: [],
            failureCount: failureCount,
            numConsecutiveEmptyPolls: numConsecutiveEmptyPolls,
            shouldStoreMessages: shouldStoreMessages,
            logStartAndStopCalls: logStartAndStopCalls,
            customAuthMethod: customAuthMethod,
            key: nil,
            using: dependencies
        )
    }
}

// MARK: - CommunityPoller

private typealias Capabilities = Network.SOGS.CapabilitiesResponse

public actor CommunityPoller: PollerType {
    public typealias PollResponse = (
        info: ResponseInfoType,
        data: Network.BatchResponseMap<Network.SOGS.Endpoint>
    )
    
    // MARK: - Settings
    
    private static let minPollInterval: TimeInterval = 3
    private static let maxPollInterval: TimeInterval = (60 * 60)
    
    /// If there are hidden rooms that we poll and they fail too many times we want to prune them (as it likely means they no longer
    /// exist, and since they are already hidden it's unlikely that the user will notice that we stopped polling for them)
    internal static let maxHiddenRoomFailureCount: Int64 = 10
    
    /// When doing a background poll we want to only fetch from rooms which are unlikely to timeout, in order to do this we exclude
    /// any rooms which have failed more than this threashold
    public static let maxRoomFailureCountForBackgroundPoll: Int64 = 15
    
    // MARK: - PollerType
    
    public let dependencies: Dependencies
    public let dependenciesKey: Dependencies.Key? = nil
    public let pollerName: String
    public let destination: PollerDestination
    public let logStartAndStopCalls: Bool
    nonisolated public var receivedPollResponse: AsyncStream<PollResponse> { responseStream.stream }
    nonisolated public var successfulPollCount: AsyncStream<Int> { pollCountStream.stream }
    
    public var pollTask: Task<Void, Error>?
    public var pollCount: Int = 0
    public var failureCount: Int
    public var lastPollStart: TimeInterval = 0
    private var lastError: Error?
    
    private let shouldStoreMessages: Bool
    nonisolated private let responseStream: CancellationAwareAsyncStream<PollResponse> = CancellationAwareAsyncStream()
    nonisolated private let pollCountStream: CurrentValueAsyncStream<Int> = CurrentValueAsyncStream(0)
    
    // MARK: - Initialization
    
    public init(
        pollerName: String,
        destination: PollerDestination,
        swarmDrainStrategy: SwarmDrainer.Strategy,
        namespaces: [Network.StorageServer.Namespace],
        failureCount: Int,
        numConsecutiveEmptyPolls: Int,
        shouldStoreMessages: Bool,
        logStartAndStopCalls: Bool,
        customAuthMethod: AuthenticationMethod?,
        key: Dependencies.Key?,
        using dependencies: Dependencies
    ) {
        self.dependencies = dependencies
        self.pollerName = pollerName
        self.destination = destination
        self.failureCount = failureCount
        self.shouldStoreMessages = shouldStoreMessages
        self.logStartAndStopCalls = logStartAndStopCalls
    }
    
    deinit {
        /// Send completion events to the observables
        Task { [responseStream, pollCountStream] in
            await responseStream.finishCurrentStreams()
            await pollCountStream.finishCurrentStreams()
        }
        
        pollTask?.cancel()
    }
    
    // MARK: - PollerType

    public func nextPollDelay() async -> TimeInterval {
        // Arbitrary backoff factor...
        return min(
            CommunityPoller.maxPollInterval,
            (CommunityPoller.minPollInterval + pow(2, Double(failureCount)))
        )
    }
    
    public func handlePollError(_ error: Error) async {
        /// Store the error to prevent looping and re-handling the `isMissingBlindedAuthError` case
        let lastErrorWasBlindedAuthError: Bool = (lastError?.isMissingBlindedAuthError == true)
        lastError = error
        
        /// We want to custom handle a '400' error code due to not having blinded auth as it likely means that we join the
        /// OpenGroup before blinding was enabled and need to update it's capabilities
        ///
        /// **Note:** To prevent an infinite loop caused by a server-side bug we want to prevent this capabilities request from
        /// happening multiple times in a row
        guard error.isMissingBlindedAuthError && !lastErrorWasBlindedAuthError else {
            /// Save the updated failure count to the database
            _ = try? await dependencies[singleton: .storage].write { [destination, failureCount, manager = dependencies[singleton: .communityManager]] db in
                try OpenGroup
                    .filter(OpenGroup.Columns.server == destination.target)
                    .updateAll(
                        db,
                        OpenGroup.Columns.pollFailureCount.set(to: failureCount)
                    )
                
                /// Update the `CommunityManager` cache
                db.afterCommit {
                    Task.detached(priority: .userInitiated) {
                        await manager.updatePollFailureCount(0, server: destination.target)
                    }
                }
            }
            return
        }
        
        /// Since we have gotten here we should update the SOGS capabilities before triggering the next poll
        do {
            let server: CommunityManager.Server = try await dependencies[singleton: .communityManager]
                .server(destination.target) ?? { throw CryptoError.invalidAuthentication }()
            let authMethod: AuthenticationMethod = server.authMethod(forceBlinded: true)
            let request: Network.PreparedRequest<Network.SOGS.CapabilitiesResponse> = try Network.SOGS.preparedCapabilities(
                authMethod: authMethod,
                using: dependencies
            )
            let response: Network.SOGS.CapabilitiesResponse = try await request.send(using: dependencies)
            
            try await dependencies[singleton: .storage].write { [destination, manager = dependencies[singleton: .communityManager]] db in
                manager.handleCapabilities(
                    db,
                    capabilities: response,
                    server: destination.target,
                    publicKey: server.publicKey
                )
            }
        }
        catch {
            /// Log the error first
            Log.error(.poller, "\(pollerName) failed to update capabilities due to error: \(error).")
            
            /// If the polling has failed 10+ times then try to prune any invalid rooms that
            /// aren't visible (they would have been added via config messages and will
            /// likely always fail but the user has no way to delete them)
            guard failureCount > CommunityPoller.maxHiddenRoomFailureCount else {
                /// Save the updated failure count to the database
                _ = try? await dependencies[singleton: .storage].write { [destination, failureCount] db in
                    try OpenGroup
                        .filter(OpenGroup.Columns.server == destination.target)
                        .updateAll(
                            db,
                            OpenGroup.Columns.pollFailureCount.set(to: failureCount)
                        )
                }
                return
            }
            
            let hiddenRoomIds: [String]? = try? await dependencies[singleton: .storage].write { [destination, failureCount, dependencies] db -> [String] in
                /// Save the updated failure count to the database
                try OpenGroup
                    .filter(OpenGroup.Columns.server == destination.target)
                    .updateAll(
                        db,
                        OpenGroup.Columns.pollFailureCount.set(to: failureCount)
                    )
                
                /// Prune any hidden rooms
                let roomIds: Set<String> = try OpenGroup
                    .filter(
                        OpenGroup.Columns.server == destination.target &&
                        OpenGroup.Columns.shouldPoll == true
                    )
                    .select(.roomToken)
                    .asRequest(of: String.self)
                    .fetchSet(db)
                    .map { OpenGroup.idFor(roomToken: $0, server: destination.target) }
                    .asSet()
                let hiddenRoomIds: Set<String> = try SessionThread
                    .select(.id)
                    .filter(ids: roomIds)
                    .filter(
                        SessionThread.Columns.shouldBeVisible == false ||
                        SessionThread.Columns.pinnedPriority == LibSession.hiddenPriority
                    )
                    .asRequest(of: String.self)
                    .fetchSet(db)

                try hiddenRoomIds.forEach { id in
                    try dependencies[singleton: .communityManager].delete(
                        db,
                        openGroupId: id,
                        /// **Note:** We pass `skipLibSessionUpdate` as `true`
                        /// here because we want to avoid syncing this deletion as the room might
                        /// not be in an invalid state on other devices - one of the other devices
                        /// will eventually trigger a new config update which will re-add this room
                        /// and hopefully at that time it'll work again
                        skipLibSessionUpdate: true
                    )
                }

                return Array(hiddenRoomIds)
            }
            
            guard let hiddenRoomIds: [String] = hiddenRoomIds, !hiddenRoomIds.isEmpty else { return }
            
            /// Add a note to the logs that this happened
            let rooms: String = hiddenRoomIds
                .sorted()
                .compactMap { $0.components(separatedBy: destination.target).last }
                .joined(separator: ", ")
            Log.error(.poller, "\(pollerName) failure count surpassed \(CommunityPoller.maxHiddenRoomFailureCount), removed hidden rooms [\(rooms)].")
        }
    }

    // MARK: - Polling
    
    public func pollerDidStart() {}
    
    public func pollerReceivedResponse(_ response: PollResponse) async {
        pollCount += 1
        await responseStream.send(response)
        await pollCountStream.send(pollCount)
    }
    
    public func pollerDidStop() {
        Task { await responseStream.finishCurrentStreams() }
    }
    
    /// Polls based on it's configuration and processes any messages, returning an array of messages that were
    /// successfully processed
    ///
    /// **Note:** The returned messages will have already been processed by the `Poller`, they are only returned
    /// for cases where we need explicit/custom behaviours to occur (eg. Onboarding)
    public func poll(forceSynchronousProcessing: Bool = false) async throws -> PollResult<PollResponse> {
        typealias APIValue = Network.BatchResponseMap<Network.SOGS.Endpoint>
        let lastSuccessfulPollTimestamp: TimeInterval = (self.lastPollStart > 0 ?
            lastPollStart :
            await dependencies[singleton: .communityManager].getLastSuccessfulCommunityPollTimestamp()
        )
        
        let server: CommunityManager.Server = try await dependencies[singleton: .communityManager]
            .server(destination.target) ?? { throw CryptoError.invalidAuthentication }()
        let authMethod: AuthenticationMethod = server.authMethod()
        let request: Network.PreparedRequest<APIValue> = try Network.SOGS.preparedPoll(
            roomInfo: server.rooms.values.compactMap { room in
                /// Exclude rooms we shouldn't be polling (the server could contain additional rooms due to certain request responses)
                guard server.roomsToPoll.contains(room.token) else { return nil }
                
                return Network.SOGS.PollRoomInfo(
                    roomToken: room.token,
                    infoUpdates: room.infoUpdates,
                    sequenceNumber: room.messageSequence
                )
            },
            lastInboxMessageId: server.inboxLatestMessageId,
            lastOutboxMessageId: server.outboxLatestMessageId,
            checkForCommunityMessageRequests: dependencies.mutate(cache: .libSession) {
                $0.get(.checkForCommunityMessageRequests)
            },
            hasPerformedInitialPoll: (pollCount > 0),
            timeSinceLastPoll: (dependencies.dateNow.timeIntervalSince1970 - lastSuccessfulPollTimestamp),
            authMethod: authMethod,
            using: dependencies
        )
        let response: (info: ResponseInfoType, value: APIValue) = try await request.send(using: dependencies)
        let result: PollResult<PollResponse> = try await handlePollResponse(
            info: response.info,
            response: response.value,
            server: server,
            failureCount: failureCount,
            using: dependencies
        )
        await dependencies[singleton: .communityManager].setLastSuccessfulCommunityPollTimestamp(
            dependencies.dateNow.timeIntervalSince1970
        )
        
        return result
    }
    
    private func handlePollResponse(
        info: ResponseInfoType,
        response: Network.BatchResponseMap<Network.SOGS.Endpoint>,
        server: CommunityManager.Server,
        failureCount: Int,
        using dependencies: Dependencies
    ) async throws -> PollResult<PollResponse> {
        var rawMessageCount: Int = 0
        var invalidMessageCount: Int = 0
        let validResponses: [Network.SOGS.Endpoint: Any] = response.data
            .filter { endpoint, data in
                switch endpoint {
                    case .capabilities:
                        guard (data as? Network.BatchSubResponse<Network.SOGS.CapabilitiesResponse>)?.body != nil else {
                            Log.error(.poller, "\(pollerName) failed due to invalid capability data.")
                            return false
                        }
                        
                        return true
                        
                    case .roomPollInfo(let roomToken, _):
                        guard (data as? Network.BatchSubResponse<Network.SOGS.RoomPollInfo>)?.body != nil else {
                            switch (data as? Network.BatchSubResponse<Network.SOGS.RoomPollInfo>)?.code {
                                case 404: Log.error(.poller, "\(pollerName) failed to retrieve info for unknown room '\(roomToken)'.")
                                case 403: Log.error(.poller, "\(pollerName) failed to retrieve info for banned room '\(roomToken)'.")
                                default: Log.error(.poller, "\(pollerName) failed due to invalid room info data.")
                            }
                            return false
                        }
                        
                        return true
                        
                    case .roomMessagesRecent(let roomToken), .roomMessagesBefore(let roomToken, _), .roomMessagesSince(let roomToken, _):
                        guard
                            let responseData: Network.BatchSubResponse<[Failable<Network.SOGS.Message>]> = data as? Network.BatchSubResponse<[Failable<Network.SOGS.Message>]>,
                            let responseBody: [Failable<Network.SOGS.Message>] = responseData.body
                        else {
                            switch (data as? Network.BatchSubResponse<[Failable<Network.SOGS.Message>]>)?.code {
                                case 404: Log.error(.poller, "\(pollerName) failed to retrieve messages for unknown room '\(roomToken)'.")
                                default: Log.error(.poller, "\(pollerName) failed due to invalid messages data.")
                            }
                            return false
                        }
                        
                        let successfulMessages: [Network.SOGS.Message] = responseBody.compactMap { $0.value }
                        rawMessageCount += successfulMessages.count
                        
                        if successfulMessages.count != responseBody.count {
                            let droppedCount: Int = (responseBody.count - successfulMessages.count)
                            invalidMessageCount += droppedCount
                            
                            Log.info(.poller, "\(pollerName) dropped \(droppedCount) invalid open group message(s).")
                        }
                        
                        return !successfulMessages.isEmpty
                        
                    case .inbox, .inboxSince, .outbox, .outboxSince:
                        guard
                            let responseData: Network.BatchSubResponse<[Network.SOGS.DirectMessage]?> = data as? Network.BatchSubResponse<[Network.SOGS.DirectMessage]?>,
                            !responseData.failedToParseBody
                        else {
                            Log.error(.poller, "\(pollerName) failed due to invalid inbox/outbox data.")
                            return false
                        }
                        
                        // Double optional because the server can return a `304` with an empty body
                        let messages: [Network.SOGS.DirectMessage] = ((responseData.body ?? []) ?? [])
                        rawMessageCount += messages.count
                        
                        return !messages.isEmpty
                        
                    default: return false // No custom handling needed
                }
            }
        let roomsUserLikelyBannedFrom: Set<String> = response.data.reduce(into: []) { result, next in
            switch next.key {
                case .roomPollInfo(let roomToken, _):
                    guard (next.value as? Network.BatchSubResponse<Network.SOGS.RoomPollInfo>)?.code == 403 else {
                        return
                    }
                    
                    result.insert(roomToken)
                    
                default: break
            }
        }
        
        // If there are no remaining 'validResponses' and there hasn't been a failure then there is
        // no need to do anything else
        guard !validResponses.isEmpty || !roomsUserLikelyBannedFrom.isEmpty || failureCount != 0 else {
            return PollResult(
                response: (info, response),
                rawMessageCount: rawMessageCount,
                validMessageCount: 0,
                invalidMessageCount: invalidMessageCount,
                hadValidHashUpdate: false
            )
        }

        // Retrieve the current capability & group info to check if anything changed
        let rooms: [String] = validResponses
            .keys
            .compactMap { endpoint -> String? in
                switch endpoint {
                    case .roomPollInfo(let roomToken, _): return roomToken
                    default: return nil
                }
            }
            .appending(contentsOf: Array(roomsUserLikelyBannedFrom))
        
        let currentInfo: (capabilities: Network.SOGS.CapabilitiesResponse, groups: [OpenGroup]) = (
            Network.SOGS.CapabilitiesResponse(
                capabilities: server.capabilities.map { $0.rawValue },
                missing: (server.missingCapabilities.isEmpty ? nil :
                    server.missingCapabilities.map { $0.rawValue }
                )
            ),
            rooms.compactMap { roomToken in
                server.openGroup(
                    roomToken: roomToken,
                    shouldPoll: true,
                    displayPictureOriginalUrl: nil
                )
            }
        )
        let changedResponses: [Network.SOGS.Endpoint: Any] = validResponses.filter { endpoint, data in
            switch endpoint {
                case .capabilities:
                    guard
                        let responseData: Network.BatchSubResponse<Network.SOGS.CapabilitiesResponse> = data as? Network.BatchSubResponse<Network.SOGS.CapabilitiesResponse>,
                        let responseBody: Network.SOGS.CapabilitiesResponse = responseData.body
                    else { return false }
                    
                    return (responseBody != currentInfo.capabilities)
                    
                case .roomPollInfo(let roomToken, _):
                    guard
                        let responseData: Network.BatchSubResponse<Network.SOGS.RoomPollInfo> = data as? Network.BatchSubResponse<Network.SOGS.RoomPollInfo>,
                        let responseBody: Network.SOGS.RoomPollInfo = responseData.body
                    else { return false }
                    guard let existingOpenGroup: OpenGroup = currentInfo.groups.first(where: { $0.roomToken == roomToken }) else {
                        return true
                    }
                    
                    return (
                        responseBody.activeUsers != existingOpenGroup.userCount || (
                            responseBody.details != nil &&
                            responseBody.details?.infoUpdates != existingOpenGroup.infoUpdates
                        ) ||
                        OpenGroup.Permissions(roomInfo: responseBody) != existingOpenGroup.permissions
                    )
                
                default: return true
            }
        }
        let roomsNeedingBannedPermissionChange: [String] = roomsUserLikelyBannedFrom.filter { roomToken in
            guard let existingOpenGroup: OpenGroup = currentInfo.groups.first(where: { $0.roomToken == roomToken }) else {
                return true
            }
            
            return !(existingOpenGroup.permissions ?? .noPermissions).isEmpty
        }
        
        /// If there are no `changedResponses`, no potentially banned rooms, and there hasn't been a failure then there is no need
        /// to do anything else
        guard !changedResponses.isEmpty || !roomsNeedingBannedPermissionChange.isEmpty || failureCount != 0 else {
            return PollResult(
                response: (info, response),
                rawMessageCount: rawMessageCount,
                validMessageCount: 0,
                invalidMessageCount: invalidMessageCount,
                hadValidHashUpdate: true
            )
        }
                
        return try await dependencies[singleton: .storage].write { [destination, manager = dependencies[singleton: .communityManager]] db -> PollResult in
            /// Reset the failure count
            if failureCount > 0 {
                try OpenGroup
                    .filter(OpenGroup.Columns.server == destination.target)
                    .updateAll(db, OpenGroup.Columns.pollFailureCount.set(to: 0))
                
                /// Update the `CommunityManager` cache
                db.afterCommit {
                    Task.detached(priority: .userInitiated) {
                        await manager.updatePollFailureCount(0, server: destination.target)
                    }
                }
            }
            
            /// An update to `capabilities` could affect the values on our `server` instance so we should handle it's response
            /// first and update our local copy so we have the latest value for handling other responses
            var updatedServer: CommunityManager.Server = server
            
            if
                let capabilitiesResponse: Network.BatchSubResponse<Network.SOGS.CapabilitiesResponse> = changedResponses[.capabilities] as? Network.BatchSubResponse<Network.SOGS.CapabilitiesResponse>,
                let capabilitiesResponseBody: Network.SOGS.CapabilitiesResponse = capabilitiesResponse.body
            {
                manager.handleCapabilities(
                    db,
                    capabilities: capabilitiesResponseBody,
                    server: destination.target,
                    publicKey: server.publicKey
                )
                
                let newCapabilities: Set<Capability.Variant> = Set(capabilitiesResponseBody.capabilities
                    .map { Capability.Variant(from: $0) })
                
                if updatedServer.capabilities != newCapabilities {
                    updatedServer = updatedServer.with(
                        capabilities: .set(to: newCapabilities),
                        using: dependencies
                    )
                }
            }
            
            /// Now we can handle the other responses
            var interactionInfo: [MessageReceiver.InsertedInteractionInfo?] = []
            try changedResponses.forEach { endpoint, data in
                switch endpoint {
                    case .capabilities: break   /// Handled above
                    case .roomPollInfo(let roomToken, _):
                        guard
                            let responseData: Network.BatchSubResponse<Network.SOGS.RoomPollInfo> = data as? Network.BatchSubResponse<Network.SOGS.RoomPollInfo>,
                            let responseBody: Network.SOGS.RoomPollInfo = responseData.body
                        else { return }
                        
                        try manager.handlePollInfo(
                            db,
                            pollInfo: responseBody,
                            server: destination.target,
                            roomToken: roomToken,
                            publicKey: server.publicKey
                        )
                        
                    case .roomMessagesRecent(let roomToken), .roomMessagesBefore(let roomToken, _), .roomMessagesSince(let roomToken, _):
                        guard
                            let responseData: Network.BatchSubResponse<[Failable<Network.SOGS.Message>]> = data as? Network.BatchSubResponse<[Failable<Network.SOGS.Message>]>,
                            let responseBody: [Failable<Network.SOGS.Message>] = responseData.body
                        else { return }
                        
                        interactionInfo.append(
                            contentsOf: manager.handleMessages(
                                db,
                                messages: responseBody.compactMap { $0.value },
                                server: destination.target,
                                roomToken: roomToken,
                                currentUserSessionIds: updatedServer.currentUserSessionIds
                            )
                        )
                        
                    case .inbox, .inboxSince, .outbox, .outboxSince:
                        guard
                            let responseData: Network.BatchSubResponse<[Network.SOGS.DirectMessage]?> = data as? Network.BatchSubResponse<[Network.SOGS.DirectMessage]?>,
                            !responseData.failedToParseBody
                        else { return }
                        
                        // Double optional because the server can return a `304` with an empty body
                        let messages: [Network.SOGS.DirectMessage] = ((responseData.body ?? []) ?? [])
                        let fromOutbox: Bool = {
                            switch endpoint {
                                case .outbox, .outboxSince: return true
                                default: return false
                            }
                        }()
                        
                        interactionInfo.append(
                            contentsOf: manager.handleDirectMessages(
                                db,
                                messages: messages,
                                fromOutbox: fromOutbox,
                                server: destination.target,
                                currentUserSessionIds: updatedServer.currentUserSessionIds
                            )
                        )
                        
                    default: break // No custom handling needed
                }
            }
            
            // TODO: [Communities] We probably want to revoke the permissions after being banned from a room but for the time being we want to be consistent with Android & Desktop (just fail to send any messages but don't show an error) - Uncomment this when we want to disable the input again
//            /// If we have rooms the user may have been banned from then we should remove their locally cached permissions (we
//            /// won't be able to get updated permissions as banning results in `403` errors when fetching room info)
//            try roomsNeedingBannedPermissionChange.forEach { roomToken in
//                try dependencies[singleton: .communityManager].revokePermissions(
//                    db,
//                    server: destination.target,
//                    roomToken: roomToken
//                )
//            }
            
            /// Notify about the received message
            interactionInfo.forEach { info in
                MessageReceiver.prepareNotificationsForInsertedInteractions(
                    db,
                    insertedInteractionInfo: info,
                    isMessageRequest: {
                        switch (info, info?.threadVariant) {
                            /// These types received via the `CommunityPoller` can't be message requests
                            case (.none, _), (_, .none), (_, .community),
                                (_, .group), (_, .legacyGroup):
                                return false
                            
                            case (.some(let info), .contact):
                                /// Users can send blinded message requests via Communities so we need to handle that case
                                return dependencies.mutate(cache: .libSession) { cache in
                                    cache.isMessageRequest(
                                        threadId: info.threadId,
                                        threadVariant: info.threadVariant
                                    )
                                }
                        }
                    }(),
                    using: dependencies
                )
            }
            
            /// Assume all messages were handled
            return PollResult(
                response: (info, response),
                rawMessageCount: rawMessageCount,
                validMessageCount: rawMessageCount,
                invalidMessageCount: invalidMessageCount,
                hadValidHashUpdate: true
            )
        }
    }
}
                    
// MARK: - Convenience

fileprivate extension Error {
    // stringlint:ignore_contents
    var isMissingBlindedAuthError: Bool {
        guard
            let networkError: NetworkError = self as? NetworkError,
            case .badRequest(let dataString, _) = networkError,
            dataString.contains("Invalid authentication: this server requires the use of blinded ids")
        else { return false }
        
        return true
    }
}

// MARK: - CommunityPoller.Info

public extension CommunityPoller {
    struct Info: Equatable {
        public let server: String
        public let pollFailureCount: Int64
    }
}

// MARK: - CommunityPollerManager

actor CommunityPollerManager: CommunityPollerManagerType {
    private let dependencies: Dependencies
    private var pollers: [String: CommunityPoller] = [:] /// One for each server
    
    nonisolated public let syncState: CommunityPollerManagerSyncState = CommunityPollerManagerSyncState()
    public var serversBeingPolled: Set<String> { Set(pollers.keys) }
    public var allPollers: [any PollerType] { Array(pollers.values) }
    
    // MARK: - Initialization
    
    public init(using dependencies: Dependencies) {
        self.dependencies = dependencies
    }
    
    deinit {
        Task { [pollers] in
            for poller in pollers.values {
                await poller.stop()
            }
        }
    }
    
    // MARK: - Functions
    
    public func startAllPollers() async {
        await dependencies[singleton: .communityManager].loadCacheIfNeeded()
        
        let servers: [CommunityManager.Server] = await dependencies[singleton: .communityManager]
            .servers()
        
        await withTaskGroup(of: Void.self) { group in
            for server in servers {
                /// Only start pollers for servers which have rooms we want to poll (these shouldn't exist but better to check in case
                /// of code changes in the future)
                guard !server.roomsToPoll.isEmpty else { continue }
                
                group.addTask {
                    await self.getOrCreatePoller(
                        for: CommunityPoller.Info(
                            server: server.server,
                            pollFailureCount: server.pollFailureCount
                        )
                    ).startIfNeeded()
                }
            }
        }
    }
    
    @discardableResult public func getOrCreatePoller(for info: CommunityPoller.Info) async -> any PollerType {
        guard let poller: CommunityPoller = pollers[info.server.lowercased()] else {
            let poller: CommunityPoller = CommunityPoller(
                pollerName: "Community poller for: \(info.server)", // stringlint:ignore
                destination: .server(info.server),
                failureCount: Int(info.pollFailureCount),
                shouldStoreMessages: true,
                logStartAndStopCalls: false,
                using: dependencies
            )
            pollers[info.server.lowercased()] = poller
            syncState.update(serversBeingPolled: Set(pollers.keys))
            return poller
        }
        
        return poller
    }

    public func stopAndRemovePoller(for server: String) async {
        await pollers[server.lowercased()]?.stop()
        pollers[server.lowercased()] = nil
        syncState.update(serversBeingPolled: Set(pollers.keys))
    }
    
    public func stopAndRemoveAllPollers() async {
        for poller in pollers.values {
            await poller.stop()
        }
        
        pollers.removeAll()
        syncState.update(serversBeingPolled: Set(pollers.keys))
    }
}

/// We manually handle thread-safety using the `NSLock` so can ensure this is `Sendable`
public final class CommunityPollerManagerSyncState: @unchecked Sendable {
    private let lock = NSLock()
    private var _serversBeingPolled: Set<String>
    
    public init(serversBeingPolled: Set<String> = []) {
        self._serversBeingPolled = serversBeingPolled
    }
    
    public var serversBeingPolled:  Set<String> { lock.withLock { _serversBeingPolled } }

    func update(serversBeingPolled: Set<String>) {
        lock.withLock { self._serversBeingPolled = serversBeingPolled }
    }
}

// MARK: - CommunityPollerManagerType

public protocol CommunityPollerManagerType {
    @available(*, deprecated, message: "Should try to refactor the code to use proper async/await")
    nonisolated var syncState: CommunityPollerManagerSyncState { get }
    var serversBeingPolled: Set<String> { get async }
    var allPollers: [any PollerType] { get async }
    
    func startAllPollers() async
    @discardableResult func getOrCreatePoller(for info: CommunityPoller.Info) async -> any PollerType
    func stopAndRemovePoller(for server: String) async
    func stopAndRemoveAllPollers() async
}

public extension CommunityPollerManagerType {
    @discardableResult func getOrCreatePoller(for server: String) async -> any PollerType {
        return await getOrCreatePoller(for: CommunityPoller.Info(server: server, pollFailureCount: 0))
    }
}

// MARK: - Conformance

extension Network.SOGS.PollRoomInfo: @retroactive FetchableRecord {}
