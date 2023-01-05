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
        
        // If we don't have a userKeyPair yet then there is no need to sync the configuration
        // as the user doesn't exist yet (this will get triggered on the first launch of a
        // fresh install due to the migrations getting run)
        guard
            let pendingSwarmConfigChanges: [SingleDestinationChanges] = Storage.shared
                .read({ db -> [SessionUtil.OutgoingConfResult]? in
                    guard
                        Identity.userExists(db),
                        let ed25519SecretKey: [UInt8] = Identity.fetchUserEd25519KeyPair(db)?.secretKey
                    else { return nil }
                    
                    return try SessionUtil.pendingChanges(
                        db,
                        userPublicKey: getUserHexEncodedPublicKey(db),
                        ed25519SecretKey: ed25519SecretKey
                    )
                })?
                .grouped(by: { $0.destination })
                .map({ (destination: Message.Destination, value: [SessionUtil.OutgoingConfResult]) -> SingleDestinationChanges in
                    SingleDestinationChanges(
                        destination: destination,
                        messages: value,
                        allOldHashes: value
                            .map { ($0.oldMessageHashes ?? []) }
                            .reduce([], +)
                            .asSet()
                    )
                })
        else {
            failure(job, StorageError.generic, false)
            return
        }
        
        // If there are no pending changes then the job can just complete (next time something
        // is updated we want to try and run immediately so don't scuedule another run in this case)
        guard !pendingSwarmConfigChanges.isEmpty else {
            success(job, true)
            return
        }
        
        Storage.shared
            .readPublisher { db in
                try pendingSwarmConfigChanges
                    .map { (change: SingleDestinationChanges) -> (messages: [TargetedMessage], allOldHashes: Set<String>) in
                        (
                            messages: try change.messages
                                .map { (outgoingConf: SessionUtil.OutgoingConfResult) -> TargetedMessage in
                                    TargetedMessage(
                                        sendData: try MessageSender.preparedSendData(
                                            db,
                                            message: outgoingConf.message,
                                            to: change.destination,
                                            interactionId: nil
                                        ),
                                        namespace: outgoingConf.namespace,
                                        oldHashes: (outgoingConf.oldMessageHashes ?? [])
                                    )
                                },
                            allOldHashes: change.allOldHashes
                        )
                    }
            }
            .subscribe(on: queue)
            .receive(on: queue)
            .flatMap { (pendingSwarmChange: [(messages: [TargetedMessage], allOldHashes: Set<String>)]) -> AnyPublisher<[HTTP.BatchResponse], Error> in
                Publishers
                    .MergeMany(
                        pendingSwarmChange
                            .map { (messages: [TargetedMessage], oldHashes: Set<String>) in
                                // Note: We do custom sending logic here because we want to batch the
                                // sending and deletion of messages within the same swarm
                                SnodeAPI
                                    .sendConfigMessages(
                                        messages
                                            .compactMap { targetedMessage -> SnodeAPI.TargetedMessage? in
                                                targetedMessage.sendData.snodeMessage
                                                    .map { ($0, targetedMessage.namespace) }
                                            },
                                        oldHashes: Array(oldHashes)
                                    )
                            }
                    )
                    .collect()
                    .eraseToAnyPublisher()
            }
            .map { (responses: [HTTP.BatchResponse]) -> [SuccessfulChange] in
                // Process the response data into an easy to understand for (this isn't strictly
                // needed but the code gets convoluted without this)
                zip(responses, pendingSwarmConfigChanges)
                    .compactMap { (batchResponse: HTTP.BatchResponse, pendingSwarmChange: SingleDestinationChanges) -> [SuccessfulChange]? in
                        let maybePublicKey: String? = {
                            switch pendingSwarmChange.destination {
                                case .contact(let publicKey), .closedGroup(let publicKey):
                                    return publicKey
                                    
                                default: return nil
                            }
                        }()
                        
                        // If we don't have a publicKey then this is an invalid config
                        guard let publicKey: String = maybePublicKey else { return nil }
                        
                        // Need to know if we successfully deleted old messages (if we didn't then
                        // we want to keep the old hashes so we can delete them the next time)
                        let didDeleteOldConfigMessages: Bool = {
                            guard
                                let subResponse: HTTP.BatchSubResponse<DeleteMessagesResponse> = (batchResponse.responses.last as? HTTP.BatchSubResponse<DeleteMessagesResponse>),
                                200...299 ~= subResponse.code
                            else { return false }
                            
                            return true
                        }()
                        
                        return zip(batchResponse.responses, pendingSwarmChange.messages)
                            .reduce(into: []) { (result: inout [SuccessfulChange], next: ResponseChange) in
                                // If the request wasn't successful then just ignore it (the next
                                // config sync will try make the changes again
                                guard
                                    let subResponse: HTTP.BatchSubResponse<SendMessagesResponse> = (next.response as? HTTP.BatchSubResponse<SendMessagesResponse>),
                                    200...299 ~= subResponse.code,
                                    let sendMessageResponse: SendMessagesResponse = subResponse.body
                                else { return }
                                
                                result.append(
                                    SuccessfulChange(
                                        message: next.change.message,
                                        publicKey: publicKey,
                                        updatedHashes: (didDeleteOldConfigMessages ?
                                            [sendMessageResponse.hash] :
                                            (next.change.oldMessageHashes ?? [])
                                                .appending(sendMessageResponse.hash)
                                        )
                                    )
                                )
                            }
                    }
                    .flatMap { $0 }
            }
            .map { (successfulChanges: [SuccessfulChange]) -> [ConfigDump] in
                // Now that we have the successful changes, we need to mark them as pushed and
                // generate any config dumps which need to be stored
                successfulChanges
                    .compactMap { successfulChange -> ConfigDump? in
                        // Updating the pushed state returns a flag indicating whether the config
                        // needs to be dumped
                        guard SessionUtil.markAsPushed(message: successfulChange.message, publicKey: successfulChange.publicKey) else {
                            return nil
                        }
                        
                        let variant: ConfigDump.Variant = successfulChange.message.kind.configDumpVariant
                        let atomicConf: Atomic<UnsafeMutablePointer<config_object>?> = SessionUtil.config(
                            for: variant,
                            publicKey: successfulChange.publicKey
                        )
                        
                        return try? SessionUtil.createDump(
                            conf: atomicConf.wrappedValue,
                            for: variant,
                            publicKey: successfulChange.publicKey,
                            messageHashes: successfulChange.updatedHashes
                        )
                    }
            }
            .sinkUntilComplete(
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
                                .fetchOne(db),
                            !JobRunner.isCurrentlyRunning(existingJob)
                        {
                            _ = try existingJob
                                .with(nextRunTimestamp: nextRunTimestamp)
                                .saved(db)
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

// MARK: - Convenience Types

public extension ConfigurationSyncJob {
    fileprivate struct SingleDestinationChanges {
        let destination: Message.Destination
        let messages: [SessionUtil.OutgoingConfResult]
        let allOldHashes: Set<String>
    }
    
    fileprivate struct TargetedMessage {
        let sendData: MessageSender.PreparedSendData
        let namespace: SnodeAPI.Namespace
        let oldHashes: [String]
    }
    
    typealias ResponseChange = (response: Codable, change: SessionUtil.OutgoingConfResult)
    
    fileprivate struct SuccessfulChange {
        let message: SharedConfigMessage
        let publicKey: String
        let updatedHashes: [String]
    }
}

// MARK: - Convenience

public extension ConfigurationSyncJob {
    static func enqueue(_ db: Database? = nil) {
        guard let db: Database = db else {
            Storage.shared.writeAsync { ConfigurationSyncJob.enqueue($0) }
            return
        }
        
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
            job: ConfigurationSyncJob.createOrUpdateIfNeeded(db)
        )
    }
    
    @discardableResult static func createOrUpdateIfNeeded(_ db: Database) -> Job {
        // Try to get an existing job (if there is one that's not running)
        if
            let existingJob: Job = try? Job
                .filter(Job.Columns.variant == Job.Variant.configurationSync)
                .fetchOne(db),
            !JobRunner.isCurrentlyRunning(existingJob)
        {
            return existingJob
        }
        
        // Otherwise create a new job
        return Job(
            variant: .configurationSync,
            behaviour: .recurring
        )
    }
    
    static func run() -> AnyPublisher<Void, Error> {
        // FIXME: Remove this once `useSharedUtilForUserConfig` is permanent
        guard Features.useSharedUtilForUserConfig else {
            return Storage.shared
                .writePublisher { db -> MessageSender.PreparedSendData in
                    // If we don't have a userKeyPair yet then there is no need to sync the configuration
                    // as the user doesn't exist yet (this will get triggered on the first launch of a
                    // fresh install due to the migrations getting run)
                    guard Identity.userExists(db) else { throw StorageError.generic }
                    
                    let publicKey: String = getUserHexEncodedPublicKey(db)
                    
                    return try MessageSender.preparedSendData(
                        db,
                        message: try ConfigurationMessage.getCurrent(db),
                        to: Message.Destination.contact(publicKey: publicKey),
                        interactionId: nil
                    )
                }
                .subscribe(on: DispatchQueue.global(qos: .userInitiated))
                .receive(on: DispatchQueue.global(qos: .userInitiated))
                .flatMap { MessageSender.sendImmediate(preparedSendData: $0) }
                .eraseToAnyPublisher()
        }
        
        // Trigger the job emitting the result when completed
        return Future { resolver in
            ConfigurationSyncJob.run(
                Job(variant: .configurationSync),
                queue: DispatchQueue.global(qos: .userInitiated),
                success: { _, _ in resolver(Result.success(())) },
                failure: { _, error, _ in resolver(Result.failure(error ?? HTTPError.generic)) },
                deferred: { _ in }
            )
        }
        .eraseToAnyPublisher()
    }
}
