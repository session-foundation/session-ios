// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionUtilitiesKit
import SessionSnodeKit

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
        
        let destination: Message.Destination = .closedGroup(groupPublicKey: threadId)
        
        dependencies[singleton: .storage]
            .writePublisher { db -> LeaveType in
                guard
                    let threadVariant: SessionThread.Variant = try? SessionThread
                        .filter(id: threadId)
                        .select(.variant)
                        .asRequest(of: SessionThread.Variant.self)
                        .fetchOne(db)
                else {
                    Log.error(.cat, "Failed due to non-existent group conversation")
                    throw MessageSenderError.noThread
                }
                guard (try? ClosedGroup.exists(db, id: threadId)) == true else {
                    Log.error(.cat, "Failed due to non-existent group")
                    throw MessageSenderError.invalidClosedGroupUpdate
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
                let finalBehaviour: GroupLeavingJob.Details.Behaviour = {
                    guard
                        threadVariant == .group,
                        (
                            LibSession.wasKickedFromGroup(
                                groupSessionId: SessionId(.group, hex: threadId),
                                using: dependencies
                            ) ||
                            LibSession.groupIsDestroyed(
                                groupSessionId: SessionId(.group, hex: threadId),
                                using: dependencies
                            )
                        )
                    else { return details.behaviour }
                    
                    return .delete
                }()
                
                switch (threadVariant, finalBehaviour, isAdminUser, (isAdminUser && numAdminUsers == 1)) {
                    case (.legacyGroup, _, _, _):
                        // Legacy group only supports the 'leave' behaviour so don't bother checking
                        return .leave(
                            try MessageSender.preparedSend(
                                db,
                                message: ClosedGroupControlMessage(kind: .memberLeft),
                                to: destination,
                                namespace: destination.defaultNamespace,
                                interactionId: job.interactionId,
                                fileIds: [],
                                using: dependencies
                            )
                        )
                    
                    case (.group, .leave, _, false):
                        let disappearingConfig: DisappearingMessagesConfiguration? = try? DisappearingMessagesConfiguration.fetchOne(db, id: threadId)
                        
                        return .leave(
                            try SnodeAPI
                                .preparedBatch(
                                    requests: [
                                        /// Don't expire the `GroupUpdateMemberLeftMessage` as that's not a UI-based
                                        /// message (it's an instruction for admin devices)
                                        try MessageSender.preparedSend(
                                            db,
                                            message: GroupUpdateMemberLeftMessage(),
                                            to: destination,
                                            namespace: destination.defaultNamespace,
                                            interactionId: job.interactionId,
                                            fileIds: [],
                                            using: dependencies
                                        ),
                                        try MessageSender.preparedSend(
                                            db,
                                            message: GroupUpdateMemberLeftNotificationMessage()
                                                .with(disappearingConfig),
                                            to: destination,
                                            namespace: destination.defaultNamespace,
                                            interactionId: nil,
                                            fileIds: [],
                                            using: dependencies
                                        )
                                    ],
                                    requireAllBatchResponses: false,
                                    swarmPublicKey: threadId,
                                    using: dependencies
                                )
                                .map { _, _ in () }
                        )
                        
                    case (.group, .delete, true, _), (.group, .leave, true, true):
                        let groupSessionId: SessionId = SessionId(.group, hex: threadId)
                        
                        /// Skip the automatic config sync because we want to perform it synchronously as part of this job
                        try dependencies.mutate(cache: .libSession) { cache in
                            try cache.withCustomBehaviour(.skipAutomaticConfigSync, for: groupSessionId) {
                                try cache.deleteGroupForEveryone(db, groupSessionId: groupSessionId)
                            }
                        }
                        
                        return .delete
                    
                    case (.group, .delete, false, _): return .delete
                        
                    default: throw MessageSenderError.invalidClosedGroupUpdate
                }
            }
            .flatMap { leaveType -> AnyPublisher<Void, Error> in
                switch leaveType {
                    case .leave(let leaveMessage):
                        return leaveMessage
                            .send(using: dependencies)
                            .map { _ in () }
                            .eraseToAnyPublisher()
                        
                    case .delete:
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
                switch (error as? MessageSenderError, error as? SnodeAPIError) {
                    case (.invalidClosedGroupUpdate, _), (.noKeyPair, _), (.encryptionFailed, _),
                        (_, .unauthorised), (_, .invalidAuthentication):
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
    enum LeaveType {
        case leave(Network.PreparedRequest<Void>)
        case delete
    }
}
