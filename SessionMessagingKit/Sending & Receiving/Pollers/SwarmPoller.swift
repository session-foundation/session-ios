// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionNetworkingKit
import SessionUtilitiesKit

// MARK: - SwarmPollerType

public protocol SwarmPollerType: PollerType where PollResponse == SwarmPoller.PollResponse {
    var swarmDrainer: SwarmDrainer { get }
    var namespaces: [Network.StorageServer.Namespace] { get }
    var customAuthMethod: AuthenticationMethod? { get }
    var shouldStoreMessages: Bool { get }
    
    init(
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
    )
}

// MARK: - SwarmPollerType Convenience

extension SwarmPollerType {
    public init(
        pollerName: String,
        destination: PollerDestination,
        swarmDrainStrategy: SwarmDrainer.Strategy,
        namespaces: [Network.StorageServer.Namespace],
        failureCount: Int = 0,
        numConsecutiveEmptyPolls: Int = 0,
        shouldStoreMessages: Bool,
        logStartAndStopCalls: Bool,
        key: Dependencies.Key?,
        using dependencies: Dependencies
    ) {
        self.init(
            pollerName: pollerName,
            destination: destination,
            swarmDrainStrategy: swarmDrainStrategy,
            namespaces: namespaces,
            failureCount: failureCount,
            numConsecutiveEmptyPolls: numConsecutiveEmptyPolls,
            shouldStoreMessages: shouldStoreMessages,
            logStartAndStopCalls: logStartAndStopCalls,
            customAuthMethod: nil,
            key: key,
            using: dependencies
        )
    }
    
    /// Polls based on it's configuration and processes any messages, returning an array of messages that were
    /// successfully processed
    ///
    /// **Note:** The returned messages will have already been processed by the `Poller`, they are only returned
    /// for cases where we need explicit/custom behaviours to occur (eg. Onboarding)
    public func poll(forceSynchronousProcessing: Bool) async throws -> PollResult<PollResponse> {
        /// Select the node to poll
        let swarm: Set<LibSession.Snode> = try await dependencies[singleton: .network]
            .getSwarm(for: destination.target, ignoreStrikeCount: false)
        await swarmDrainer.updateSwarmIfNeeded(swarm)
        let snode: LibSession.Snode = try await swarmDrainer.selectNextNode()
        
        /// Fetch the messages (refreshing the current config hashes)
        let authMethod: AuthenticationMethod = try (customAuthMethod ?? Authentication.with(
            swarmPublicKey: destination.target,
            using: dependencies
        ))
        let activeHashes: [String] = {
            /// If we don't have an account then there won't be any active hashes so don't bother trying to get them
            guard dependencies[cache: .general].userExists else { return [] }
            
            return dependencies.mutate(cache: .libSession) { cache in
                cache.activeHashes(for: destination.target)
            }
        }()
        let lastHashes: [Network.StorageServer.Namespace: String] = try await dependencies[singleton: .storage].read { [namespaces, dependencies] db in
            try namespaces.reduce(into: [:]) { result, namespace in
                result[namespace] = try SnodeReceivedMessageInfo.fetchLastNotExpired(
                    db,
                    for: snode,
                    namespace: namespace,
                    swarmPublicKey: try authMethod.swarmPublicKey,
                    using: dependencies
                )?.hash
            }
        }
        let response: Network.StorageServer.PollResponse = try await Network.StorageServer.poll(
            namespaces: namespaces,
            lastHashes: lastHashes,
            refreshingConfigHashes: activeHashes,
            updateExpiryDates: SnodeReceivedMessageInfo
                .updateExpirationDates(groupedExpiryResult:using:),
            from: snode,
            authMethod: authMethod,
            using: dependencies
        )
        
        /// Get all of the messages and sort them by their required `processingOrder`
        typealias MessageData = (namespace: Network.StorageServer.Namespace, messages: [Network.StorageServer.Message], lastHash: String?)
        let sortedMessages: [MessageData] = response
            .compactMap { namespace, result -> MessageData? in
                (result.data?.messages).map { (namespace, $0, result.data?.lastHash) }
            }
            .sorted { lhs, rhs in lhs.namespace.processingOrder < rhs.namespace.processingOrder }
        let rawMessageCount: Int = sortedMessages.map { $0.messages.count }.reduce(0, +)
        
        /// No need to do anything if there are no messages
        guard rawMessageCount > 0 else {
            return PollResult(response: [])
        }
        
        /// Process the response
        let processedResponse: (configMessageJobs: [Job], standardMessageJobs: [Job], pollResult: PollResult<SwarmPoller.PollResponse>) = try await dependencies[singleton: .storage].write { [destination, shouldStoreMessages, dependencies] db in
            SwarmPoller.processPollResponse(
                db,
                cat: .poller,
                source: .snode(snode),
                swarmPublicKey: destination.target,
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
        await withThrowingTaskGroup(of: Void.self) { [dependencies] group in
            for job in processedResponse.configMessageJobs {
                group.addTask { [dependencies] in
                    /// **Note:** In the background we just want jobs to fail silently
                    _ = try? await ConfigMessageReceiveJob.run(job, using: dependencies)
                }
            }
        }
        await withThrowingTaskGroup(of: Void.self) { [dependencies] group in
            for job in processedResponse.standardMessageJobs {
                group.addTask { [dependencies] in
                    /// **Note:** In the background we just want jobs to fail silently
                    _ = try? await MessageReceiveJob.run(job, using: dependencies)
                }
            }
        }
        
        return processedResponse.pollResult
    }
}

public enum SwarmPoller {
    public typealias PollResponse = [ProcessedMessage]
    
    public enum PollSource: Equatable {
        case snode(LibSession.Snode)
        case pushNotification
    }
    
    @discardableResult public static func processPollResponse(
        _ db: ObservingDatabase,
        cat: Log.Category,
        source: PollSource,
        swarmPublicKey: String,
        shouldStoreMessages: Bool,
        ignoreDedupeFiles: Bool,
        forceSynchronousProcessing: Bool,
        sortedMessages: [(namespace: Network.StorageServer.Namespace, messages: [Network.StorageServer.Message], lastHash: String?)],
        using dependencies: Dependencies
    ) -> ([Job], [Job], PollResult<SwarmPoller.PollResponse>) {
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
                        
                        /// Insert the deduplication record (ignoring dedupe files if needed)
                        ///
                        /// **Note:** For the synchronous notification extension import path (`forceSynchronousProcessing`, ie. loading
                        /// messages saved by the notification extension) we defer this insert - for both standard **and** config messages -
                        /// so it can be performed within the same savepoint as the message handling below. This ensures we never commit a
                        /// dedupe record without successfully handling the message (which would otherwise permanently prevent it from being
                        /// reprocessed on a future poll). Asynchronously-handled messages (which retry via a persistent job if they fail) and
                        /// the normal synchronous poll handling still insert the record here
                        let willHandleSynchronouslyInSavepoint: Bool = (shouldStoreMessages && forceSynchronousProcessing)

                        if !willHandleSynchronouslyInSavepoint {
                            try MessageDeduplication.insert(
                                db,
                                processedMessage: processedMessage,
                                ignoreDedupeFiles: ignoreDedupeFiles,
                                using: dependencies
                            )
                        }

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

                                /// On the synchronous notification extension import path the message (and a dedupe file) will have
                                /// been saved by the extension; since we failed to process it here (eg. `CryptoError.invalidKey` when
                                /// the group keys haven't synced into the main app yet) we need to remove that dedupe record so a
                                /// subsequent poll can genuinely reprocess the message once it becomes decryptable - otherwise the
                                /// surviving dedupe file would make the poll drop it as a duplicate and the message would be lost
                                ///
                                /// **Note:** For groups the `threadId` matches the `swarmPublicKey`; for other conversations the
                                /// computed path won't exist so this is a harmless no-op (hence `try?`)
                                if forceSynchronousProcessing {
                                    try? dependencies[singleton: .extensionHelper].removeDedupeRecord(
                                        threadId: swarmPublicKey,
                                        uniqueIdentifier: message.hash
                                    )
                                }
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
                        ///
                        /// For the synchronous notification extension import path (`forceSynchronousProcessing`) we perform the
                        /// deferred deduplication inserts and the config handling within a savepoint so they are atomic - otherwise a
                        /// failure would leave dedupe records behind without the config changes having been applied, permanently
                        /// preventing them from being reprocessed. For all other paths the dedupe records were already inserted above
                        /// so we just handle the messages
                        try db.inSavepoint {
                            if forceSynchronousProcessing {
                                try processedMessages.forEach { processedMessage in
                                    do {
                                        try MessageDeduplication.insert(
                                            db,
                                            processedMessage: processedMessage,
                                            ignoreDedupeFiles: ignoreDedupeFiles,
                                            using: dependencies
                                        )
                                    }
                                    catch {
                                        /// Tolerate duplicates (the record already exists so there's nothing more to insert - just cancel
                                        /// the pending file write) but let any other error roll the savepoint back
                                        switch error {
                                            case DatabaseError.SQLITE_CONSTRAINT_UNIQUE,
                                                DatabaseError.SQLITE_CONSTRAINT,    /// Sometimes thrown for UNIQUE
                                                MessageError.duplicateMessage,
                                                MessageError.selfSend:
                                                MessageDeduplication.removePendingWrite(processedMessage, using: dependencies)

                                            default: throw error
                                        }
                                    }
                                }
                            }

                            try dependencies.mutate(cache: .libSession) {
                                try $0.handleConfigMessages(
                                    db,
                                    swarmPublicKey: swarmPublicKey,
                                    messages: ConfigMessageReceiveJob
                                        .Details(messages: processedMessages)
                                        .messages
                                )
                            }

                            return .commit
                        }
                    }
                    catch {
                        /// If we deferred the dedupe inserts then the savepoint rolled them back so cancel their pending file writes too
                        if forceSynchronousProcessing {
                            processedMessages.forEach { MessageDeduplication.removePendingWrite($0, using: dependencies) }
                        }

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
                            var insertedInteractionInfo: MessageReceiver.InsertedInteractionInfo?

                            /// Perform the deduplication insert and message handling within a savepoint so the two are atomic - if the
                            /// handling fails we must **not** leave a dedupe record behind as that would permanently prevent the
                            /// message from being reprocessed on a future poll (the dedupe insert was deferred above for exactly this
                            /// reason)
                            try db.inSavepoint {
                                try MessageDeduplication.insert(
                                    db,
                                    processedMessage: processedMessage,
                                    ignoreDedupeFiles: ignoreDedupeFiles,
                                    using: dependencies
                                )

                                insertedInteractionInfo = try MessageReceiver.handle(
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

                                return .commit
                            }

                            /// Notify about the received message (performed outside the savepoint as a notification failure shouldn't
                            /// roll back the successfully handled message)
                            MessageReceiver.prepareNotificationsForInsertedInteractions(
                                db,
                                insertedInteractionInfo: insertedInteractionInfo,
                                isMessageRequest: dependencies.mutate(cache: .libSession) { cache in
                                    cache.isMessageRequest(threadId: threadId, threadVariant: messageInfo.threadVariant)
                                },
                                using: dependencies
                            )
                        }
                        catch {
                            /// The savepoint rolled back the dedupe insert and any partial handling, but the pending dedupe file write is
                            /// registered outside the transaction scope so cancel it explicitly to keep the two consistent
                            MessageDeduplication.removePendingWrite(processedMessage, using: dependencies)

                            switch error {
                                /// Ignore duplicate & selfSend message errors (the message was already handled previously so there's
                                /// nothing more to do)
                                case DatabaseError.SQLITE_CONSTRAINT_UNIQUE,
                                    DatabaseError.SQLITE_CONSTRAINT,    /// Sometimes thrown for UNIQUE
                                    MessageError.duplicateMessage,
                                    MessageError.selfSend:
                                    break

                                default:
                                    invalidMessageCount += 1
                                    Log.error(cat, "Failed to handle processed message in \(threadId) due to error: \(error).")

                                    /// The savepoint rolled back the message handling (and its deferred dedupe insert) but the extension
                                    /// may have saved a dedupe file for this message; remove it so a subsequent poll can reprocess the
                                    /// message rather than dropping it as a duplicate
                                    if forceSynchronousProcessing {
                                        try? dependencies[singleton: .extensionHelper].removeDedupeRecord(
                                            threadId: threadId,
                                            uniqueIdentifier: processedMessage.uniqueIdentifier
                                        )
                                    }
                            }
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
