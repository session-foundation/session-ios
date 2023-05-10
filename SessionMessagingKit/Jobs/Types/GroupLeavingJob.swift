// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SignalCoreKit
import SessionUtilitiesKit
import SessionSnodeKit

public enum GroupLeavingJob: JobExecutor {
    public static var maxFailureCount: Int = 0
    public static var requiresThreadId: Bool = true
    public static var requiresInteractionId: Bool = true
    
    public static func run(
        _ job: SessionUtilitiesKit.Job,
        queue: DispatchQueue,
        success: @escaping (Job, Bool) -> (),
        failure: @escaping (Job, Error?, Bool) -> (),
        deferred: @escaping (Job) -> ())
    {
        guard
            let detailsData: Data = job.details,
            let details: Details = try? JSONDecoder().decode(Details.self, from: detailsData),
            let threadId: String = job.threadId,
            let interactionId: Int64 = job.interactionId
        else {
            failure(job, JobRunnerError.missingRequiredDetails, true)
            return
        }
        
        let destination: Message.Destination = .closedGroup(groupPublicKey: threadId)
        
        Storage.shared
            .writePublisher { db in
                guard (try? SessionThread.exists(db, id: threadId)) == true else {
                    SNLog("Can't update nonexistent closed group.")
                    throw MessageSenderError.noThread
                }
                guard (try? ClosedGroup.exists(db, id: threadId)) == true else {
                    throw MessageSenderError.invalidClosedGroupUpdate
                }
                
                return try MessageSender.preparedSendData(
                    db,
                    message: ClosedGroupControlMessage(
                        kind: .memberLeft
                    ),
                    to: destination,
                    namespace: destination.defaultNamespace,
                    interactionId: job.interactionId,
                    isSyncMessage: false
                )
            }
            .flatMap { MessageSender.sendImmediate(preparedSendData: $0) }
            .receive(on: queue)
            .sinkUntilComplete(
                receiveCompletion: { result in
                    switch result {
                        case .failure:
                            Storage.shared.writeAsync { db in
                                try Interaction
                                    .filter(id: job.interactionId)
                                    .updateAll(
                                        db,
                                        [
                                            Interaction.Columns.variant
                                                .set(to: Interaction.Variant.infoClosedGroupCurrentUserErrorLeaving),
                                            Interaction.Columns.body.set(to: "group_unable_to_leave".localized())
                                        ]
                                    )
                            }
                            success(job, false)
                            
                        case .finished:
                            Storage.shared.writeAsync { db in
                                // Update the group (if the admin leaves the group is disbanded)
                                let currentUserPublicKey: String = getUserHexEncodedPublicKey(db)
                                let wasAdminUser: Bool = GroupMember
                                    .filter(GroupMember.Columns.groupId == threadId)
                                    .filter(GroupMember.Columns.profileId == currentUserPublicKey)
                                    .filter(GroupMember.Columns.role == GroupMember.Role.admin)
                                    .isNotEmpty(db)
                                
                                if wasAdminUser {
                                    try GroupMember
                                        .filter(GroupMember.Columns.groupId == threadId)
                                        .deleteAll(db)
                                }
                                else {
                                    try GroupMember
                                        .filter(GroupMember.Columns.groupId == threadId)
                                        .filter(GroupMember.Columns.profileId == currentUserPublicKey)
                                        .deleteAll(db)
                                }
                                
                                // Update the transaction
                                try Interaction
                                    .filter(id: interactionId)
                                    .updateAll(
                                        db,
                                        [
                                            Interaction.Columns.variant
                                                .set(to: Interaction.Variant.infoClosedGroupCurrentUserLeft),
                                            Interaction.Columns.body.set(to: "GROUP_YOU_LEFT".localized())
                                        ]
                                    )
                                
                                // Clear out the group info as needed
                                try ClosedGroup.removeKeysAndUnsubscribe(
                                    db,
                                    threadId: threadId,
                                    removeGroupData: details.deleteThread,
                                    calledFromConfigHandling: false
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
            case deleteThread
        }
        
        public let deleteThread: Bool
        
        // MARK: - Initialization
        
        public init(deleteThread: Bool) {
            self.deleteThread = deleteThread
        }
        
        // MARK: - Codable
        
        public init(from decoder: Decoder) throws {
            let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
            
            self = Details(
                deleteThread: try container.decode(Bool.self, forKey: .deleteThread)
            )
        }
        
        public func encode(to encoder: Encoder) throws {
            var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)
            
            try container.encode(deleteThread, forKey: .deleteThread)
        }
    }
}

