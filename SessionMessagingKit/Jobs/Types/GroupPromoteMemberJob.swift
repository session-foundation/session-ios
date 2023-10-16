// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionUtilitiesKit
import SessionSnodeKit

public enum GroupPromoteMemberJob: JobExecutor {
    public static var maxFailureCount: Int = 1
    public static var requiresThreadId: Bool = true
    public static var requiresInteractionId: Bool = false
    
    public static func run(
        _ job: Job,
        queue: DispatchQueue,
        success: @escaping (Job, Bool, Dependencies) -> (),
        failure: @escaping (Job, Error?, Bool, Dependencies) -> (),
        deferred: @escaping (Job, Dependencies) -> (),
        using dependencies: Dependencies
    ) {
        guard
            let threadId: String = job.threadId,
            let detailsData: Data = job.details,
            let groupIdentityPrivateKey: Data = dependencies[singleton: .storage].read({ db in
                try ClosedGroup
                    .filter(id: threadId)
                    .select(.groupIdentityPrivateKey)
                    .asRequest(of: Data.self)
                    .fetchOne(db)
            }),
            let details: Details = try? JSONDecoder(using: dependencies).decode(Details.self, from: detailsData)
        else {
            SNLog("[GroupPromoteMemberJob] Failing due to missing details")
            failure(job, JobRunnerError.missingRequiredDetails, true, dependencies)
            return
        }
        
        let encryptedGroupIdentityPrivateKey: Data = groupIdentityPrivateKey
        
        let sentTimestamp: Int64 = SnodeAPI.currentOffsetTimestampMs()
        let message: GroupUpdatePromoteMessage = GroupUpdatePromoteMessage(
            memberPublicKey: Data(hex: details.memberSessionIdHexString),
            encryptedGroupIdentityPrivateKey: encryptedGroupIdentityPrivateKey,
            sentTimestamp: UInt64(sentTimestamp)
        )
        
        /// Perform the actual message sending
        dependencies[singleton: .storage]
            .writePublisher { db -> HTTP.PreparedRequest<Void> in
                try MessageSender.preparedSend(
                    db,
                    message: message,
                    to: .closedGroup(groupPublicKey: threadId),
                    namespace: .groupMessages,
                    interactionId: nil,
                    fileIds: [],
                    isSyncMessage: false,
                    using: dependencies
                )
            }
            .flatMap { $0.send(using: dependencies) }
            .subscribe(on: queue, using: dependencies)
            .receive(on: queue, using: dependencies)
            .sinkUntilComplete(
                receiveCompletion: { result in
                    switch result {
                        case .finished: success(job, false, dependencies)
                        case .failure(let error):
                            SNLog("[GroupPromoteMemberJob] Couldn't send message due to error: \(error).")
                            
                            // Update the promotion status of the group member (only if the role status isn't already
                            // 'accepted')
                            dependencies[singleton: .storage].write(using: dependencies) { db in
                                try GroupMember
                                    .filter(
                                        GroupMember.Columns.groupId == threadId &&
                                        GroupMember.Columns.profileId == details.memberSessionIdHexString &&
                                        GroupMember.Columns.roleStatus != GroupMember.RoleStatus.accepted
                                    )
                                    .updateAllAndConfig(
                                        db,
                                        GroupMember.Columns.roleStatus.set(to: GroupMember.RoleStatus.failed),
                                        using: dependencies
                                    )
                            }
                            
                            // Register the failure
                            switch error {
                                case let senderError as MessageSenderError where !senderError.isRetryable:
                                    failure(job, error, true, dependencies)
                                    
                                case OnionRequestAPIError.httpRequestFailedAtDestination(let statusCode, _, _) where statusCode == 429: // Rate limited
                                    failure(job, error, true, dependencies)
                                    
                                case SnodeAPIError.clockOutOfSync:
                                    SNLog("[GroupPromoteMemberJob] Permanently Failing to send due to clock out of sync issue.")
                                    failure(job, error, true, dependencies)
                                    
                                default: failure(job, error, false, dependencies)
                            }
                    }
                }
            )
    }
}

// MARK: - GroupPromoteMemberJob.Details

extension GroupPromoteMemberJob {
    public struct Details: Codable {
        public let memberSessionIdHexString: String
    }
}

