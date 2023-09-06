// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionUtilitiesKit
import SessionSnodeKit

public enum GroupInviteMemberJob: JobExecutor {
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
            let currentInfo: (groupName: String, adminProfile: Profile) = dependencies[singleton: .storage].read({ db in
                let maybeGroupName: String? = try ClosedGroup
                    .filter(id: threadId)
                    .select(.name)
                    .asRequest(of: String.self)
                    .fetchOne(db)
                
                guard let groupName: String = maybeGroupName else { throw StorageError.objectNotFound }
                
                return (groupName, Profile.fetchOrCreateCurrentUser(db, using: dependencies))
            }),
            let details: Details = try? JSONDecoder(using: dependencies).decode(Details.self, from: detailsData)
        else {
            SNLog("[InviteGroupMemberJob] Failing due to missing details")
            failure(job, JobRunnerError.missingRequiredDetails, true, dependencies)
            return
        }
        
        let sentTimestamp: Int64 = SnodeAPI.currentOffsetTimestampMs()
        let message: GroupUpdateInviteMessage = GroupUpdateInviteMessage(
            groupIdentityPublicKey: Data(hex: threadId),
            groupName: currentInfo.groupName,
            memberSubkey: details.memberSubkey,
            memberTag: details.memberTag,
            profile: VisibleMessage.VMProfile.init(
                profile: currentInfo.adminProfile,
                blocksCommunityMessageRequests: nil
            ),
            sentTimestamp: UInt64(sentTimestamp)
        )
        
        // TODO: Need to actually send the invite to the recipient
        // TODO: Need to batch errors together and send a toast indicating invitation failures
//        SnodeAPI
//            .SendMessageRequest(message: <#T##SnodeMessage#>, namespace: <#T##SnodeAPI.Namespace#>, subkey: <#T##String?#>, timestampMs: <#T##UInt64#>, ed25519PublicKey: <#T##[UInt8]#>, ed25519SecretKey: <#T##[UInt8]#>)
        
    }
}

// MARK: - GroupInviteMemberJob.Details

extension GroupInviteMemberJob {
    public struct Details: Codable {
        public let memberSubkey: Data
        public let memberTag: Data
    }
}

