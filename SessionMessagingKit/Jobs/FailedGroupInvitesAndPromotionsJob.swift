// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionUtilitiesKit

// MARK: - Log.Category

private extension Log.Category {
    static let cat: Log.Category = .create("FailedGroupInvitesAndPromotionsJob", defaultLevel: .info)
}

// MARK: - FailedGroupInvitesAndPromotionsJob

public enum FailedGroupInvitesAndPromotionsJob: JobExecutor {
    public static let maxFailureCount: Int = -1
    public static let requiresThreadId: Bool = false
    public static let requiresInteractionId: Bool = false
    
    public static func canStart(
        jobState: JobState,
        alongside runningJobs: [JobState],
        using dependencies: Dependencies
    ) -> Bool {
        /// No point running more than 1 at a time
        return false
    }
    
    public static func run(_ job: Job, using dependencies: Dependencies) async throws -> JobExecutionResult {
        guard dependencies[cache: .general].userExists else { return .success }
        
        /// Wait for the `libSession` cache to finish being setup, if it's still empty once setup then something is wrong and we can
        /// throw an error
        try await dependencies.waitUntilInitialised(cache: .libSession)
        
        guard !dependencies[cache: .libSession].isEmpty else {
            throw JobRunnerError.missingRequiredDetails
        }
        
        var invitationsCount: Int = -1
        var promotionsCount: Int = -1
        
        /// Update all `sending` message states to `failed`
        try await dependencies[singleton: .storage].writeAsync { db in
            invitationsCount = try GroupMember
                .filter(
                    GroupMember.Columns.groupId > SessionId.Prefix.group.rawValue &&
                    GroupMember.Columns.groupId < SessionId.Prefix.group.endOfRangeString
                )
                .filter(GroupMember.Columns.role == GroupMember.Role.standard)
                .filter(GroupMember.Columns.roleStatus == GroupMember.RoleStatus.sending)
                .updateAllAndConfig(
                    db,
                    GroupMember.Columns.roleStatus.set(to: GroupMember.RoleStatus.failed),
                    using: dependencies
                )
            promotionsCount = try GroupMember
                .filter(
                    GroupMember.Columns.groupId > SessionId.Prefix.group.rawValue &&
                    GroupMember.Columns.groupId < SessionId.Prefix.group.endOfRangeString
                )
                .filter(GroupMember.Columns.role == GroupMember.Role.admin)
                .filter(GroupMember.Columns.roleStatus == GroupMember.RoleStatus.sending)
                .updateAllAndConfig(
                    db,
                    GroupMember.Columns.roleStatus.set(to: GroupMember.RoleStatus.failed),
                    using: dependencies
                )
        }
        try Task.checkCancellation()
        
        Log.info(.cat, "Invites marked as failed: \(invitationsCount), Promotions marked as failed: \(promotionsCount)")
        return .success
    }
}
