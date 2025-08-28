// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionNetworkingKit
import SessionUtilitiesKit

// MARK: - Cache

public extension Singleton {
    static let communityPollerManager: SingletonConfig<CommunityPollerManagerType> = Dependencies.create(
        identifier: "communityPollers",
        createInstance: { dependencies in CommunityPollerManager(using: dependencies) }
    )
}

// MARK: - CommunityPoller Convenience

public extension PollerType where PollResponse == CommunityPoller.PollResponse {
    init(
        pollerName: String,
        destination: PollerDestination,
        failureCount: Int = 0,
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
            shouldStoreMessages: shouldStoreMessages,
            logStartAndStopCalls: logStartAndStopCalls,
            customAuthMethod: customAuthMethod,
            using: dependencies
        )
    }
}

// MARK: - CommunityPoller

private typealias Capabilities = OpenGroupAPI.Capabilities

public actor CommunityPoller: PollerType {
    public typealias PollResponse = (
        info: ResponseInfoType,
        data: Network.BatchResponseMap<OpenGroupAPI.Endpoint>
    )
    
    // MARK: - Settings
    
    private static let minPollInterval: TimeInterval = 3
    private static let maxPollInterval: TimeInterval = (60 * 60)
    internal static let maxInactivityPeriod: TimeInterval = (14 * 24 * 60 * 60)
    
    /// If there are hidden rooms that we poll and they fail too many times we want to prune them (as it likely means they no longer
    /// exist, and since they are already hidden it's unlikely that the user will notice that we stopped polling for them)
    internal static let maxHiddenRoomFailureCount: Int64 = 10
    
    /// When doing a background poll we want to only fetch from rooms which are unlikely to timeout, in order to do this we exclude
    /// any rooms which have failed more than this threashold
    public static let maxRoomFailureCountForBackgroundPoll: Int64 = 15
    
    // MARK: - PollerType
    
    public let dependencies: Dependencies
    public let pollerName: String
    public let destination: PollerDestination
    public let logStartAndStopCalls: Bool
    nonisolated public var receivedPollResponse: AsyncStream<PollResponse> { responseStream.stream }
    
    public var pollTask: Task<Void, any Error>?
    public var pollCount: Int = 0
    public var failureCount: Int
    public var lastPollStart: TimeInterval = 0
    public var cancellable: AnyCancellable?
    
    private let shouldStoreMessages: Bool
    nonisolated private let responseStream: CancellationAwareAsyncStream<PollResponse> = CancellationAwareAsyncStream()
    
    // MARK: - Initialization
    
    public init(
        pollerName: String,
        destination: PollerDestination,
        swarmDrainStrategy: SwarmDrainer.Strategy,
        namespaces: [SnodeAPI.Namespace],
        failureCount: Int,
        shouldStoreMessages: Bool,
        logStartAndStopCalls: Bool,
        customAuthMethod: AuthenticationMethod?,
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
        // Send completion events to the observables
        Task { [stream = responseStream] in
            await stream.finishCurrentStreams()
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
        /// We want to custom handle a '400' error code due to not having blinded auth as it likely means that we join the
        /// OpenGroup before blinding was enabled and need to update it's capabilities
        ///
        /// **Note:** To prevent an infinite loop caused by a server-side bug we want to prevent this capabilities request from
        /// happening multiple times in a row
        guard error.isMissingBlindedAuthError else {
            /// Save the updated failure count to the database
            _ = try? await dependencies[singleton: .storage].writeAsync { [destination, failureCount] db in
                try OpenGroup
                    .filter(OpenGroup.Columns.server == destination.target)
                    .updateAll(
                        db,
                        OpenGroup.Columns.pollFailureCount.set(to: failureCount)
                    )
            }
            return
        }
        
        /// Since we have gotten here we should update the SOGS capabilities before triggering the next poll
        do {
            let authMethod: AuthenticationMethod = try await dependencies[singleton: .storage].readAsync { [destination, dependencies] db -> AuthenticationMethod in
                try Authentication.with(
                    db,
                    server: destination.target,
                    forceBlinded: true,
                    using: dependencies
                )
            }
            let request: Network.PreparedRequest<OpenGroupAPI.Capabilities> = try OpenGroupAPI.preparedCapabilities(
                authMethod: authMethod,
                using: dependencies
            )
            let response: OpenGroupAPI.Capabilities = try await request.send(using: dependencies)
            
            try await dependencies[singleton: .storage].writeAsync { [destination] db in
                OpenGroupManager.handleCapabilities(
                    db,
                    capabilities: response,
                    on: destination.target
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
                _ = try? await dependencies[singleton: .storage].writeAsync { [destination, failureCount] db in
                    try OpenGroup
                        .filter(OpenGroup.Columns.server == destination.target)
                        .updateAll(
                            db,
                            OpenGroup.Columns.pollFailureCount.set(to: failureCount)
                        )
                }
                return
            }
            
            let hiddenRoomIds: [String]? = try? await dependencies[singleton: .storage].writeAsync { [destination, failureCount, dependencies] db -> [String] in
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
                        OpenGroup.Columns.isActive == true
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
                    try dependencies[singleton: .openGroupManager].delete(
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
        await responseStream.send(response)
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
        typealias PollInfo = (
            roomInfo: [OpenGroupAPI.RoomInfo],
            lastInboxMessageId: Int64,
            lastOutboxMessageId: Int64,
            authMethod: AuthenticationMethod
        )
        typealias APIValue = Network.BatchResponseMap<OpenGroupAPI.Endpoint>
        let lastSuccessfulPollTimestamp: TimeInterval = (self.lastPollStart > 0 ?
            lastPollStart :
            dependencies.mutate(cache: .openGroupManager) { cache in
                cache.getLastSuccessfulCommunityPollTimestamp()
            }
        )
        
        let pollInfo: PollInfo = try await dependencies[singleton: .storage].readAsync { [destination, dependencies] db in
            /// **Note:** The `OpenGroup` type converts to lowercase in init
            let server: String = destination.target.lowercased()
            let roomInfo: [OpenGroupAPI.RoomInfo] = try OpenGroup
                .select(.roomToken, .infoUpdates, .sequenceNumber)
                .filter(OpenGroup.Columns.server == server)
                .filter(OpenGroup.Columns.isActive == true)
                .filter(OpenGroup.Columns.roomToken != "")
                .asRequest(of: OpenGroupAPI.RoomInfo.self)
                .fetchAll(db)
            
            guard !roomInfo.isEmpty else { throw OpenGroupAPIError.invalidPoll }
            
            return (
                roomInfo,
                (try? OpenGroup
                    .select(.inboxLatestMessageId)
                    .filter(OpenGroup.Columns.server == server)
                    .asRequest(of: Int64.self)
                    .fetchOne(db))
                    .defaulting(to: 0),
                (try? OpenGroup
                    .select(.outboxLatestMessageId)
                    .filter(OpenGroup.Columns.server == server)
                    .asRequest(of: Int64.self)
                    .fetchOne(db))
                    .defaulting(to: 0),
                try Authentication.with(db, server: server, using: dependencies)
            )
        }
        let request: Network.PreparedRequest<APIValue> = try OpenGroupAPI.preparedPoll(
            roomInfo: pollInfo.roomInfo,
            lastInboxMessageId: pollInfo.lastInboxMessageId,
            lastOutboxMessageId: pollInfo.lastOutboxMessageId,
            hasPerformedInitialPoll: (pollCount > 0),
            timeSinceLastPoll: (dependencies.dateNow.timeIntervalSince1970 - lastSuccessfulPollTimestamp),
            authMethod: pollInfo.authMethod,
            using: dependencies
        )
        let response: (info: ResponseInfoType, value: APIValue) = try await request.send(using: dependencies)
        let result: PollResult<PollResponse> = try await handlePollResponse(
            info: response.info,
            response: response.value,
            failureCount: failureCount,
            using: dependencies
        )
        pollCount += 1
        dependencies.mutate(cache: .openGroupManager) { cache in
            cache.setLastSuccessfulCommunityPollTimestamp(
                dependencies.dateNow.timeIntervalSince1970
            )
        }
        
        return result
    }
    
    private func handlePollResponse(
        info: ResponseInfoType,
        response: Network.BatchResponseMap<OpenGroupAPI.Endpoint>,
        failureCount: Int,
        using dependencies: Dependencies
    ) async throws -> PollResult<PollResponse> {
        var rawMessageCount: Int = 0
        let validResponses: [OpenGroupAPI.Endpoint: Any] = response.data
            .filter { endpoint, data in
                switch endpoint {
                    case .capabilities:
                        guard (data as? Network.BatchSubResponse<Capabilities>)?.body != nil else {
                            Log.error(.poller, "\(pollerName) failed due to invalid capability data.")
                            return false
                        }
                        
                        return true
                        
                    case .roomPollInfo(let roomToken, _):
                        guard (data as? Network.BatchSubResponse<OpenGroupAPI.RoomPollInfo>)?.body != nil else {
                            switch (data as? Network.BatchSubResponse<OpenGroupAPI.RoomPollInfo>)?.code {
                                case 404: Log.error(.poller, "\(pollerName) failed to retrieve info for unknown room '\(roomToken)'.")
                                default: Log.error(.poller, "\(pollerName) failed due to invalid room info data.")
                            }
                            return false
                        }
                        
                        return true
                        
                    case .roomMessagesRecent(let roomToken), .roomMessagesBefore(let roomToken, _), .roomMessagesSince(let roomToken, _):
                        guard
                            let responseData: Network.BatchSubResponse<[Failable<OpenGroupAPI.Message>]> = data as? Network.BatchSubResponse<[Failable<OpenGroupAPI.Message>]>,
                            let responseBody: [Failable<OpenGroupAPI.Message>] = responseData.body
                        else {
                            switch (data as? Network.BatchSubResponse<[Failable<OpenGroupAPI.Message>]>)?.code {
                                case 404: Log.error(.poller, "\(pollerName) failed to retrieve messages for unknown room '\(roomToken)'.")
                                default: Log.error(.poller, "\(pollerName) failed due to invalid messages data.")
                            }
                            return false
                        }
                        
                        let successfulMessages: [OpenGroupAPI.Message] = responseBody.compactMap { $0.value }
                        rawMessageCount += successfulMessages.count
                        
                        if successfulMessages.count != responseBody.count {
                            let droppedCount: Int = (responseBody.count - successfulMessages.count)
                            
                            Log.info(.poller, "\(pollerName) dropped \(droppedCount) invalid open group message(s).")
                        }
                        
                        return !successfulMessages.isEmpty
                        
                    case .inbox, .inboxSince, .outbox, .outboxSince:
                        guard
                            let responseData: Network.BatchSubResponse<[OpenGroupAPI.DirectMessage]?> = data as? Network.BatchSubResponse<[OpenGroupAPI.DirectMessage]?>,
                            !responseData.failedToParseBody
                        else {
                            Log.error(.poller, "\(pollerName) failed due to invalid inbox/outbox data.")
                            return false
                        }
                        
                        // Double optional because the server can return a `304` with an empty body
                        let messages: [OpenGroupAPI.DirectMessage] = ((responseData.body ?? []) ?? [])
                        rawMessageCount += messages.count
                        
                        return !messages.isEmpty
                        
                    default: return false // No custom handling needed
                }
            }
        
        // If there are no remaining 'validResponses' and there hasn't been a failure then there is
        // no need to do anything else
        guard !validResponses.isEmpty || failureCount != 0 else {
            return PollResult((info, response), rawMessageCount, 0, true)
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
        let currentInfo: (capabilities: OpenGroupAPI.Capabilities, groups: [OpenGroup]) = try await dependencies[singleton: .storage].readAsync { [destination] db in
            let allCapabilities: [Capability] = try Capability
                .filter(Capability.Columns.openGroupServer == destination.target)
                .fetchAll(db)
            let capabilities: OpenGroupAPI.Capabilities = OpenGroupAPI.Capabilities(
                capabilities: allCapabilities
                    .filter { !$0.isMissing }
                    .map { $0.variant },
                missing: {
                    let missingCapabilities: [Capability.Variant] = allCapabilities
                        .filter { $0.isMissing }
                        .map { $0.variant }
                    
                    return (missingCapabilities.isEmpty ? nil : missingCapabilities)
                }()
            )
            let openGroupIds: [String] = rooms
                .map { OpenGroup.idFor(roomToken: $0, server: destination.target) }
            let groups: [OpenGroup] = try OpenGroup
                .filter(ids: openGroupIds)
                .fetchAll(db)
            
            return (capabilities, groups)
        }
        
        let changedResponses: [OpenGroupAPI.Endpoint: Any] = validResponses.filter { endpoint, data in
            switch endpoint {
                case .capabilities:
                    guard
                        let responseData: Network.BatchSubResponse<OpenGroupAPI.Capabilities> = data as? Network.BatchSubResponse<OpenGroupAPI.Capabilities>,
                        let responseBody: OpenGroupAPI.Capabilities = responseData.body
                    else { return false }
                    
                    return (responseBody != currentInfo.capabilities)
                    
                case .roomPollInfo(let roomToken, _):
                    guard
                        let responseData: Network.BatchSubResponse<OpenGroupAPI.RoomPollInfo> = data as? Network.BatchSubResponse<OpenGroupAPI.RoomPollInfo>,
                        let responseBody: OpenGroupAPI.RoomPollInfo = responseData.body
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
        
        // If there are no 'changedResponses' and there hasn't been a failure then there is
        // no need to do anything else
        guard !changedResponses.isEmpty || failureCount != 0 else {
            return PollResult((info, response), rawMessageCount, 0, true)
        }
        
        return try await dependencies[singleton: .storage].writeAsync { [destination] db -> PollResult<PollResponse> in
            // Reset the failure count
            if failureCount > 0 {
                try OpenGroup
                    .filter(OpenGroup.Columns.server == destination.target)
                    .updateAll(db, OpenGroup.Columns.pollFailureCount.set(to: 0))
            }
            
            var interactionInfo: [MessageReceiver.InsertedInteractionInfo?] = []
            try changedResponses.forEach { endpoint, data in
                switch endpoint {
                    case .capabilities:
                        guard
                            let responseData: Network.BatchSubResponse<OpenGroupAPI.Capabilities> = data as? Network.BatchSubResponse<OpenGroupAPI.Capabilities>,
                            let responseBody: OpenGroupAPI.Capabilities = responseData.body
                        else { return }
                        
                        OpenGroupManager.handleCapabilities(
                            db,
                            capabilities: responseBody,
                            on: destination.target
                        )
                        
                    case .roomPollInfo(let roomToken, _):
                        guard
                            let responseData: Network.BatchSubResponse<OpenGroupAPI.RoomPollInfo> = data as? Network.BatchSubResponse<OpenGroupAPI.RoomPollInfo>,
                            let responseBody: OpenGroupAPI.RoomPollInfo = responseData.body
                        else { return }
                        
                        try OpenGroupManager.handlePollInfo(
                            db,
                            pollInfo: responseBody,
                            publicKey: nil,
                            for: roomToken,
                            on: destination.target,
                            using: dependencies
                        )
                        
                    case .roomMessagesRecent(let roomToken), .roomMessagesBefore(let roomToken, _), .roomMessagesSince(let roomToken, _):
                        guard
                            let responseData: Network.BatchSubResponse<[Failable<OpenGroupAPI.Message>]> = data as? Network.BatchSubResponse<[Failable<OpenGroupAPI.Message>]>,
                            let responseBody: [Failable<OpenGroupAPI.Message>] = responseData.body
                        else { return }
                        
                        interactionInfo.append(
                            contentsOf: OpenGroupManager.handleMessages(
                                db,
                                messages: responseBody.compactMap { $0.value },
                                for: roomToken,
                                on: destination.target,
                                using: dependencies
                            )
                        )
                        
                    case .inbox, .inboxSince, .outbox, .outboxSince:
                        guard
                            let responseData: Network.BatchSubResponse<[OpenGroupAPI.DirectMessage]?> = data as? Network.BatchSubResponse<[OpenGroupAPI.DirectMessage]?>,
                            !responseData.failedToParseBody
                        else { return }
                        
                        // Double optional because the server can return a `304` with an empty body
                        let messages: [OpenGroupAPI.DirectMessage] = ((responseData.body ?? []) ?? [])
                        let fromOutbox: Bool = {
                            switch endpoint {
                                case .outbox, .outboxSince: return true
                                default: return false
                            }
                        }()
                        
                        interactionInfo.append(
                            contentsOf: OpenGroupManager.handleDirectMessages(
                                db,
                                messages: messages,
                                fromOutbox: fromOutbox,
                                on: destination.target,
                                using: dependencies
                            )
                        )
                        
                    default: break // No custom handling needed
                }
            }
            
            /// Notify about the received message
            interactionInfo.forEach { info in
                MessageReceiver.prepareNotificationsForInsertedInteractions(
                    db,
                    insertedInteractionInfo: info,
                    isMessageRequest: false,    /// Communities can't be message requests
                    using: dependencies
                )
            }
            
            /// Assume all messages were handled
            return PollResult((info, response), rawMessageCount, rawMessageCount, true)
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

// MARK: - CommunityPollerManager

public extension CommunityPoller {
    struct Info: Equatable, FetchableRecord, Decodable, ColumnExpressible {
        public typealias Columns = CodingKeys
        public enum CodingKeys: String, CodingKey, ColumnExpression {
            case server
            case pollFailureCount
        }
        
        public let server: String
        public let pollFailureCount: Int64
    }
}

// MARK: - CommunityPollerManager
    
actor CommunityPollerManager: CommunityPollerManagerType {
    private let dependencies: Dependencies
    private var pollers: [String: CommunityPoller] = [:] // One for each server
    
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
        Task {
            let communityInfo: [CommunityPoller.Info] = try await dependencies[singleton: .storage].readAsync { db in
                // The default room promise creates an OpenGroup with an empty `roomToken` value,
                // we don't want to start a poller for this as the user hasn't actually joined a room
                try OpenGroup
                    .select(
                        OpenGroup.Columns.server,
                        max(OpenGroup.Columns.pollFailureCount).forKey(CommunityPoller.Info.Columns.pollFailureCount)
                    )
                    .filter(OpenGroup.Columns.isActive == true)
                    .filter(OpenGroup.Columns.roomToken != "")
                    .group(OpenGroup.Columns.server)
                    .asRequest(of: CommunityPoller.Info.self)
                    .fetchAll(db)
            }
            
            for info in communityInfo {
                await getOrCreatePoller(for: info).startIfNeeded()
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
    private var _serversBeingPolled: Set<String> = []
    
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

extension OpenGroupAPI.RoomInfo: FetchableRecord {}
