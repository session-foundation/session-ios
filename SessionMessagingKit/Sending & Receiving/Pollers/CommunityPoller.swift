// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionUIKit
import SessionNetworkingKit
import SessionUtilitiesKit

// MARK: - Cache

public extension Cache {
    static let communityPollers: CacheConfig<CommunityPollerCacheType, CommunityPollerImmutableCacheType> = Dependencies.create(
        identifier: "communityPollers",
        createInstance: { dependencies in CommunityPoller.Cache(using: dependencies) },
        mutableInstance: { $0 },
        immutableInstance: { $0 }
    )
}

// MARK: - CommunityPollerType

public protocol CommunityPollerType {
    typealias PollResponse = (info: ResponseInfoType, data: Network.BatchResponseMap<Network.SOGS.Endpoint>)
    
    var isPolling: Bool { get }
    nonisolated var receivedPollResponse: AsyncStream<PollResponse> { get }
    
    func startIfNeeded()
    func stop()
}

// MARK: - CommunityPoller

private typealias Capabilities = Network.SOGS.CapabilitiesResponse

public final class CommunityPoller: CommunityPollerType & PollerType {
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
    public let pollerQueue: DispatchQueue
    public let pollerName: String
    public let pollerDestination: PollerDestination
    public let logStartAndStopCalls: Bool
    nonisolated public var receivedPollResponse: AsyncStream<PollResponse> { responseStream.stream }
    nonisolated public var successfulPollCount: AsyncStream<Int> { pollCountStream.stream }
    
    public var isPolling: Bool = false
    public var pollCount: Int = 0
    public var failureCount: Int
    public var lastPollStart: TimeInterval = 0
    public var cancellable: AnyCancellable?
    
    private let shouldStoreMessages: Bool
    nonisolated private let responseStream: CancellationAwareAsyncStream<PollResponse> = CancellationAwareAsyncStream()
    nonisolated private let pollCountStream: CurrentValueAsyncStream<Int> = CurrentValueAsyncStream(0)
    
    // MARK: - Initialization
    
    required public init(
        pollerName: String,
        pollerQueue: DispatchQueue,
        pollerDestination: PollerDestination,
        pollerDrainBehaviour: ThreadSafeObject<SwarmDrainBehaviour> = .alwaysRandom,
        namespaces: [Network.SnodeAPI.Namespace] = [],
        failureCount: Int,
        shouldStoreMessages: Bool,
        logStartAndStopCalls: Bool,
        customAuthMethod: AuthenticationMethod? = nil,
        using dependencies: Dependencies
    ) {
        self.dependencies = dependencies
        self.pollerName = pollerName
        self.pollerQueue = pollerQueue
        self.pollerDestination = pollerDestination
        self.failureCount = failureCount
        self.shouldStoreMessages = shouldStoreMessages
        self.logStartAndStopCalls = logStartAndStopCalls
    }
    
    deinit {
        // Send completion events to the observables
        Task { [stream = responseStream] in
            await stream.finishCurrentStreams()
        }
    }
    
    // MARK: - Abstract Methods

    public func nextPollDelay() -> AnyPublisher<TimeInterval, Error> {
        // Arbitrary backoff factor...
        return Just(min(CommunityPoller.maxPollInterval, CommunityPoller.minPollInterval + pow(2, Double(failureCount))))
            .setFailureType(to: Error.self)
            .eraseToAnyPublisher()
    }
    
    public func handlePollError(_ error: Error, _ lastError: Error?) -> PollerErrorResponse {
        /// We want to custom handle a '400' error code due to not having blinded auth as it likely means that we join the
        /// OpenGroup before blinding was enabled and need to update it's capabilities
        ///
        /// **Note:** To prevent an infinite loop caused by a server-side bug we want to prevent this capabilities request from
        /// happening multiple times in a row
        switch (error.isMissingBlindedAuthError, lastError?.isMissingBlindedAuthError) {
            case (true, .none), (true, false): break
            default:
                /// Save the updated failure count to the database
                dependencies[singleton: .storage].writeAsync { [pollerDestination, failureCount] db in
                    try OpenGroup
                        .filter(OpenGroup.Columns.server == pollerDestination.target)
                        .updateAll(
                            db,
                            OpenGroup.Columns.pollFailureCount.set(to: failureCount + 1)
                        )
                }
                return .continuePolling
        }
        
        func handleError(_ error: Error) throws -> AnyPublisher<Void, Error> {
            /// Log the error first
            Log.error(.poller, "\(pollerName) failed to update capabilities due to error: \(error).")
            
            /// If the polling has failed 10+ times then try to prune any invalid rooms that
            /// aren't visible (they would have been added via config messages and will
            /// likely always fail but the user has no way to delete them)
            guard (failureCount + 1) > CommunityPoller.maxHiddenRoomFailureCount else {
                /// Save the updated failure count to the database
                dependencies[singleton: .storage].writeAsync { [pollerDestination, failureCount] db in
                    try OpenGroup
                        .filter(OpenGroup.Columns.server == pollerDestination.target)
                        .updateAll(
                            db,
                            OpenGroup.Columns.pollFailureCount.set(to: failureCount + 1)
                        )
                }
                
                throw error
            }
            
            return dependencies[singleton: .storage]
                .writePublisher { [pollerDestination, failureCount, dependencies] db -> [String] in
                    /// Save the updated failure count to the database
                    try OpenGroup
                        .filter(OpenGroup.Columns.server == pollerDestination.target)
                        .updateAll(
                            db,
                            OpenGroup.Columns.pollFailureCount.set(to: failureCount + 1)
                        )
                    
                    /// Prune any hidden rooms
                    let roomIds: Set<String> = try OpenGroup
                        .filter(
                            OpenGroup.Columns.server == pollerDestination.target &&
                            OpenGroup.Columns.shouldPoll == true
                        )
                        .select(.roomToken)
                        .asRequest(of: String.self)
                        .fetchSet(db)
                        .map { OpenGroup.idFor(roomToken: $0, server: pollerDestination.target) }
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
                .handleEvents(
                    receiveOutput: { [pollerName, pollerDestination] hiddenRoomIds in
                        guard !hiddenRoomIds.isEmpty else { return }
                        
                        // Add a note to the logs that this happened
                        let rooms: String = hiddenRoomIds
                            .sorted()
                            .compactMap { $0.components(separatedBy: pollerDestination.target).last }
                            .joined(separator: ", ")
                        Log.error(.poller, "\(pollerName) failure count surpassed \(CommunityPoller.maxHiddenRoomFailureCount), removed hidden rooms [\(rooms)].")
                    }
                )
                .map { _ in () }
                .eraseToAnyPublisher()
        }
        
        /// Since we have gotten here we should update the SOGS capabilities before triggering the next poll
        cancellable = dependencies[singleton: .storage]
            .readPublisher { [pollerDestination, dependencies] db -> AuthenticationMethod in
                try Authentication.with(
                    db,
                    server: pollerDestination.target,
                    forceBlinded: true,
                    using: dependencies
                )
            }
            .subscribe(on: pollerQueue, using: dependencies)
            .receive(on: pollerQueue, using: dependencies)
            .tryMap { [dependencies] authMethod in
                (
                    authMethod,
                    try Network.SOGS.preparedCapabilities(
                        authMethod: authMethod,
                        using: dependencies
                    )
                )
            }
            .flatMap { [dependencies] authMethod, request in
                request.send(using: dependencies).map { ($0.0, $0.1, authMethod) }
            }
            .flatMapStorageWritePublisher(using: dependencies) { [pollerDestination, dependencies] (db: ObservingDatabase, response: (info: ResponseInfoType, data: Network.SOGS.CapabilitiesResponse, authMethod: AuthenticationMethod)) in
                guard case .community(_, let publicKey, _, _, _) = response.authMethod.info else {
                    throw CryptoError.invalidAuthentication
                }
                
                dependencies[singleton: .communityManager].handleCapabilities(
                    db,
                    capabilities: response.data,
                    server: pollerDestination.target,
                    publicKey: publicKey
                )
            }
            .tryCatch { try handleError($0) }
            .asResult()
            .flatMapOptional { [weak self] _ in self?.nextPollDelay() }
            .sink(
                receiveCompletion: { _ in },    // Never called
                receiveValue: { [weak self, pollerQueue, dependencies] nextPollDelay in
                    let nextPollInterval: TimeUnit = .seconds(nextPollDelay)
                    
                    // Schedule the next poll
                    pollerQueue.asyncAfter(deadline: .now() + .milliseconds(Int(nextPollInterval.timeInterval * 1000)), qos: .default, using: dependencies) {
                        self?.pollRecursively(error)
                    }
                }
            )
        
            /// Stop polling at this point (we will resume once the above publisher completes
            return .stopPolling
    }

    // MARK: - Polling
    
    public func pollerDidStart() {}
    
    /// Polls based on it's configuration and processes any messages, returning an array of messages that were
    /// successfully processed
    ///
    /// **Note:** The returned messages will have already been processed by the `Poller`, they are only returned
    /// for cases where we need explicit/custom behaviours to occur (eg. Onboarding)
    public func poll(forceSynchronousProcessing: Bool = false) -> AnyPublisher<PollResult, Error> {
        typealias PollInfo = (
            roomInfo: [Network.SOGS.PollRoomInfo],
            lastInboxMessageId: Int64,
            lastOutboxMessageId: Int64,
            authMethod: AuthenticationMethod
        )
        let lastSuccessfulPollTimestamp: TimeInterval = (self.lastPollStart > 0 ?
            lastPollStart :
            dependencies[singleton: .communityManager].getLastSuccessfulCommunityPollTimestampSync()
        )
        
        return dependencies[singleton: .storage]
            .readPublisher { [pollerDestination, dependencies] db -> PollInfo in
                /// **Note:** The `OpenGroup` type converts to lowercase in init
                let server: String = pollerDestination.target.lowercased()
                let roomInfo: [Network.SOGS.PollRoomInfo] = try OpenGroup
                    .select(.roomToken, .infoUpdates, .sequenceNumber)
                    .filter(OpenGroup.Columns.server == server)
                    .filter(OpenGroup.Columns.shouldPoll == true)
                    .asRequest(of: Network.SOGS.PollRoomInfo.self)
                    .fetchAll(db)
                
                guard !roomInfo.isEmpty else { throw SOGSError.invalidPoll }
                
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
            .tryFlatMap { [pollCount, dependencies] pollInfo -> AnyPublisher<(ResponseInfoType, Network.BatchResponseMap<Network.SOGS.Endpoint>, AuthenticationMethod), Error> in
                try Network.SOGS
                    .preparedPoll(
                        roomInfo: pollInfo.roomInfo,
                        lastInboxMessageId: pollInfo.lastInboxMessageId,
                        lastOutboxMessageId: pollInfo.lastOutboxMessageId,
                        checkForCommunityMessageRequests: dependencies.mutate(cache: .libSession) {
                            $0.get(.checkForCommunityMessageRequests)
                        },
                        hasPerformedInitialPoll: (pollCount > 0),
                        timeSinceLastPoll: (dependencies.dateNow.timeIntervalSince1970 - lastSuccessfulPollTimestamp),
                        authMethod: pollInfo.authMethod,
                        using: dependencies
                    )
                    .send(using: dependencies)
                    .map { ($0.0, $0.1, pollInfo.authMethod) }
                    .eraseToAnyPublisher()
            }
            .tryFlatMapOptional { [weak self, failureCount, dependencies] info, response, authMethod in
                guard case .community(_, let publicKey, _, _, _) = authMethod.info else {
                    throw CryptoError.invalidAuthentication
                }
                
                return self?.handlePollResponse(
                    info: info,
                    response: response,
                    publicKey: publicKey,
                    failureCount: failureCount,
                    using: dependencies
                )
            }
            .handleEvents(
                receiveOutput: { [weak self, dependencies] _ in
                    let updatedPollCount: Int = ((self?.pollCount ?? 0) + 1)
                    self?.pollCount = updatedPollCount
                    
                    Task { [weak self] in
                        await self?.pollCountStream.send(updatedPollCount)
                        await dependencies[singleton: .communityManager].setLastSuccessfulCommunityPollTimestamp(
                            dependencies.dateNow.timeIntervalSince1970
                        )
                    }
                }
            )
            .eraseToAnyPublisher()
    }
    
    private func handlePollResponse(
        info: ResponseInfoType,
        response: Network.BatchResponseMap<Network.SOGS.Endpoint>,
        publicKey: String,
        failureCount: Int,
        using dependencies: Dependencies
    ) -> AnyPublisher<PollResult, Error> {
        var rawMessageCount: Int = 0
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
        
        // If there are no remaining 'validResponses' and there hasn't been a failure then there is
        // no need to do anything else
        guard !validResponses.isEmpty || failureCount != 0 else {
            return Just(((info, response), rawMessageCount, 0, true))
                .setFailureType(to: Error.self)
                .eraseToAnyPublisher()
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
        
        return dependencies[singleton: .storage]
            .readPublisher { [pollerDestination] db -> (capabilities: Network.SOGS.CapabilitiesResponse, groups: [OpenGroup]) in
                let allCapabilities: [Capability] = try Capability
                    .filter(Capability.Columns.openGroupServer == pollerDestination.target)
                    .fetchAll(db)
                let capabilities: Network.SOGS.CapabilitiesResponse = Network.SOGS.CapabilitiesResponse(
                    capabilities: allCapabilities
                        .filter { !$0.isMissing }
                        .map { $0.variant.rawValue },
                    missing: {
                        let missingCapabilities: [String] = allCapabilities
                            .filter { $0.isMissing }
                            .map { $0.variant.rawValue }
                        
                        return (missingCapabilities.isEmpty ? nil : missingCapabilities)
                    }()
                )
                let openGroupIds: [String] = rooms
                    .map { OpenGroup.idFor(roomToken: $0, server: pollerDestination.target) }
                let groups: [OpenGroup] = try OpenGroup
                    .filter(ids: openGroupIds)
                    .fetchAll(db)
                
                return (capabilities, groups)
            }
            .flatMap { [pollerDestination, dependencies] (capabilities: Network.SOGS.CapabilitiesResponse, groups: [OpenGroup]) -> AnyPublisher<PollResult, Error> in
                let changedResponses: [Network.SOGS.Endpoint: Any] = validResponses
                    .filter { endpoint, data in
                        switch endpoint {
                            case .capabilities:
                                guard
                                    let responseData: Network.BatchSubResponse<Network.SOGS.CapabilitiesResponse> = data as? Network.BatchSubResponse<Network.SOGS.CapabilitiesResponse>,
                                    let responseBody: Network.SOGS.CapabilitiesResponse = responseData.body
                                else { return false }
                                
                                return (responseBody != capabilities)
                                
                            case .roomPollInfo(let roomToken, _):
                                guard
                                    let responseData: Network.BatchSubResponse<Network.SOGS.RoomPollInfo> = data as? Network.BatchSubResponse<Network.SOGS.RoomPollInfo>,
                                    let responseBody: Network.SOGS.RoomPollInfo = responseData.body
                                else { return false }
                                guard let existingOpenGroup: OpenGroup = groups.first(where: { $0.roomToken == roomToken }) else {
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
                    return Just(((info, response), rawMessageCount, 0, true))
                        .setFailureType(to: Error.self)
                        .eraseToAnyPublisher()
                }
                
                return dependencies[singleton: .storage]
                    .writePublisher { db -> PollResult in
                        // Reset the failure count
                        if failureCount > 0 {
                            try OpenGroup
                                .filter(OpenGroup.Columns.server == pollerDestination.target)
                                .updateAll(db, OpenGroup.Columns.pollFailureCount.set(to: 0))
                        }
                        
                        var interactionInfo: [MessageReceiver.InsertedInteractionInfo?] = []
                        try changedResponses.forEach { endpoint, data in
                            switch endpoint {
                                case .capabilities:
                                    guard
                                        let responseData: Network.BatchSubResponse<Network.SOGS.CapabilitiesResponse> = data as? Network.BatchSubResponse<Network.SOGS.CapabilitiesResponse>,
                                        let responseBody: Network.SOGS.CapabilitiesResponse = responseData.body
                                    else { return }
                                    
                                    dependencies[singleton: .communityManager].handleCapabilities(
                                        db,
                                        capabilities: responseBody,
                                        server: pollerDestination.target,
                                        publicKey: publicKey
                                    )
                                    
                                case .roomPollInfo(let roomToken, _):
                                    guard
                                        let responseData: Network.BatchSubResponse<Network.SOGS.RoomPollInfo> = data as? Network.BatchSubResponse<Network.SOGS.RoomPollInfo>,
                                        let responseBody: Network.SOGS.RoomPollInfo = responseData.body
                                    else { return }
                                    
                                    try dependencies[singleton: .communityManager].handlePollInfo(
                                        db,
                                        pollInfo: responseBody,
                                        server: pollerDestination.target,
                                        roomToken: roomToken,
                                        publicKey: publicKey
                                    )
                                    
                                case .roomMessagesRecent(let roomToken), .roomMessagesBefore(let roomToken, _), .roomMessagesSince(let roomToken, _):
                                    guard
                                        let responseData: Network.BatchSubResponse<[Failable<Network.SOGS.Message>]> = data as? Network.BatchSubResponse<[Failable<Network.SOGS.Message>]>,
                                        let responseBody: [Failable<Network.SOGS.Message>] = responseData.body
                                    else { return }
                                    
                                    /// Might have been updated when handling one of the other responses so re-fetch the value
                                    let currentUserSessionIds: Set<String> = dependencies[singleton: .communityManager]
                                        .currentUserSessionIdsSync(pollerDestination.target.lowercased())
                                    interactionInfo.append(
                                        contentsOf: dependencies[singleton: .communityManager].handleMessages(
                                            db,
                                            messages: responseBody.compactMap { $0.value },
                                            server: pollerDestination.target,
                                            roomToken: roomToken,
                                            currentUserSessionIds: currentUserSessionIds
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
                                    
                                    /// Might have been updated when handling one of the other responses so re-fetch the value
                                    let currentUserSessionIds: Set<String> = dependencies[singleton: .communityManager]
                                        .currentUserSessionIdsSync(pollerDestination.target.lowercased())
                                    interactionInfo.append(
                                        contentsOf: dependencies[singleton: .communityManager].handleDirectMessages(
                                            db,
                                            messages: messages,
                                            fromOutbox: fromOutbox,
                                            server: pollerDestination.target,
                                            currentUserSessionIds: currentUserSessionIds
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
                        return ((info, response), rawMessageCount, rawMessageCount, true)
                    }
                    .eraseToAnyPublisher()
            }
            .eraseToAnyPublisher()
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

// MARK: - GroupPoller Cache

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
    
    class Cache: CommunityPollerCacheType {
        private let dependencies: Dependencies
        private var _pollers: [String: CommunityPoller] = [:] // One for each server
        
        public var serversBeingPolled: Set<String> { Set(_pollers.keys) }
        public var allPollers: [CommunityPollerType] { Array(_pollers.values) }
        
        // MARK: - Initialization
        
        public init(using dependencies: Dependencies) {
            self.dependencies = dependencies
        }
        
        deinit {
            _pollers.forEach { _, poller in poller.stop() }
            _pollers.removeAll()
        }
        
        // MARK: - Functions
        
        public func startAllPollers() {
            // On the communityPollerQueue fetch all SOGS and start the pollers
            Threading.communityPollerQueue.async(using: dependencies) { [weak self, dependencies] in
                dependencies[singleton: .storage].readAsync(
                    retrieve: { db -> [Info] in
                        // The default room promise creates an OpenGroup with an empty `roomToken` value,
                        // we don't want to start a poller for this as the user hasn't actually joined a room
                        try OpenGroup
                            .select(
                                OpenGroup.Columns.server,
                                max(OpenGroup.Columns.pollFailureCount).forKey(Info.Columns.pollFailureCount)
                            )
                            .filter(OpenGroup.Columns.shouldPoll == true)
                            .group(OpenGroup.Columns.server)
                            .asRequest(of: Info.self)
                            .fetchAll(db)
                    },
                    completion: { [weak self] result in
                        switch result {
                            case .failure: break
                            case .success(let infos):
                                Threading.communityPollerQueue.async(using: dependencies) { [weak self] in
                                    infos.forEach { info in
                                        self?.getOrCreatePoller(for: info).startIfNeeded()
                                    }
                                }
                        }
                    }
                )
            }
        }
        
        @discardableResult public func getOrCreatePoller(for info: CommunityPoller.Info) -> CommunityPollerType {
            guard let poller: CommunityPoller = _pollers[info.server.lowercased()] else {
                let poller: CommunityPoller = CommunityPoller(
                    pollerName: "Community poller for: \(info.server)", // stringlint:ignore
                    pollerQueue: Threading.communityPollerQueue,
                    pollerDestination: .server(info.server),
                    failureCount: Int(info.pollFailureCount),
                    shouldStoreMessages: true,
                    logStartAndStopCalls: false,
                    using: dependencies
                )
                _pollers[info.server.lowercased()] = poller
                return poller
            }
            
            return poller
        }

        public func stopAndRemovePoller(for server: String) {
            _pollers[server.lowercased()]?.stop()
            _pollers[server.lowercased()] = nil
        }
        
        public func stopAndRemoveAllPollers() {
            _pollers.forEach { _, poller in poller.stop() }
            _pollers.removeAll()
        }
    }
}

// MARK: - GroupPollerCacheType

/// This is a read-only version of the Cache designed to avoid unintentionally mutating the instance in a non-thread-safe way
public protocol CommunityPollerImmutableCacheType: ImmutableCacheType {
    var serversBeingPolled: Set<String> { get }
    var allPollers: [CommunityPollerType] { get }
}

public protocol CommunityPollerCacheType: CommunityPollerImmutableCacheType, MutableCacheType {
    var serversBeingPolled: Set<String> { get }
    var allPollers: [CommunityPollerType] { get }
    
    func startAllPollers()
    @discardableResult func getOrCreatePoller(for info: CommunityPoller.Info) -> CommunityPollerType
    func stopAndRemovePoller(for server: String)
    func stopAndRemoveAllPollers()
}

public extension CommunityPollerCacheType {
    @discardableResult func getOrCreatePoller(for server: String) -> CommunityPollerType {
        return getOrCreatePoller(for: CommunityPoller.Info(server: server, pollFailureCount: 0))
    }
}

// MARK: - Conformance

extension Network.SOGS.PollRoomInfo: @retroactive FetchableRecord {}
