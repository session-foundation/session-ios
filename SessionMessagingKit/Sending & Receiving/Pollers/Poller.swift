// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import Sodium
import SessionSnodeKit
import SessionUtilitiesKit

public class Poller {
    private var timers: Atomic<[String: Timer]> = Atomic([:])
    internal var isPolling: Atomic<[String: Bool]> = Atomic([:])
    internal var pollCount: Atomic<[String: Int]> = Atomic([:])
    internal var failureCount: Atomic<[String: Int]> = Atomic([:])
    
    // MARK: - Settings
    
    /// The namespaces which this poller queries
    internal var namespaces: [SnodeAPI.Namespace] {
        preconditionFailure("abstract class - override in subclass")
    }
    
    /// The number of times the poller can poll before swapping to a new snode
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
        timers.mutate { $0[publicKey]?.invalidate() }
    }
    
    // MARK: - Abstract Methods
    
    /// The name for this poller to appear in the logs
    internal func pollerName(for publicKey: String) -> String {
        preconditionFailure("abstract class - override in subclass")
    }
    
    internal func nextPollDelay(for publicKey: String) -> TimeInterval {
        preconditionFailure("abstract class - override in subclass")
    }
    
    internal func getSnodeForPolling(
        for publicKey: String
    ) -> AnyPublisher<Snode, Error> {
        preconditionFailure("abstract class - override in subclass")
    }
    
    internal func handlePollError(_ error: Error, for publicKey: String, using dependencies: SMKDependencies) {
        preconditionFailure("abstract class - override in subclass")
    }

    // MARK: - Private API
    
    internal func startIfNeeded(for publicKey: String) {
        // Run on the 'pollerQueue' to ensure any 'Atomic' access doesn't block the main thread
        // on startup
        Threading.pollerQueue.async { [weak self] in
            guard self?.isPolling.wrappedValue[publicKey] != true else { return }
            
            // Might be a race condition that the setUpPolling finishes too soon,
            // and the timer is not created, if we mark the group as is polling
            // after setUpPolling. So the poller may not work, thus misses messages
            self?.isPolling.mutate { $0[publicKey] = true }
            self?.setUpPolling(for: publicKey)
        }
    }
    
    /// We want to initially trigger a poll against the target service node and then run the recursive polling,
    /// if an error is thrown during the poll then this should automatically restart the polling
    internal func setUpPolling(
        for publicKey: String,
        using dependencies: SMKDependencies = SMKDependencies(
            subscribeQueue: Threading.pollerQueue,
            receiveQueue: Threading.pollerQueue
        )
    ) {
        guard isPolling.wrappedValue[publicKey] == true else { return }
        
        let namespaces: [SnodeAPI.Namespace] = self.namespaces
        
        getSnodeForPolling(for: publicKey)
            .subscribe(on: dependencies.subscribeQueue, immediatelyIfMain: true)
            .flatMap { snode -> AnyPublisher<[Message], Error> in
                Poller.poll(
                    namespaces: namespaces,
                    from: snode,
                    for: publicKey,
                    poller: self,
                    using: dependencies
                )
            }
            .receive(on: dependencies.receiveQueue, immediatelyIfMain: true)
            .sinkUntilComplete(
                receiveCompletion: { [weak self] result in
                    switch result {
                        case .finished: self?.pollRecursively(for: publicKey, using: dependencies)
                        case .failure(let error):
                            guard self?.isPolling.wrappedValue[publicKey] == true else { return }
                            
                            self?.handlePollError(error, for: publicKey, using: dependencies)
                    }
                }
            )
    }

    private func pollRecursively(
        for publicKey: String,
        using dependencies: SMKDependencies = SMKDependencies()
    ) {
        guard isPolling.wrappedValue[publicKey] == true else { return }
        
        let namespaces: [SnodeAPI.Namespace] = self.namespaces
        let nextPollInterval: TimeInterval = nextPollDelay(for: publicKey)
        
        timers.mutate {
            $0[publicKey] = Timer.scheduledTimerOnMainThread(
                withTimeInterval: nextPollInterval,
                repeats: false
            ) { [weak self] timer in
                timer.invalidate()

                self?.getSnodeForPolling(for: publicKey)
                    .subscribe(on: dependencies.subscribeQueue, immediatelyIfMain: true)
                    .flatMap { snode -> AnyPublisher<[Message], Error> in
                        Poller.poll(
                            namespaces: namespaces,
                            from: snode,
                            for: publicKey,
                            poller: self,
                            using: dependencies
                        )
                    }
                    .receive(on: dependencies.receiveQueue, immediatelyIfMain: true)
                    .sinkUntilComplete(
                        receiveCompletion: { result in
                            switch result {
                                case .failure(let error): self?.handlePollError(error, for: publicKey, using: dependencies)
                                case .finished:
                                    let maxNodePollCount: UInt = (self?.maxNodePollCount ?? 0)

                                    // If we have polled this service node more than the
                                    // maximum allowed then throw an error so the parent
                                    // loop can restart the polling
                                    if maxNodePollCount > 0 {
                                        let pollCount: Int = (self?.pollCount.wrappedValue[publicKey] ?? 0)
                                        self?.pollCount.mutate { $0[publicKey] = (pollCount + 1) }
                                        
                                        guard pollCount < maxNodePollCount else {
                                            let newSnodeNextPollInterval: TimeInterval = (self?.nextPollDelay(for: publicKey) ?? nextPollInterval)
                                            
                                            self?.timers.mutate {
                                                $0[publicKey] = Timer.scheduledTimerOnMainThread(
                                                    withTimeInterval: newSnodeNextPollInterval,
                                                    repeats: false
                                                ) { [weak self] timer in
                                                    timer.invalidate()
                                                    
                                                    self?.pollCount.mutate { $0[publicKey] = 0 }
                                                    self?.setUpPolling(for: publicKey, using: dependencies)
                                                }
                                            }
                                            return
                                        }
                                    }

                                    // Otherwise just loop
                                    self?.pollRecursively(for: publicKey, using: dependencies)
                            }
                        }
                    )
            }
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
        using dependencies: SMKDependencies = SMKDependencies(
            receiveQueue: Threading.pollerQueue
        )
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
                
                Storage.shared.write { db in
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
                            let updatedJob: Job? = JobRunner
                                .add(db, job: jobToRun, canStartJob: !calledFromBackgroundPoller)
                                
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
                            let updatedJob: Job? = JobRunner
                                .add(db, job: jobToRun, canStartJob: !calledFromBackgroundPoller)
                            
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
                    
                    // Clean up message hashes and add some logs about the poll results
                    if allMessages.isEmpty && !hadValidHashUpdate {
                        if !calledFromBackgroundPoller {
                            SNLog("Received \(allMessages.count) new message\(allMessages.count == 1 ? "" : "s"), all duplicates - marking the hash we polled with as invalid")
                        }
                        
                        // Update the cached validity of the messages
                        try SnodeReceivedMessageInfo.handlePotentialDeletedOrInvalidHash(
                            db,
                            potentiallyInvalidHashes: lastHashes,
                            otherKnownValidHashes: otherKnownHashes
                        )
                    }
                    else if !calledFromBackgroundPoller {
                        SNLog("Received \(messageCount) new message\(messageCount == 1 ? "" : "s") in \(pollerName) (duplicates: \(allMessages.count - messageCount))")
                    }
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
                                        queue: dependencies.receiveQueue,
                                        success: { _, _ in resolver(Result.success(())) },
                                        failure: { _, _, _ in resolver(Result.success(())) },
                                        deferred: { _ in resolver(Result.success(())) }
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
                                                queue: dependencies.receiveQueue,
                                                success: { _, _ in resolver(Result.success(())) },
                                                failure: { _, _, _ in resolver(Result.success(())) },
                                                deferred: { _ in resolver(Result.success(())) }
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
