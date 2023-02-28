// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionUtil
import SessionSnodeKit
import SessionUtilitiesKit

public enum ConfigurationSyncJob: JobExecutor {
    public static let maxFailureCount: Int = -1
    public static let requiresThreadId: Bool = false
    public static let requiresInteractionId: Bool = false
    private static let maxRunFrequency: TimeInterval = 3
    
    public static func run(
        _ job: Job,
        queue: DispatchQueue,
        success: @escaping (Job, Bool) -> (),
        failure: @escaping (Job, Error?, Bool) -> (),
        deferred: @escaping (Job) -> ()
    ) {
        guard Features.useSharedUtilForUserConfig else {
            success(job, true)
            return
        }
        
        // On startup it's possible for multiple ConfigSyncJob's to run at the same time (which is
        // redundant) so check if there is another job already running and, if so, defer this job
        let jobDetails: [Int64: Data?] = JobRunner.defailsForCurrentlyRunningJobs(of: .configurationSync)
        
        guard jobDetails.setting(job.id, nil).count == 0 else {
            deferred(job)   // We will re-enqueue when needed
            return
        }
        
        // If we don't have a userKeyPair yet then there is no need to sync the configuration
        // as the user doesn't exist yet (this will get triggered on the first launch of a
        // fresh install due to the migrations getting run)
        guard
            let publicKey: String = job.threadId,
            let pendingConfigChanges: [SessionUtil.OutgoingConfResult] = Storage.shared
                .read({ db in try SessionUtil.pendingChanges(db, publicKey: publicKey) })
        else {
            failure(job, StorageError.generic, false)
            return
        }
        
        // If there are no pending changes then the job can just complete (next time something
        // is updated we want to try and run immediately so don't scuedule another run in this case)
        guard !pendingConfigChanges.isEmpty else {
            success(job, true)
            return
        }
        
        // Identify the destination and merge all obsolete hashes into a single set
        let destination: Message.Destination = (publicKey == getUserHexEncodedPublicKey() ?
            Message.Destination.contact(publicKey: publicKey) :
            Message.Destination.closedGroup(groupPublicKey: publicKey)
        )
        let allObsoleteHashes: Set<String> = pendingConfigChanges
            .map { $0.obsoleteHashes }
            .reduce([], +)
            .asSet()
        
        Storage.shared
            .readPublisher(receiveOn: queue) { db in
                try pendingConfigChanges.map { change -> MessageSender.PreparedSendData in
                    try MessageSender.preparedSendData(
                        db,
                        message: change.message,
                        to: destination,
                        namespace: change.namespace,
                        interactionId: nil
                    )
                }
            }
            .flatMap { (changes: [MessageSender.PreparedSendData]) -> AnyPublisher<HTTP.BatchResponse, Error> in
                SnodeAPI
                    .sendConfigMessages(
                        changes.compactMap { change in
                            guard
                                let namespace: SnodeAPI.Namespace = change.namespace,
                                let snodeMessage: SnodeMessage = change.snodeMessage
                            else { return nil }
                            
                            return (snodeMessage, namespace)
                        },
                        allObsoleteHashes: Array(allObsoleteHashes)
                    )
            }
            .receive(on: queue)
            .map { (response: HTTP.BatchResponse) -> [ConfigDump] in
                /// The number of responses returned might not match the number of changes sent but they will be returned
                /// in the same order, this means we can just `zip` the two arrays as it will take the smaller of the two and
                /// correctly align the response to the change
                zip(response.responses, pendingConfigChanges)
                    .compactMap { (subResponse: Codable, change: SessionUtil.OutgoingConfResult) in
                        /// If the request wasn't successful then just ignore it (the next time we sync this config we will try
                        /// to send the changes again)
                        guard
                            let typedResponse: HTTP.BatchSubResponse<SendMessagesResponse> = (subResponse as? HTTP.BatchSubResponse<SendMessagesResponse>),
                            200...299 ~= typedResponse.code,
                            !typedResponse.failedToParseBody,
                            let sendMessageResponse: SendMessagesResponse = typedResponse.body
                        else { return nil }
                        
                        /// Since this change was successful we need to mark it as pushed and generate any config dumps
                        /// which need to be stored
                        return SessionUtil.markingAsPushed(
                            message: change.message,
                            serverHash: sendMessageResponse.hash,
                            publicKey: publicKey
                        )
                    }
            }
            .sinkUntilComplete(
                receiveCompletion: { result in
                    switch result {
                        case .finished: break
                        case .failure(let error): failure(job, error, false)
                    }
                },
                receiveValue: { (configDumps: [ConfigDump]) in
                    // Flag to indicate whether the job should be finished or will run again
                    var shouldFinishCurrentJob: Bool = false
                    
                    // Lastly we need to save the updated dumps to the database
                    let updatedJob: Job? = Storage.shared.write { db in
                        // Save the updated dumps to the database
                        try configDumps.forEach { try $0.save(db) }
                        
                        // When we complete the 'ConfigurationSync' job we want to immediately schedule
                        // another one with a 'nextRunTimestamp' set to the 'maxRunFrequency' value to
                        // throttle the config sync requests
                        let nextRunTimestamp: TimeInterval = (Date().timeIntervalSince1970 + maxRunFrequency)
                        
                        // If another 'ConfigurationSync' job was scheduled then update that one
                        // to run at 'nextRunTimestamp' and make the current job stop
                        if
                            let existingJob: Job = try? Job
                                .filter(Job.Columns.id != job.id)
                                .filter(Job.Columns.variant == Job.Variant.configurationSync)
                                .filter(Job.Columns.threadId == publicKey)
                                .fetchOne(db)
                        {
                            // If the next job isn't currently running then delay it's start time
                            // until the 'nextRunTimestamp'
                            if !JobRunner.isCurrentlyRunning(existingJob) {
                                _ = try existingJob
                                    .with(nextRunTimestamp: nextRunTimestamp)
                                    .saved(db)
                            }
                            
                            // If there is another job then we should finish this one
                            shouldFinishCurrentJob = true
                            return job
                        }
                        
                        return try job
                            .with(nextRunTimestamp: nextRunTimestamp)
                            .saved(db)
                    }
                    
                    success((updatedJob ?? job), shouldFinishCurrentJob)
                }
            )
    }
}

// MARK: - Convenience

public extension ConfigurationSyncJob {
        
    static func enqueue(_ db: Database, publicKey: String) {
        // FIXME: Remove this once `useSharedUtilForUserConfig` is permanent
        guard Features.useSharedUtilForUserConfig else {
            // If we don't have a userKeyPair (or name) yet then there is no need to sync the
            // configuration as the user doesn't fully exist yet (this will get triggered on
            // the first launch of a fresh install due to the migrations getting run and a few
            // times during onboarding)
            guard
                Identity.userExists(db),
                !Profile.fetchOrCreateCurrentUser(db).name.isEmpty,
                let legacyConfigMessage: Message = try? ConfigurationMessage.getCurrent(db)
            else { return }
            
            let publicKey: String = getUserHexEncodedPublicKey(db)
            
            JobRunner.add(
                db,
                job: Job(
                    variant: .messageSend,
                    threadId: publicKey,
                    details: MessageSendJob.Details(
                        destination: Message.Destination.contact(publicKey: publicKey),
                        message: legacyConfigMessage
                    )
                )
            )
            return
        }
        
        // Upsert a config sync job (if there is already an pending one then no need
        // to add another one)
        JobRunner.upsert(
            db,
            job: ConfigurationSyncJob.createOrUpdateIfNeeded(db, publicKey: publicKey)
        )
    }
    
    @discardableResult static func createOrUpdateIfNeeded(_ db: Database, publicKey: String) -> Job {
        // Try to get an existing job (if there is one that's not running)
        if
            let existingJobs: [Job] = try? Job
                .filter(Job.Columns.variant == Job.Variant.configurationSync)
                .filter(Job.Columns.threadId == publicKey)
                .fetchAll(db),
            let existingJob: Job = existingJobs.first(where: { !JobRunner.isCurrentlyRunning($0) })
        {
            return existingJob
        }
        
        // Otherwise create a new job
        return Job(
            variant: .configurationSync,
            behaviour: .recurring,
            threadId: publicKey
        )
    }
    
    static func run() -> AnyPublisher<Void, Error> {
        // FIXME: Remove this once `useSharedUtilForUserConfig` is permanent
        guard Features.useSharedUtilForUserConfig else {
            return Storage.shared
                .writePublisher(receiveOn: DispatchQueue.global(qos: .userInitiated)) { db -> MessageSender.PreparedSendData in
                    // If we don't have a userKeyPair yet then there is no need to sync the configuration
                    // as the user doesn't exist yet (this will get triggered on the first launch of a
                    // fresh install due to the migrations getting run)
                    guard Identity.userExists(db) else { throw StorageError.generic }
                    
                    let publicKey: String = getUserHexEncodedPublicKey(db)
                    
                    return try MessageSender.preparedSendData(
                        db,
                        message: try ConfigurationMessage.getCurrent(db),
                        to: Message.Destination.contact(publicKey: publicKey),
                        namespace: .default,
                        interactionId: nil
                    )
                }
                .flatMap { MessageSender.sendImmediate(preparedSendData: $0) }
                .eraseToAnyPublisher()
        }
        
        // Trigger the job emitting the result when completed
        return Deferred {
            Future { resolver in
                ConfigurationSyncJob.run(
                    Job(variant: .configurationSync),
                    queue: DispatchQueue.global(qos: .userInitiated),
                    success: { _, _ in resolver(Result.success(())) },
                    failure: { _, error, _ in resolver(Result.failure(error ?? HTTPError.generic)) },
                    deferred: { _ in }
                )
            }
        }
        .eraseToAnyPublisher()
    }
}
