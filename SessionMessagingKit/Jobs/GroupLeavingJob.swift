// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionUtilitiesKit
import SessionNetworkingKit

// MARK: - Log.Category

private extension Log.Category {
    static let cat: Log.Category = .create("GroupLeavingJob", defaultLevel: .info)
}

// MARK: - GroupLeavingJob

public enum GroupLeavingJob: JobExecutor {
    public static var maxFailureCount: Int = 0
    public static var requiresThreadId: Bool = true
    public static var requiresInteractionId: Bool = true
    
    public static func run<S: Scheduler>(
        _ job: Job,
        scheduler: S,
        success: @escaping (Job, Bool) -> Void,
        failure: @escaping (Job, Error, Bool) -> Void,
        deferred: @escaping (Job) -> Void,
        using dependencies: Dependencies
    ) {
        guard
            let detailsData: Data = job.details,
            let details: Details = try? JSONDecoder(using: dependencies).decode(Details.self, from: detailsData),
            let threadId: String = job.threadId,
            let interactionId: Int64 = job.interactionId
        else { return failure(job, JobRunnerError.missingRequiredDetails, true) }
        
        let destination: Message.Destination = .group(publicKey: threadId)
        
        dependencies[singleton: .storage]
            .writePublisher(updates: { db -> RequestType in
                guard (try? ClosedGroup.exists(db, id: threadId)) == true else {
                    Log.error(.cat, "Failed due to non-existent group")
                    throw MessageError.invalidGroupUpdate("Could not retrieve group")
                }
                
                let userSessionId: SessionId = dependencies[cache: .general].sessionId
                let isAdminUser: Bool = GroupMember
                    .filter(GroupMember.Columns.groupId == threadId)
                    .filter(GroupMember.Columns.profileId == userSessionId.hexString)
                    .filter(GroupMember.Columns.role == GroupMember.Role.admin)
                    .isNotEmpty(db)
                let numAdminUsers: Int = (try? GroupMember
                    .filter(GroupMember.Columns.groupId == threadId)
                    .filter(GroupMember.Columns.role == GroupMember.Role.admin)
                    .distinct()
                    .fetchCount(db))
                    .defaulting(to: 0)
                let finalBehaviour: Details.Behaviour = {
                    guard
                        dependencies.mutate(cache: .libSession, { cache in
                            !cache.wasKickedFromGroup(groupSessionId: SessionId(.group, hex: threadId)) ||
                            !cache.groupIsDestroyed(groupSessionId: SessionId(.group, hex: threadId))
                        })
                    else { return .delete }
                    
                    return details.behaviour
                }()
                
                switch (finalBehaviour, isAdminUser, (isAdminUser && numAdminUsers == 1)) {
                    case (.leave, _, false):
                        let disappearingConfig: DisappearingMessagesConfiguration? = try? DisappearingMessagesConfiguration.fetchOne(db, id: threadId)
                        let authMethod: AuthenticationMethod = try Authentication.with(db, swarmPublicKey: threadId, using: dependencies)
                        
                        return .sendLeaveMessage(authMethod, disappearingConfig)
                        
                    case (.delete, true, _), (.leave, true, true):
                        let groupSessionId: SessionId = SessionId(.group, hex: threadId)
                        
                        /// Skip the automatic config sync because we want to perform it synchronously as part of this job
                        try dependencies.mutate(cache: .libSession) { cache in
                            try cache.withCustomBehaviour(.skipAutomaticConfigSync, for: groupSessionId) {
                                try cache.deleteGroupForEveryone(db, groupSessionId: groupSessionId)
                            }
                        }
                        
                        return .configSync
                    
                    case (.delete, false, _): return .configSync
                    default: throw MessageError.invalidGroupUpdate("Unsupported group leaving configuration")
                }
            })
            .tryFlatMap { requestType -> AnyPublisher<Void, Error> in
                switch requestType {
                    case .sendLeaveMessage(let authMethod, let disappearingConfig):
                        return try Network.SnodeAPI
                            .preparedBatch(
                                requests: [
                                    /// Don't expire the `GroupUpdateMemberLeftMessage` as that's not a UI-based
                                    /// message (it's an instruction for admin devices)
                                    try MessageSender.preparedSend(
                                        message: GroupUpdateMemberLeftMessage(),
                                        to: destination,
                                        namespace: destination.defaultNamespace,
                                        interactionId: job.interactionId,
                                        attachments: nil,
                                        authMethod: authMethod,
                                        onEvent: MessageSender.standardEventHandling(using: dependencies),
                                        using: dependencies
                                    ),
                                    try MessageSender.preparedSend(
                                        message: GroupUpdateMemberLeftNotificationMessage()
                                            .with(disappearingConfig),
                                        to: destination,
                                        namespace: destination.defaultNamespace,
                                        interactionId: nil,
                                        attachments: nil,
                                        authMethod: authMethod,
                                        onEvent: MessageSender.standardEventHandling(using: dependencies),
                                        using: dependencies
                                    )
                                ],
                                requireAllBatchResponses: false,
                                swarmPublicKey: threadId,
                                using: dependencies
                            )
                            .send(using: dependencies)
                            .map { _ in () }
                            .eraseToAnyPublisher()
                        
                    case .configSync:
                        return ConfigurationSyncJob
                            .run(swarmPublicKey: threadId, using: dependencies)
                            .map { _ in () }
                            .eraseToAnyPublisher()
                }
            }
            .tryCatch { error -> AnyPublisher<Void, Error> in
                /// If it failed due to one of these errors then clear out any associated data (as the `SessionThread` exists but
                /// either the data required to send the `MEMBER_LEFT` message doesn't or the user has had their access to the
                /// group revoked which would leave the user in a state where they can't leave the group)
                switch (error as? MessageError, error as? SnodeAPIError, error as? CryptoError) {
                    case (.invalidGroupUpdate, _, _), (.encodingFailed, _, _),
                        (_, .unauthorised, _), (_, _, .invalidAuthentication):
                        return Just(()).setFailureType(to: Error.self).eraseToAnyPublisher()
                    
                    default: throw error
                }
            }
            .subscribe(on: scheduler, using: dependencies)
            .receive(on: scheduler, using: dependencies)
            .sinkUntilComplete(
                receiveCompletion: { result in
                    switch result {
                        case .failure(let error):
                            // Update the interaction to indicate we failed to leave the group (it shouldn't
                            // be possible to fail to delete a group so we don't have copy for that case(
                            dependencies[singleton: .storage].writeAsync { db in
                                let updatedBody: String = "groupLeaveErrorFailed"
                                    .put(key: "group_name", value: ((try? ClosedGroup.fetchOne(db, id: threadId))?.name ?? ""))
                                    .localized()
                                
                                try Interaction
                                    .filter(id: interactionId)
                                    .updateAll(
                                        db,
                                        Interaction.Columns.variant
                                            .set(to: Interaction.Variant.infoGroupCurrentUserErrorLeaving),
                                        Interaction.Columns.body.set(to: updatedBody)
                                    )
                            }
                            
                            failure(job, error, true)
                            
                        case .finished:
                            // Remove all of the group data
                            dependencies[singleton: .storage].writeAsync { db in
                                try ClosedGroup.removeData(
                                    db,
                                    threadIds: [threadId],
                                    dataToRemove: .allData,
                                    using: dependencies
                                )
                            }
                            
                            success(job, false)
                    }
                }
            )
    }
}

// MARK: - GroupLeavingJob.Details

extension GroupLeavingJob {
    public struct Details: Codable {
        private enum CodingKeys: String, CodingKey {
            case behaviour
        }
        
        public enum Behaviour: Int, Codable {
            /// Will leave the group, deleting it from the current device but letting the group continue to exist as long
            /// the current user isn't the only admin
            case leave = 1
            
            /// Will permanently delete the group, this will result in the group being deleted from all member devices
            case delete = 2
        }
        
        public let behaviour: Behaviour
        
        // MARK: - Initialization
        
        public init(behaviour: Behaviour) {
            self.behaviour = behaviour
        }
    }
}

// MARK: - Convenience

private extension GroupLeavingJob {
    enum RequestType {
        case sendLeaveMessage(AuthenticationMethod, DisappearingMessagesConfiguration?)
        case configSync
    }
}
