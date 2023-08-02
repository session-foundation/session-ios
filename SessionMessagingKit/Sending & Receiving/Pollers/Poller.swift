// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import Sodium
import SessionSnodeKit
import SessionUtilitiesKit

public class Poller {
    private var cancellables: Atomic<[String: AnyCancellable]> = Atomic([:])
    internal var isPolling: Atomic<[String: Bool]> = Atomic([:])
    internal var pollCount: Atomic<[String: Int]> = Atomic([:])
    internal var failureCount: Atomic<[String: Int]> = Atomic([:])
    
    internal var targetSnode: Atomic<Snode?> = Atomic(nil)
    private var usedSnodes: Atomic<Set<Snode>> = Atomic([])
    
    // MARK: - Settings
    
    /// The namespaces which this poller queries
    internal var namespaces: [SnodeAPI.Namespace] {
        preconditionFailure("abstract class - override in subclass")
    }
    
    /// The number of times the poller can poll a single snode before swapping to a new snode
    internal var maxNodePollCount: UInt {
        preconditionFailure("abstract class - override in subclass")
    }

    // MARK: - Public API
    
    public init() {}
    
    public func stopAllPollers() {
        let pollers: [String] = Array(isPolling.wrappedValue.keys)
        
        pollers.forEach { groupPublicKey in
            self.stopPolling(for: groupPublicKey)
        }
    }
    
    public func stopPolling(for publicKey: String) {
        isPolling.mutate { $0[publicKey] = false }
        cancellables.mutate { $0[publicKey]?.cancel() }
    }
    
    // MARK: - Abstract Methods
    
    /// The name for this poller to appear in the logs
    internal func pollerName(for publicKey: String) -> String {
        preconditionFailure("abstract class - override in subclass")
    }
    
    /// Calculate the delay which should occur before the next poll
    internal func nextPollDelay(for publicKey: String, using dependencies: Dependencies) -> TimeInterval {
        preconditionFailure("abstract class - override in subclass")
    }
    
    /// Perform and logic which should occur when the poll errors, will stop polling if `false` is returned
    internal func handlePollError(_ error: Error, for publicKey: String, using dependencies: Dependencies) -> Bool {
        preconditionFailure("abstract class - override in subclass")
    }

    // MARK: - Private API
    
    internal func startIfNeeded(for publicKey: String, using dependencies: Dependencies) {
        // Run on the 'pollerQueue' to ensure any 'Atomic' access doesn't block the main thread
        // on startup
        Threading.pollerQueue.async { [weak self] in
            guard self?.isPolling.wrappedValue[publicKey] != true else { return }
            
            // Might be a race condition that the setUpPolling finishes too soon,
            // and the timer is not created, if we mark the group as is polling
            // after setUpPolling. So the poller may not work, thus misses messages
            self?.isPolling.mutate { $0[publicKey] = true }
            self?.pollRecursively(for: publicKey, using: dependencies)
        }
    }
    
    internal func getSnodeForPolling(
        for publicKey: String,
        using dependencies: Dependencies
    ) -> AnyPublisher<Snode, Error> {
        // If we don't want to poll a snode multiple times then just grab a random one from the swarm
        guard maxNodePollCount > 0 else {
            return SnodeAPI.getSwarm(for: publicKey, using: dependencies)
                .tryMap { swarm -> Snode in
                    try swarm.randomElement() ?? { throw OnionRequestAPIError.insufficientSnodes }()
                }
                .eraseToAnyPublisher()
        }
        
        // If we already have a target snode then use that
        if let targetSnode: Snode = self.targetSnode.wrappedValue {
            return Just(targetSnode)
                .setFailureType(to: Error.self)
                .eraseToAnyPublisher()
        }
        
        // Select the next unused snode from the swarm (if we've used them all then clear the used list and
        // start cycling through them again)
        return SnodeAPI.getSwarm(for: publicKey, using: dependencies)
            .tryMap { [usedSnodes = self.usedSnodes, targetSnode = self.targetSnode] swarm -> Snode in
                let unusedSnodes: Set<Snode> = swarm.subtracting(usedSnodes.wrappedValue)
                
                // If we've used all of the SNodes then clear out the used list
                if unusedSnodes.isEmpty {
                    usedSnodes.mutate { $0.removeAll() }
                }
                
                // Select the next SNode
                let nextSnode: Snode = try swarm.randomElement() ?? { throw OnionRequestAPIError.insufficientSnodes }()
                targetSnode.mutate { $0 = nextSnode }
                usedSnodes.mutate { $0.insert(nextSnode) }
                
                return nextSnode
            }
            .eraseToAnyPublisher()
    }
    
    internal func incrementPollCount(publicKey: String) {
        guard maxNodePollCount > 0 else { return }
        
        let pollCount: Int = (self.pollCount.wrappedValue[publicKey] ?? 0)
        self.pollCount.mutate { $0[publicKey] = (pollCount + 1) }
        
        // Check if we've polled the serice node too many times
        guard pollCount > maxNodePollCount else { return }
        
        // If we have polled this service node more than the maximum allowed then clear out
        // the 'targetServiceNode' value
        self.targetSnode.mutate { $0 = nil }
    }
    
    private func pollRecursively(
        for publicKey: String,
        using dependencies: Dependencies
    ) {
        guard isPolling.wrappedValue[publicKey] == true else { return }
        
        let namespaces: [SnodeAPI.Namespace] = self.namespaces
        let lastPollStart: TimeInterval = dependencies.dateNow.timeIntervalSince1970
        let lastPollInterval: TimeInterval = nextPollDelay(for: publicKey, using: dependencies)
        let getSnodePublisher: AnyPublisher<Snode, Error> = getSnodeForPolling(for: publicKey, using: dependencies)
        
        // Store the publisher intp the cancellables dictionary
        cancellables.mutate { [weak self] cancellables in
            cancellables[publicKey] = getSnodePublisher
                .flatMap { snode -> AnyPublisher<[Message], Error> in
                    Poller.poll(
                        namespaces: namespaces,
                        from: snode,
                        for: publicKey,
                        poller: self,
                        using: dependencies
                    )
                }
                .subscribe(on: Threading.pollerQueue, using: dependencies)
                .receive(on: Threading.pollerQueue, using: dependencies)
                .sink(
                    receiveCompletion: { result in
                        switch result {
                            case .failure(let error):
                                // Determine if the error should stop us from polling anymore
                                guard self?.handlePollError(error, for: publicKey, using: dependencies) == true else {
                                    return
                                }
                                
                            case .finished: break
                        }
                        
                        // Increment the poll count
                        self?.incrementPollCount(publicKey: publicKey)
                        
                        // Calculate the remaining poll delay
                        let currentTime: TimeInterval = dependencies.dateNow.timeIntervalSince1970
                        let nextPollInterval: TimeInterval = (
                            self?.nextPollDelay(for: publicKey, using: dependencies) ??
                            lastPollInterval
                        )
                        let remainingInterval: TimeInterval = max(0, nextPollInterval - (currentTime - lastPollStart))
                        
                        // Schedule the next poll
                        guard remainingInterval > 0 else {
                            return Threading.pollerQueue.async(using: dependencies) {
                                self?.pollRecursively(for: publicKey, using: dependencies)
                            }
                        }
                        
                        Threading.pollerQueue.asyncAfter(deadline: .now() + .milliseconds(Int(remainingInterval * 1000)), qos: .default, using: dependencies) {
                            self?.pollRecursively(for: publicKey, using: dependencies)
                        }
                    },
                    receiveValue: { _ in }
                )
        }
    }
    
    /// Polls the specified namespaces and processes any messages, returning an array of messages that were
    /// successfully processed
    ///
    /// **Note:** The returned messages will have already been processed by the `Poller`, they are only returned
    /// for cases where we need explicit/custom behaviours to occur (eg. Onboarding)
    public static func poll(
        namespaces: [SnodeAPI.Namespace],
        from snode: Snode,
        for publicKey: String,
        calledFromBackgroundPoller: Bool = false,
        isBackgroundPollValid: @escaping (() -> Bool) = { true },
        poller: Poller? = nil,
        using dependencies: Dependencies = Dependencies()
    ) -> AnyPublisher<[Message], Error> {
        // If the polling has been cancelled then don't continue
        guard
            (calledFromBackgroundPoller && isBackgroundPollValid()) ||
            poller?.isPolling.wrappedValue[publicKey] == true
        else {
            return Just([])
                .setFailureType(to: Error.self)
                .eraseToAnyPublisher()
        }
        
        let pollerName: String = (
            poller?.pollerName(for: publicKey) ??
            "poller with public key \(publicKey)"
        )
        let configHashes: [String] = SessionUtil.configHashes(for: publicKey)
        
        // Fetch the messages
        return SnodeAPI
            .poll(
                namespaces: namespaces,
                refreshingConfigHashes: configHashes,
                from: snode,
                associatedWith: publicKey,
                using: dependencies
            )
            .flatMap { namespacedResults -> AnyPublisher<[Message], Error> in
                guard
                    (calledFromBackgroundPoller && isBackgroundPollValid()) ||
                    poller?.isPolling.wrappedValue[publicKey] == true
                else {
                    return Just([])
                        .setFailureType(to: Error.self)
                        .eraseToAnyPublisher()
                }
                
                let allMessages: [SnodeReceivedMessage] = namespacedResults
                    .compactMap { _, result -> [SnodeReceivedMessage]? in result.data?.messages }
                    .flatMap { $0 }
                
                // No need to do anything if there are no messages
                guard !allMessages.isEmpty else {
                    if !calledFromBackgroundPoller { SNLog("Received no new messages in \(pollerName)") }
                    
                    return Just([])
                        .setFailureType(to: Error.self)
                        .eraseToAnyPublisher()
                }
                
                // Otherwise process the messages and add them to the queue for handling
                let lastHashes: [String] = namespacedResults
                    .compactMap { $0.value.data?.lastHash }
                let otherKnownHashes: [String] = namespacedResults
                    .filter { $0.key.shouldDedupeMessages }
                    .compactMap { $0.value.data?.messages.map { $0.info.hash } }
                    .reduce([], +)
                var messageCount: Int = 0
                var processedMessages: [Message] = []
                var hadValidHashUpdate: Bool = false
                var configMessageJobsToRun: [Job] = []
                var standardMessageJobsToRun: [Job] = []
                var pollerLogOutput: String = "\(pollerName) failed to process any messages"
                
                dependencies.storage.write { db in
                    let allProcessedMessages: [ProcessedMessage] = allMessages
                        .compactMap { message -> ProcessedMessage? in
                            do {
                                return try Message.processRawReceivedMessage(db, rawMessage: message)
                            }
                            catch {
                                switch error {
                                    // Ignore duplicate & selfSend message errors (and don't bother logging
                                    // them as there will be a lot since we each service node duplicates messages)
                                    case DatabaseError.SQLITE_CONSTRAINT_UNIQUE,
                                        MessageReceiverError.duplicateMessage,
                                        MessageReceiverError.duplicateControlMessage,
                                        MessageReceiverError.selfSend:
                                        break
                                        
                                    case MessageReceiverError.duplicateMessageNewSnode:
                                        hadValidHashUpdate = true
                                        break
                                        
                                    case DatabaseError.SQLITE_ABORT:
                                        // In the background ignore 'SQLITE_ABORT' (it generally means
                                        // the BackgroundPoller has timed out
                                        if !calledFromBackgroundPoller {
                                            SNLog("Failed to the database being suspended (running in background with no background task).")
                                        }
                                        break
                                        
                                    default: SNLog("Failed to deserialize envelope due to error: \(error).")
                                }
                                
                                return nil
                            }
                        }
                    
                    // Add a job to process the config messages first
                    let configJobIds: [Int64] = allProcessedMessages
                        .filter { $0.messageInfo.variant == .sharedConfigMessage }
                        .grouped { threadId, _, _, _ in threadId }
                        .compactMap { threadId, threadMessages in
                            messageCount += threadMessages.count
                            processedMessages += threadMessages.map { $0.messageInfo.message }
                            
                            let jobToRun: Job? = Job(
                                variant: .configMessageReceive,
                                behaviour: .runOnce,
                                threadId: threadId,
                                details: ConfigMessageReceiveJob.Details(
                                    messages: threadMessages.map { $0.messageInfo },
                                    calledFromBackgroundPoller: calledFromBackgroundPoller
                                )
                            )
                            configMessageJobsToRun = configMessageJobsToRun.appending(jobToRun)
                            
                            // If we are force-polling then add to the JobRunner so they are
                            // persistent and will retry on the next app run if they fail but
                            // don't let them auto-start
                            let updatedJob: Job? = dependencies.jobRunner
                                .add(
                                    db,
                                    job: jobToRun,
                                    canStartJob: !calledFromBackgroundPoller,
                                    using: dependencies
                                )
                                
                            return updatedJob?.id
                        }
                    
                    // Add jobs for processing non-config messages which are dependant on the config message
                    // processing jobs
                    allProcessedMessages
                        .filter { $0.messageInfo.variant != .sharedConfigMessage }
                        .grouped { threadId, _, _, _ in threadId }
                        .forEach { threadId, threadMessages in
                            messageCount += threadMessages.count
                            processedMessages += threadMessages.map { $0.messageInfo.message }
                            
                            let jobToRun: Job? = Job(
                                variant: .messageReceive,
                                behaviour: .runOnce,
                                threadId: threadId,
                                details: MessageReceiveJob.Details(
                                    messages: threadMessages.map { $0.messageInfo },
                                    calledFromBackgroundPoller: calledFromBackgroundPoller
                                )
                            )
                            standardMessageJobsToRun = standardMessageJobsToRun.appending(jobToRun)
                            
                            // If we are force-polling then add to the JobRunner so they are
                            // persistent and will retry on the next app run if they fail but
                            // don't let them auto-start
                            let updatedJob: Job? = dependencies.jobRunner
                                .add(
                                    db,
                                    job: jobToRun,
                                    canStartJob: !calledFromBackgroundPoller,
                                    using: dependencies
                                )
                            
                            // Create the dependency between the jobs
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
                                    SNLog("Failed to add dependency between config processing and non-config processing messageReceive jobs.")
                                }
                            }
                        }
                    
                    // Set the output for logging
                    pollerLogOutput = "Received \(messageCount) new message\(messageCount == 1 ? "" : "s") in \(pollerName) (duplicates: \(allMessages.count - messageCount))"
                    
                    // Clean up message hashes and add some logs about the poll results
                    if allMessages.isEmpty && !hadValidHashUpdate {
                        pollerLogOutput = "Received \(allMessages.count) new message\(allMessages.count == 1 ? "" : "s") in \(pollerName), all duplicates - marking the hash we polled with as invalid"
                        
                        // Update the cached validity of the messages
                        try SnodeReceivedMessageInfo.handlePotentialDeletedOrInvalidHash(
                            db,
                            potentiallyInvalidHashes: lastHashes,
                            otherKnownValidHashes: otherKnownHashes
                        )
                    }
                }
                
                // Only output logs if it isn't the background poller
                if !calledFromBackgroundPoller {
                    SNLog(pollerLogOutput)
                }
                
                // If we aren't runing in a background poller then just finish immediately
                guard calledFromBackgroundPoller else {
                    return Just(processedMessages)
                        .setFailureType(to: Error.self)
                        .eraseToAnyPublisher()
                }
                
                // We want to try to handle the receive jobs immediately in the background
                return Publishers
                    .MergeMany(
                        configMessageJobsToRun.map { job -> AnyPublisher<Void, Error> in
                            Deferred {
                                Future<Void, Error> { resolver in
                                    // Note: In the background we just want jobs to fail silently
                                    ConfigMessageReceiveJob.run(
                                        job,
                                        queue: Threading.pollerQueue,
                                        success: { _, _, _ in resolver(Result.success(())) },
                                        failure: { _, _, _, _ in resolver(Result.success(())) },
                                        deferred: { _, _ in resolver(Result.success(())) },
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
                                standardMessageJobsToRun.map { job -> AnyPublisher<Void, Error> in
                                    Deferred {
                                        Future<Void, Error> { resolver in
                                            // Note: In the background we just want jobs to fail silently
                                            MessageReceiveJob.run(
                                                job,
                                                queue: Threading.pollerQueue,
                                                success: { _, _, _ in resolver(Result.success(())) },
                                                failure: { _, _, _, _ in resolver(Result.success(())) },
                                                deferred: { _, _ in resolver(Result.success(())) },
                                                using: dependencies
                                            )
                                        }
                                    }
                                    .eraseToAnyPublisher()
                                }
                            )
                            .collect()
                    }
                    .map { _ in processedMessages }
                    .eraseToAnyPublisher()
            }
            .eraseToAnyPublisher()
    }
}
