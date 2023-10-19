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
        
        // The first 32 bytes of a 64 byte ed25519 private key are the seed which can be used
        // to generate the KeyPair so extract those and send along with the promotion message
        let sentTimestamp: Int64 = SnodeAPI.currentOffsetTimestampMs(using: dependencies)
        let message: GroupUpdatePromoteMessage = GroupUpdatePromoteMessage(
            groupIdentitySeed: groupIdentityPrivateKey.prefix(32),
            sentTimestamp: UInt64(sentTimestamp)
        )
        
        /// Perform the actual message sending
        dependencies[singleton: .storage]
            .readPublisher { db -> HTTP.PreparedRequest<Void> in
                try MessageSender.preparedSend(
                    db,
                    message: message,
                    to: .contact(publicKey: details.memberSessionIdHexString),
                    namespace: .default,
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
                            
                            // Update the promotion status of the group member (only if the role is 'admin' and
                            // the role status isn't already 'accepted')
                            dependencies[singleton: .storage].write(using: dependencies) { db in
                                try GroupMember
                                    .filter(
                                        GroupMember.Columns.groupId == threadId &&
                                        GroupMember.Columns.profileId == details.memberSessionIdHexString &&
                                        GroupMember.Columns.role == GroupMember.Role.admin &&
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

