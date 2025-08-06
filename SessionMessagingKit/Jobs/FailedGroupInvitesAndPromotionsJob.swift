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
    
    public static func run<S: Scheduler>(
        _ job: Job,
        scheduler: S,
        success: @escaping (Job, Bool) -> Void,
        failure: @escaping (Job, Error, Bool) -> Void,
        deferred: @escaping (Job) -> Void,
        using dependencies: Dependencies
    ) {
        guard dependencies[cache: .general].userExists else { return success(job, false) }
        guard !dependencies[cache: .libSession].isEmpty else {
            return failure(job, JobRunnerError.missingRequiredDetails, false)
        }
        
        var invitationsCount: Int = -1
        var promotionsCount: Int = -1
        
        // Update all 'sending' message states to 'failed'
        dependencies[singleton: .storage]
            .writePublisher { db in
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
            .subscribe(on: scheduler, using: dependencies)
            .receive(on: scheduler, using: dependencies)
            .sinkUntilComplete(
                receiveCompletion: { _ in
                    Log.info(.cat, "Invites marked as failed: \(invitationsCount), Promotions marked as failed: \(promotionsCount)")
                    success(job, false)
                }
            )
    }
}
