// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionNetworkingKit
import SessionUtilitiesKit

// MARK: - SwarmPollerType

public protocol SwarmPollerType {
    typealias PollResponse = [ProcessedMessage]
    
    var swarmDrainer: SwarmDrainer { get }
    
    nonisolated var receivedPollResponse: AsyncStream<PollResponse> { get }
    
    func startIfNeeded()
    func stop()
}

// MARK: - SwarmPoller

public class SwarmPoller: SwarmPollerType & PollerType {
    public enum PollSource: Equatable {
        case snode(LibSession.Snode)
        case pushNotification
    }
    
    public let dependencies: Dependencies
    public let dependenciesKey: Dependencies.Key?
    public let pollerQueue: DispatchQueue
    public let pollerName: String
    public let pollerDestination: PollerDestination
    public let swarmDrainer: SwarmDrainer
    public let logStartAndStopCalls: Bool
    nonisolated public var receivedPollResponse: AsyncStream<PollResponse> { responseStream.stream }
    nonisolated public var successfulPollCount: AsyncStream<Int> { pollCountStream.stream }
    
    public var pollTask: Task<Void, Error>?
    public var pollCount: Int = 0
    public var failureCount: Int
    public var lastPollStart: TimeInterval = 0
    
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
        swarmDrainStrategy: SwarmDrainer.Strategy,
        namespaces: [Network.SnodeAPI.Namespace],
        failureCount: Int = 0,
        shouldStoreMessages: Bool,
        logStartAndStopCalls: Bool,
        customAuthMethod: AuthenticationMethod? = nil,
        key: Dependencies.Key?,
        using dependencies: Dependencies
    ) {
        self.dependencies = dependencies
        self.dependenciesKey = key
        self.pollerName = pollerName
        self.pollerQueue = pollerQueue
        self.pollerDestination = pollerDestination
        self.swarmDrainer = SwarmDrainer(
            strategy: swarmDrainStrategy,
            nextRetrievalAfterDrain: .resetState,
            logDetails: SwarmDrainer.LogDetails(cat: .poller, name: pollerName),
            using: dependencies
        )
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
    public func nextPollDelay() async -> TimeInterval {
        preconditionFailure("abstract class - override in subclass")
    }
    
    // MARK: - Polling
    
    public func pollerDidStart() {}
    
    /// Polls based on it's configuration and processes any messages, returning an array of messages that were
    /// successfully processed
    ///
    /// **Note:** The returned messages will have already been processed by the `Poller`, they are only returned
    /// for cases where we need explicit/custom behaviours to occur (eg. Onboarding)
    public func poll(forceSynchronousProcessing: Bool) async throws -> PollResult<PollResponse> {
        /// Select the node to poll
        // FIXME: Refactor to async/await
        let swarm: Set<LibSession.Snode> = try await dependencies[singleton: .network]
            .getSwarm(for: pollerDestination.target)
            .values
            .first { _ in true } ?? { throw NetworkError.invalidResponse }()
        await swarmDrainer.updateSwarmIfNeeded(swarm)
        let snode: LibSession.Snode = try await swarmDrainer.selectNextNode()
        
        /// Fetch the messages (refreshing the current config hashes)
        let authMethod: AuthenticationMethod = try (customAuthMethod ?? Authentication.with(
            swarmPublicKey: pollerDestination.target,
            using: dependencies
        ))
        let activeHashes: [String] = {
            /// If we don't have an account then there won't be any active hashes so don't bother trying to get them
            guard dependencies[cache: .general].userExists else { return [] }
            
            return dependencies.mutate(cache: .libSession) { cache in
                cache.activeHashes(for: pollerDestination.target)
            }
        }()
        let request: Network.PreparedRequest<Network.SnodeAPI.PollResponse> = try await dependencies[singleton: .storage].readAsync { [namespaces, dependencies] db in
            try Network.SnodeAPI.preparedPoll(
                db,
                namespaces: namespaces,
                refreshingConfigHashes: activeHashes,
                from: snode,
                authMethod: authMethod,
                using: dependencies
            )
        }
        // FIXME: Refactor to async/await
        let response: Network.SnodeAPI.PollResponse = try await request.send(using: dependencies)
            .values
            .first { _ in true }?.1 ?? { throw NetworkError.invalidResponse }()
        
        /// Get all of the messages and sort them by their required `processingOrder`
        typealias MessageData = (namespace: Network.SnodeAPI.Namespace, messages: [SnodeReceivedMessage], lastHash: String?)
        let sortedMessages: [MessageData] = response
            .compactMap { namespace, result -> MessageData? in
                (result.data?.messages).map { (namespace, $0, result.data?.lastHash) }
            }
            .sorted { lhs, rhs in lhs.namespace.processingOrder < rhs.namespace.processingOrder }
        let rawMessageCount: Int = sortedMessages.map { $0.messages.count }.reduce(0, +)
        
        /// No need to do anything if there are no messages
        guard rawMessageCount > 0 else {
            pollCount += 1
            await responseStream.send([])
            await pollCountStream.send(pollCount)
            return PollResult(response: [])
        }
        
        /// Process the response
        let processedResponse: (configMessageJobs: [Job], standardMessageJobs: [Job], pollResult: PollResult<SwarmPoller.PollResponse>) = try await dependencies[singleton: .storage].writeAsync { [pollerDestination, shouldStoreMessages, dependencies] db in
            SwarmPoller.processPollResponse(
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
        }
        
        /// If we don't want to forcible process the response synchronously then just finish immediately
        guard forceSynchronousProcessing else { return processedResponse.pollResult }
        
        /// We want to try to handle the receive jobs immediately in the background
        await withThrowingTaskGroup { [dependencies] group in
            for job in processedResponse.configMessageJobs {
                group.addTask { [dependencies] in
                    /// **Note:** In the background we just want jobs to fail silently
                    try? await ConfigMessageReceiveJob.run(job, using: dependencies)
                }
            }
        }
        await withThrowingTaskGroup { [dependencies] group in
            for job in processedResponse.standardMessageJobs {
                group.addTask { [dependencies] in
                    /// **Note:** In the background we just want jobs to fail silently
                    try? await MessageReceiveJob.run(job, using: dependencies)
                }
            }
        }
        
        pollCount += 1
        await responseStream.send(processedResponse.pollResult.response)
        await pollCountStream.send(pollCount)
        
        return processedResponse.pollResult
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
            return ([], [], PollResult(response: []))
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
            return ([], [], PollResult(response: []))
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
                
                /// If we are force-polling then add to the `JobRunner` so they are persistent and will retry on the next app
                /// run if they fail but don't let them auto-start
                return dependencies[singleton: .jobRunner].add(
                    db,
                    job: Job(
                        variant: .configMessageReceive,
                        threadId: threadId,
                        details: ConfigMessageReceiveJob.Details(messages: threadMessages)
                    )
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
                
                /// If we are force-polling then add to the `JobRunner` so they are persistent but they won't run as the
                /// `JobRunner` only runs in the foreground (we add them so if they fail when being handled in the backgroud
                /// they can retry on the next app run)
                ///
                /// We also add a dependency on any config jobs because those should be handled before standard messages
                let job: Job? = dependencies[singleton: .jobRunner].add(
                    db,
                    job: Job(
                        variant: .messageReceive,
                        threadId: threadId,
                        details: MessageReceiveJob.Details(messages: threadMessages)
                    ),
                    initialDependencies: configJobIds.map { configJobId in
                        .job(otherJobId: configJobId)
                    }
                )
                
                return job
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
