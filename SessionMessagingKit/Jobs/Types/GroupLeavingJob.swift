// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import PromiseKit
import SignalCoreKit
import SessionUtilitiesKit
import SessionSnodeKit

public enum GroupLeavingJob: JobExecutor {
    public static var maxFailureCount: Int = -1
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
            let details: Details = try? JSONDecoder().decode(Details.self, from: detailsData)
        else {
            failure(job, JobRunnerError.missingRequiredDetails, false)
            return
        }
        
        guard let thread: SessionThread = Storage.shared.read({ db in try? SessionThread.fetchOne(db, id: details.groupPublicKey)}) else {
            SNLog("Can't leave nonexistent closed group.")
            failure(job, MessageSenderError.noThread, false)
            return
        }
        
        guard let closedGroup: ClosedGroup = Storage.shared.read({ db in try? thread.closedGroup.fetchOne(db)}) else {
            failure(job, MessageSenderError.invalidClosedGroupUpdate, false)
            return
        }
        
        Storage.shared.writeAsync { db -> Promise<Void> in
            try MessageSender.sendNonDurably(
                db,
                message: ClosedGroupControlMessage(
                    kind: .memberLeft
                ),
                interactionId: details.infoMessageInteractionId,
                in: thread
            )
        }
        .done(on: queue) { _ in
            // Remove the group from the database and unsubscribe from PNs
            ClosedGroupPoller.shared.stopPolling(for: details.groupPublicKey)
            
            Storage.shared.write { db in
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
                    .filter(id: details.infoMessageInteractionId)
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
                
                if details.deleteThreadAfterSuccess {
                    _ = try SessionThread
                        .filter(id: thread.id)
                        .deleteAll(db)
                }
            }
            success(job, false)
        }
        .catch(on: queue) { error in
            Storage.shared.write { db in
                try Interaction
                    .filter(id: details.infoMessageInteractionId)
                    .updateAll(
                        db,
                        [
                            Interaction.Columns.variant.set(to: Interaction.Variant.infoClosedGroupCurrentUserErrorLeaving),
                            Interaction.Columns.body.set(to: "group_unable_to_leave".localized())
                        ]
                    )
            }
        }
        .retainUntilComplete()
        
    }
}

// MARK: - GroupLeavingJob.Details

extension GroupLeavingJob {
    public struct Details: Codable {
        private enum CodingKeys: String, CodingKey {
            case infoMessageInteractionId
            case groupPublicKey
            case deleteThreadAfterSuccess
        }
        
        public let infoMessageInteractionId: Int64
        public let groupPublicKey: String
        public let deleteThreadAfterSuccess: Bool
        
        // MARK: - Initialization
        
        public init(
            infoMessageInteractionId: Int64,
            groupPublicKey: String,
            deleteThreadAfterSuccess: Bool
        ) {
            self.infoMessageInteractionId = infoMessageInteractionId
            self.groupPublicKey = groupPublicKey
            self.deleteThreadAfterSuccess = deleteThreadAfterSuccess
        }
        
        // MARK: - Codable
        
        public init(from decoder: Decoder) throws {
            let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
            
            self = Details(
                infoMessageInteractionId: try container.decode(Int64.self, forKey: .infoMessageInteractionId),
                groupPublicKey: try container.decode(String.self, forKey: .groupPublicKey),
                deleteThreadAfterSuccess: try container.decode(Bool.self, forKey: .deleteThreadAfterSuccess)
            )
        }
        
        public func encode(to encoder: Encoder) throws {
            var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)

            try container.encode(infoMessageInteractionId, forKey: .infoMessageInteractionId)
            try container.encode(groupPublicKey, forKey: .groupPublicKey)
            try container.encode(deleteThreadAfterSuccess, forKey: .deleteThreadAfterSuccess)
        }
    }
}

