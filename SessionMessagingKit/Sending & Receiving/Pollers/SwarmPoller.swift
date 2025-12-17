// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionNetworkingKit
import SessionUtilitiesKit

// MARK: - SwarmPollerType

public protocol SwarmPollerType {
    typealias PollResponse = [ProcessedMessage]
    
    nonisolated var receivedPollResponse: AsyncStream<PollResponse> { get }
    
    func startIfNeeded()
    func stop()
}

// MARK: - SwarmPoller

public class SwarmPoller: SwarmPollerType & PollerType {
    private static let emptyResult: ([Job], [Job], PollResult<PollResponse>) = (
        [],
        [],
        PollResult(
            response: [],
            rawMessageCount: 0,
            validMessageCount: 0,
            invalidMessageCount: 0,
            hadValidHashUpdate: false
        )
    )
    
    public enum PollSource: Equatable {
        case snode(LibSession.Snode)
        case pushNotification
    }
    
    public let dependencies: Dependencies
    public let pollerQueue: DispatchQueue
    public let pollerName: String
    public let pollerDestination: PollerDestination
    @ThreadSafeObject public var pollerDrainBehaviour: SwarmDrainBehaviour
    public let logStartAndStopCalls: Bool
    nonisolated public var receivedPollResponse: AsyncStream<PollResponse> { responseStream.stream }
    nonisolated public var successfulPollCount: AsyncStream<Int> { pollCountStream.stream }
    
    public var isPolling: Bool = false
    public var pollCount: Int = 0
    public var failureCount: Int
    public var lastPollStart: TimeInterval = 0
    public var cancellable: AnyCancellable?
    
    private let namespaces: [Network.SnodeAPI.Namespace]
    private let customAuthMethod: AuthenticationMethod?
    private let shouldStoreMessages: Bool
    nonisolated private let responseStream: CancellationAwareAsyncStream<PollResponse> = CancellationAwareAsyncStream()
    nonisolated private let pollCountStream: CurrentValueAsyncStream<Int> = CurrentValueAsyncStream(0)

    // MARK: - Initialization
    
    required public init(
        pollerName: String,
        pollerQueue: DispatchQueue,
        pollerDestination: PollerDestination,
        pollerDrainBehaviour: ThreadSafeObject<SwarmDrainBehaviour>,
        namespaces: [Network.SnodeAPI.Namespace],
        failureCount: Int = 0,
        shouldStoreMessages: Bool,
        logStartAndStopCalls: Bool,
        customAuthMethod: AuthenticationMethod? = nil,
        using dependencies: Dependencies
    ) {
        self.dependencies = dependencies
        self.pollerName = pollerName
        self.pollerQueue = pollerQueue
        self.pollerDestination = pollerDestination
        self._pollerDrainBehaviour = pollerDrainBehaviour
        self.namespaces = namespaces
        self.failureCount = failureCount
        self.customAuthMethod = customAuthMethod
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
    
    /// Calculate the delay which should occur before the next poll
    public func nextPollDelay() -> AnyPublisher<TimeInterval, Error> {
        preconditionFailure("abstract class - override in subclass")
    }
    
    /// Perform and logic which should occur when the poll errors, will stop polling if `false` is returned
    public func handlePollError(_ error: Error, _ lastError: Error?) -> PollerErrorResponse {
        preconditionFailure("abstract class - override in subclass")
    }
    
    // MARK: - Internal Functions
    
    internal func setDrainBehaviour(_ behaviour: SwarmDrainBehaviour) {
        _pollerDrainBehaviour.set(to: behaviour)
    }

    // MARK: - Polling
    
    public func pollerDidStart() {}
    
    /// Polls based on it's configuration and processes any messages, returning an array of messages that were
    /// successfully processed
    ///
    /// **Note:** The returned messages will have already been processed by the `Poller`, they are only returned
    /// for cases where we need explicit/custom behaviours to occur (eg. Onboarding)
    public func poll(forceSynchronousProcessing: Bool) -> AnyPublisher<PollResult<PollResponse>, Error> {
        let pollerQueue: DispatchQueue = self.pollerQueue
        let activeHashes: [String] = {
            /// If we don't have an account then there won't be any active hashes so don't bother trying to get them
            guard dependencies[cache: .general].userExists else { return [] }
            
            return dependencies.mutate(cache: .libSession) { cache in
                cache.activeHashes(for: pollerDestination.target)
            }
        }()
        
        /// Fetch the messages
        return dependencies[singleton: .network]
            .getSwarm(for: pollerDestination.target)
            .tryFlatMapWithRandomSnode(drainBehaviour: _pollerDrainBehaviour, using: dependencies) { [pollerDestination, customAuthMethod, namespaces, dependencies] snode -> AnyPublisher<(LibSession.Snode, Network.PreparedRequest<Network.SnodeAPI.PollResponse>), Error> in
                dependencies[singleton: .storage].readPublisher { db -> (LibSession.Snode, Network.PreparedRequest<Network.SnodeAPI.PollResponse>) in
                    let authMethod: AuthenticationMethod = try (customAuthMethod ?? Authentication.with(
                        swarmPublicKey: pollerDestination.target,
                        using: dependencies
                    ))
                    
                    return (
                        snode,
                        try Network.SnodeAPI.preparedPoll(
                            db,
                            namespaces: namespaces,
                            refreshingConfigHashes: activeHashes,
                            from: snode,
                            authMethod: authMethod,
                            using: dependencies
                        )
                    )
                }
            }
            .flatMap { [dependencies] snode, request in
                request.send(using: dependencies)
                    .map { _, response in (snode, response) }
            }
            .flatMapStorageWritePublisher(using: dependencies, updates: { [pollerDestination, shouldStoreMessages, forceSynchronousProcessing, dependencies] db, info -> ([Job], [Job], PollResult<PollResponse>) in
                let (snode, namespacedResults): (LibSession.Snode, Network.SnodeAPI.PollResponse) = info
                
                /// Get all of the messages and sort them by their required `processingOrder`
                typealias MessageData = (namespace: Network.SnodeAPI.Namespace, messages: [SnodeReceivedMessage], lastHash: String?)
                let sortedMessages: [MessageData] = namespacedResults
                    .compactMap { namespace, result -> MessageData? in
                        (result.data?.messages).map { (namespace, $0, result.data?.lastHash) }
                    }
                    .sorted { lhs, rhs in lhs.namespace.processingOrder < rhs.namespace.processingOrder }
                let rawMessageCount: Int = sortedMessages.map { $0.messages.count }.reduce(0, +)
                
                /// No need to do anything if there are no messages
                guard rawMessageCount > 0 else {
                    return SwarmPoller.emptyResult
                }
                
                return SwarmPoller.processPollResponse(
                    db,
                    cat: .poller,
                    source: .snode(snode),
                    swarmPublicKey: pollerDestination.target,
                    shouldStoreMessages: shouldStoreMessages,
                    ignoreDedupeFiles: false,
                    forceSynchronousProcessing: forceSynchronousProcessing,
                    sortedMessages: sortedMessages,
                    using: dependencies
                )
            })
            .flatMap { [dependencies] (configMessageJobs, standardMessageJobs, pollResult) -> AnyPublisher<PollResult, Error> in
                // If we don't want to forcible process the response synchronously then just finish immediately
                guard forceSynchronousProcessing else {
                    return Just(pollResult)
                        .setFailureType(to: Error.self)
                        .eraseToAnyPublisher()
                }
                
                // We want to try to handle the receive jobs immediately in the background
                return Publishers
                    .MergeMany(
                        configMessageJobs.map { job -> AnyPublisher<Void, Error> in
                            Deferred {
                                Future<Void, Error> { resolver in
                                    // Note: In the background we just want jobs to fail silently
                                    ConfigMessageReceiveJob.run(
                                        job,
                                        scheduler: pollerQueue,
                                        success: { _, _ in resolver(Result.success(())) },
                                        failure: { _, _, _ in resolver(Result.success(())) },
                                        deferred: { _ in resolver(Result.success(())) },
                                        using: dependencies
                                    )
                                }
                            }
                            .eraseToAnyPublisher()
                        }
                    )
                    .collect()
                    .flatMap { _ in
                        Publishers
                            .MergeMany(
                                standardMessageJobs.map { job -> AnyPublisher<Void, Error> in
                                    Deferred {
                                        Future<Void, Error> { resolver in
                                            // Note: In the background we just want jobs to fail silently
                                            MessageReceiveJob.run(
                                                job,
                                                scheduler: pollerQueue,
                                                success: { _, _ in resolver(Result.success(())) },
                                                failure: { _, _, _ in resolver(Result.success(())) },
                                                deferred: { _ in resolver(Result.success(())) },
                                                using: dependencies
                                            )
                                        }
                                    }
                                    .eraseToAnyPublisher()
                                }
                            )
                            .collect()
                    }
                    .map { _ in pollResult }
                    .eraseToAnyPublisher()
            }
            .handleEvents(
                receiveOutput: { [weak self] (pollResult: PollResult) in
                    let updatedPollCount: Int = ((self?.pollCount ?? 0) + 1)
                    self?.pollCount = updatedPollCount
                    
                    /// Notify any observers that we got a result
                    Task { [weak self] in
                        await self?.responseStream.send(pollResult.response)
                        await self?.pollCountStream.send(updatedPollCount)
                    }
                }
            )
            .eraseToAnyPublisher()
    }
    
    @discardableResult public static func processPollResponse(
        _ db: ObservingDatabase,
        cat: Log.Category,
        source: PollSource,
        swarmPublicKey: String,
        shouldStoreMessages: Bool,
        ignoreDedupeFiles: Bool,
        forceSynchronousProcessing: Bool,
        sortedMessages: [(namespace: Network.SnodeAPI.Namespace, messages: [SnodeReceivedMessage], lastHash: String?)],
        using dependencies: Dependencies
    ) -> ([Job], [Job], PollResult<PollResponse>) {
        /// No need to do anything if there are no messages
        let rawMessageCount: Int = sortedMessages.map { $0.messages.count }.reduce(0, +)
        
        guard rawMessageCount > 0 else {
            return SwarmPoller.emptyResult
        }
        
        /// Otherwise process the messages and add them to the queue for handling
        let lastHashes: [String] = sortedMessages.compactMap { $0.lastHash }
        let otherKnownHashes: [String] = sortedMessages
            .filter { $0.namespace.shouldFetchSinceLastHash }
            .compactMap { $0.messages.map { $0.hash } }
            .reduce([], +)
        var messageCount: Int = 0
        var invalidMessageCount: Int = 0
        var finalProcessedMessages: [ProcessedMessage] = []
        var hadValidHashUpdate: Bool = false
        
        /// If the poll was successful we need to retrieve the `lastHash` values direct from the database again to ensure they
        /// still line up (if they have been reset in the database then we want to ignore the poll as it would invalidate whatever
        /// change modified the `lastHash` values potentially resulting in us not polling again from scratch even if we want to)
        let lastHashesAfterFetch: Set<String> = {
            switch source {
                case .pushNotification: return []
                case .snode(let snode):
                    return Set(sortedMessages.compactMap { namespace, _, _ in
                        try? SnodeReceivedMessageInfo
                            .fetchLastNotExpired(
                                db,
                                for: snode,
                                namespace: namespace,
                                swarmPublicKey: swarmPublicKey,
                                using: dependencies
                            )?
                            .hash
                    })
            }
        }()
        
        guard lastHashes.isEmpty || Set(lastHashes) == lastHashesAfterFetch else {
            return SwarmPoller.emptyResult
        }
        
        /// Since the hashes are still accurate we can now process the messages
        let currentUserSessionId: SessionId = dependencies[cache: .general].sessionId
        let allProcessedMessages: [ProcessedMessage] = sortedMessages
            .compactMap { namespace, messages, _ -> [ProcessedMessage]? in
                let processedMessages: [ProcessedMessage] = messages.compactMap { message -> ProcessedMessage? in
                    do {
                        let processedMessage: ProcessedMessage = try MessageReceiver.parse(
                            data: message.data,
                            origin: .swarm(
                                publicKey: swarmPublicKey,
                                namespace: message.namespace,
                                serverHash: message.hash,
                                serverTimestampMs: message.timestampMs,
                                serverExpirationTimestamp: TimeInterval(Double(message.expirationTimestampMs) / 1000)
                            ),
                            using: dependencies
                        )
                        hadValidHashUpdate = (message.info?.storeUpdatedLastHash(db) == true)
                        
                        /// Insert the standard dedupe record ignoring dedupe files if needed
                        try MessageDeduplication.insert(
                            db,
                            processedMessage: processedMessage,
                            ignoreDedupeFiles: ignoreDedupeFiles,
                            using: dependencies
                        )
                        
                        return processedMessage
                    }
                    catch {
                        /// For some error cases we want to update the last hash so do so
                        if (error as? MessageError)?.shouldUpdateLastHash == true {
                            hadValidHashUpdate = (message.info?.storeUpdatedLastHash(db) == true)
                        }
                        
                        switch error {
                            /// Ignore duplicate & selfSend message errors (and don't bother logging them as there
                            /// will be a lot since we each service node duplicates messages)
                            case DatabaseError.SQLITE_CONSTRAINT_UNIQUE,
                                DatabaseError.SQLITE_CONSTRAINT,    /// Sometimes thrown for UNIQUE
                                MessageError.duplicateMessage,
                                MessageError.selfSend:
                                break
                            
                            case DatabaseError.SQLITE_ABORT:
                                Log.warn(cat, "Failed to the database being suspended (running in background with no background task).")
                                
                            default:
                                invalidMessageCount += 1
                                Log.error(cat, "Failed to deserialize envelope due to error: \(error).")
                        }
                        
                        return nil
                    }
                }
                
                /// If this message should be stored and should be handled synchronously then do so here before processing the next namespace
                guard
                    shouldStoreMessages &&
                    !processedMessages.isEmpty &&
                    (namespace.shouldHandleSynchronously || forceSynchronousProcessing)
                else { return processedMessages }
                
                if namespace.isConfigNamespace {
                    do {
                        /// Process config messages all at once in case they are multi-part messages
                        try dependencies.mutate(cache: .libSession) {
                            try $0.handleConfigMessages(
                                db,
                                swarmPublicKey: swarmPublicKey,
                                messages: ConfigMessageReceiveJob
                                    .Details(messages: processedMessages)
                                    .messages
                            )
                        }
                    }
                    catch {
                        invalidMessageCount += 1
                        Log.error(cat, "Failed to handle processed config message in \(swarmPublicKey) due to error: \(error).")
                    }
                }
                else {
                    /// Individually process non-config messages
                    processedMessages.forEach { processedMessage in
                        guard case .standard(let threadId, let threadVariant, let messageInfo, _) = processedMessage else {
                            return
                        }
                        
                        do {
                            let info: MessageReceiver.InsertedInteractionInfo? = try MessageReceiver.handle(
                                db,
                                threadId: threadId,
                                threadVariant: threadVariant,
                                message: messageInfo.message,
                                decodedMessage: messageInfo.decodedMessage,
                                serverExpirationTimestamp: messageInfo.serverExpirationTimestamp,
                                suppressNotifications: (source == .pushNotification),    /// Have already shown
                                currentUserSessionIds: [currentUserSessionId.hexString], /// Swarm poller only has one
                                using: dependencies
                            )
                            
                            /// Notify about the received message
                            MessageReceiver.prepareNotificationsForInsertedInteractions(
                                db,
                                insertedInteractionInfo: info,
                                isMessageRequest: dependencies.mutate(cache: .libSession) { cache in
                                    cache.isMessageRequest(threadId: threadId, threadVariant: messageInfo.threadVariant)
                                },
                                using: dependencies
                            )
                        }
                        catch {
                            invalidMessageCount += 1
                            Log.error(cat, "Failed to handle processed message in \(threadId) due to error: \(error).")
                        }
                    }
                }
                
                /// Make sure to add any synchronously processed messages to the `finalProcessedMessages` as otherwise
                /// they wouldn't be emitted by `receivedPollResponse`, also need to add the count to `messageCount` to
                /// ensure it's not incorrect
                finalProcessedMessages += processedMessages
                messageCount += processedMessages.count
                return nil
            }
            .flatMap { $0 }
        
        /// If we don't want to store the messages then no need to continue (don't want to create message receive jobs or mess with cached hashes)
        guard shouldStoreMessages && !forceSynchronousProcessing else {
            finalProcessedMessages += allProcessedMessages
            return (
                [],
                [],
                PollResult(
                    response: finalProcessedMessages,
                    rawMessageCount: rawMessageCount,
                    validMessageCount: messageCount,
                    invalidMessageCount: invalidMessageCount,
                    hadValidHashUpdate: hadValidHashUpdate
                )
            )
        }
        
        /// Add a job to process the config messages first
        let configMessageJobs: [Job] = allProcessedMessages
            .filter { $0.isConfigMessage && !$0.namespace.shouldHandleSynchronously }
            .grouped { $0.threadId }
            .compactMap { threadId, threadMessages in
                messageCount += threadMessages.count
                finalProcessedMessages += threadMessages
                
                let job: Job? = Job(
                    variant: .configMessageReceive,
                    behaviour: .runOnce,
                    threadId: threadId,
                    details: ConfigMessageReceiveJob.Details(messages: threadMessages)
                )
                
                /// If we are force-polling then add to the `JobRunner` so they are persistent and will retry on the next app
                /// run if they fail but don't let them auto-start
                return dependencies[singleton: .jobRunner].add(
                    db,
                    job: job,
                    canStartJob: !dependencies[singleton: .appContext].isInBackground
                )
            }
        let configJobIds: [Int64] = configMessageJobs.compactMap { $0.id }
        
        /// Add jobs for processing non-config messages which are dependant on the config message processing jobs
        let standardMessageJobs: [Job] = allProcessedMessages
            .filter { !$0.isConfigMessage && !$0.namespace.shouldHandleSynchronously }
            .grouped { $0.threadId }
            .compactMap { threadId, threadMessages in
                messageCount += threadMessages.count
                finalProcessedMessages += threadMessages
                
                let job: Job? = Job(
                    variant: .messageReceive,
                    behaviour: .runOnce,
                    threadId: threadId,
                    details: MessageReceiveJob.Details(messages: threadMessages)
                )
                
                /// If we are force-polling then add to the `JobRunner` so they are persistent and will retry on the next app
                /// run if they fail but don't let them auto-start
                let updatedJob: Job? = dependencies[singleton: .jobRunner].add(
                    db,
                    job: job,
                    canStartJob: (
                        !dependencies[singleton: .appContext].isInBackground ||
                        // FIXME: Better seperate the call messages handling, since we need to handle them all the time
                        dependencies[singleton: .callManager].currentCall != nil
                    )
                )
                
                /// Create the dependency between the jobs (config processing should happen before standard message processing)
                if let updatedJobId: Int64 = updatedJob?.id {
                    do {
                        try configJobIds.forEach { configJobId in
                            try JobDependencies(
                                jobId: updatedJobId,
                                dependantId: configJobId
                            )
                            .insert(db)
                        }
                    }
                    catch {
                        Log.warn(cat, "Failed to add dependency between config processing and non-config processing messageReceive jobs.")
                    }
                }
                
                return updatedJob
            }
        
        /// If the source was a snode then update the cached validity of the messages (for messages received via push notifications
        /// we want to receive them in a subsequent poll to ensure we have the correct `lastHash` value as they can be received
        /// out of order)
        switch source {
            case .pushNotification: break
            case .snode:
                do {
                    try SnodeReceivedMessageInfo.handlePotentialDeletedOrInvalidHash(
                        db,
                        potentiallyInvalidHashes: (sortedMessages.isEmpty && !hadValidHashUpdate ?
                            lastHashes :
                            []
                        ),
                        otherKnownValidHashes: otherKnownHashes
                    )
                }
                catch { Log.error(cat, "Failed to handle potential invalid/deleted hashes due to error: \(error).") }
        }
        
        return (
            configMessageJobs,
            standardMessageJobs,
            PollResult(
                response: finalProcessedMessages,
                rawMessageCount: rawMessageCount,
                validMessageCount: messageCount,
                invalidMessageCount: invalidMessageCount,
                hadValidHashUpdate: hadValidHashUpdate
            )
        )
    }
}
