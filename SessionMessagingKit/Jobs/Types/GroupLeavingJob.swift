// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import PromiseKit
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
        success: @escaping (SessionUtilitiesKit.Job, Bool) -> (),
        failure: @escaping (SessionUtilitiesKit.Job, Error?, Bool) -> (),
        deferred: @escaping (SessionUtilitiesKit.Job) -> ())
    {
        guard
            let detailsData: Data = job.details,
            let details: Details = try? JSONDecoder().decode(Details.self, from: detailsData),
            let interactionId: Int64 = job.interactionId
        else {
            failure(job, JobRunnerError.missingRequiredDetails, true)
            return
        }
        
        guard let thread: SessionThread = Storage.shared.read({ db in try? SessionThread.fetchOne(db, id: details.groupPublicKey)}) else {
            SNLog("Can't leave nonexistent closed group.")
            failure(job, MessageSenderError.noThread, true)
            return
        }
        
        guard let closedGroup: ClosedGroup = Storage.shared.read({ db in try? thread.closedGroup.fetchOne(db)}) else {
            failure(job, MessageSenderError.invalidClosedGroupUpdate, true)
            return
        }
        
        Storage.shared.writeAsync { db -> Promise<Void> in
            try MessageSender.sendNonDurably(
                db,
                message: ClosedGroupControlMessage(
                    kind: .memberLeft
                ),
                interactionId: interactionId,
                in: thread
            )
        }
        .done(on: queue) { _ in
            // Remove the group from the database and unsubscribe from PNs
            ClosedGroupPoller.shared.stopPolling(for: details.groupPublicKey)
            
            Storage.shared.writeAsync { db in
                let userPublicKey: String = getUserHexEncodedPublicKey(db)
                
                try closedGroup
                    .keyPairs
                    .deleteAll(db)
                
                let _ = PushNotificationAPI.performOperation(
                    .unsubscribe,
                    for: details.groupPublicKey,
                    publicKey: userPublicKey
                )
                
                try Interaction
                    .filter(id: interactionId)
                    .updateAll(
                        db,
                        [
                            Interaction.Columns.variant.set(to: Interaction.Variant.infoClosedGroupCurrentUserLeft),
                            Interaction.Columns.body.set(to: "GROUP_YOU_LEFT".localized())
                        ]
                    )
                
                // Update the group (if the admin leaves the group is disbanded)
                let wasAdminUser: Bool = try GroupMember
                    .filter(GroupMember.Columns.groupId == thread.id)
                    .filter(GroupMember.Columns.profileId == userPublicKey)
                    .filter(GroupMember.Columns.role == GroupMember.Role.admin)
                    .isNotEmpty(db)
                
                if wasAdminUser {
                    try GroupMember
                        .filter(GroupMember.Columns.groupId == thread.id)
                        .deleteAll(db)
                }
                else {
                    try GroupMember
                        .filter(GroupMember.Columns.groupId == thread.id)
                        .filter(GroupMember.Columns.profileId == userPublicKey)
                        .deleteAll(db)
                }
                
                if details.deleteThread {
                    _ = try SessionThread
                        .filter(id: thread.id)
                        .deleteAll(db)
                }
            }
            success(job, false)
        }
        .catch(on: queue) { error in
            Storage.shared.writeAsync { db in
                try Interaction
                    .filter(id: job.interactionId)
                    .updateAll(
                        db,
                        [
                            Interaction.Columns.variant.set(to: Interaction.Variant.infoClosedGroupCurrentUserErrorLeaving),
                            Interaction.Columns.body.set(to: "group_unable_to_leave".localized())
                        ]
                    )
            }
            success(job, false)
        }
        .retainUntilComplete()
        
    }
}

// MARK: - GroupLeavingJob.Details

extension GroupLeavingJob {
    public struct Details: Codable {
        private enum CodingKeys: String, CodingKey {
            case groupPublicKey
            case deleteThread
        }
        
        public let groupPublicKey: String
        public let deleteThread: Bool
        
        // MARK: - Initialization
        
        public init(
            groupPublicKey: String,
            deleteThread: Bool
        ) {
            self.groupPublicKey = groupPublicKey
            self.deleteThread = deleteThread
        }
        
        // MARK: - Codable
        
        public init(from decoder: Decoder) throws {
            let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
            
            self = Details(
                groupPublicKey: try container.decode(String.self, forKey: .groupPublicKey),
                deleteThread: try container.decode(Bool.self, forKey: .deleteThread)
            )
        }
        
        public func encode(to encoder: Encoder) throws {
            var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)

            try container.encode(groupPublicKey, forKey: .groupPublicKey)
            try container.encode(deleteThread, forKey: .deleteThread)
        }
    }
}

