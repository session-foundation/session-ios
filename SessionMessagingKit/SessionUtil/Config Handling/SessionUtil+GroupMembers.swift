// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtil
import SessionUtilitiesKit

// MARK: - Group Info Handling

internal extension SessionUtil {
    static let columnsRelatedToGroupMembers: [ColumnExpression] = []
    
    // MARK: - Incoming Changes
    
    static func handleGroupMembersUpdate(
        _ db: Database,
        in config: Config?,
        groupIdentityPublicKey: String,
        serverTimestampMs: Int64,
        using dependencies: Dependencies
    ) throws {
        guard config.needsDump else { return }
        guard case .object(let conf) = config else { throw SessionUtilError.invalidConfigObject }
        
        var infiniteLoopGuard: Int = 0
        var result: [MemberData] = []
        var member: config_group_member = config_group_member()
        let membersIterator: UnsafeMutablePointer<groups_members_iterator> = groups_members_iterator_new(conf)
        
        while !groups_members_iterator_done(membersIterator, &member) {
            try SessionUtil.checkLoopLimitReached(&infiniteLoopGuard, for: .groupMembers)
            
            let memberId: String = String(cString: withUnsafeBytes(of: member.session_id) { [UInt8]($0) }
                .map { CChar($0) }
                .nullTerminated()
            )
            let profilePictureUrl: String? = String(libSessionVal: member.profile_pic.url, nullIfEmpty: true)
            let profileResult: Profile = Profile(
                id: memberId,
                name: String(libSessionVal: member.name),
                lastNameUpdate: (TimeInterval(serverTimestampMs) / 1000),
                nickname: nil,
                profilePictureUrl: profilePictureUrl,
                profileEncryptionKey: (profilePictureUrl == nil ? nil :
                    Data(
                        libSessionVal: member.profile_pic.key,
                        count: ProfileManager.avatarAES256KeyByteLength
                    )
                ),
                lastProfilePictureUpdate: (TimeInterval(serverTimestampMs) / 1000),
                lastBlocksCommunityMessageRequests: 0
            )
            
            result.append(
                MemberData(
                    memberId: memberId,
                    profile: profileResult,
                    admin: member.admin,
                    invited: member.invited,
                    promoted: member.promoted
                )
            )
            
            groups_members_iterator_advance(membersIterator)
        }
        groups_members_iterator_free(membersIterator) // Need to free the iterator
        
        // Get the two member sets
        let existingMembers: Set<GroupMember> = (try? GroupMember
            .filter(GroupMember.Columns.groupId == groupIdentityPublicKey)
            .fetchSet(db))
            .defaulting(to: [])
        let updatedMembers: Set<GroupMember> = result
            .map {
                GroupMember(
                    groupId: groupIdentityPublicKey,
                    profileId: $0.memberId,
                    role: ($0.admin ? .admin : .standard),
                    // TODO: Other properties
                    isHidden: false
                )
            }
            .asSet()
        let updatedStandardMemberIds: Set<String> = updatedMembers
            .filter { $0.role == .standard }
            .map { $0.profileId }
            .asSet()
        let updatedAdminMemberIds: Set<String> = updatedMembers
            .filter { $0.role == .admin }
            .map { $0.profileId }
            .asSet()

        // Add in any new members and remove any removed members
        try updatedMembers
            .subtracting(existingMembers)
            .forEach { try $0.save(db) }
        
        try GroupMember
            .filter(
                GroupMember.Columns.groupId == groupIdentityPublicKey && (
                    GroupMember.Columns.role == GroupMember.Role.standard &&
                    !updatedStandardMemberIds.contains(GroupMember.Columns.profileId)
                ) || (
                    GroupMember.Columns.role == GroupMember.Role.admin &&
                    !updatedAdminMemberIds.contains(GroupMember.Columns.profileId)
                )
            )
            .deleteAll(db)
    }
}

// MARK: - Outgoing Changes

internal extension SessionUtil {
}

// MARK: - MemberData

private struct MemberData {
    let memberId: String
    let profile: Profile?
    let admin: Bool
    let invited: Int32
    let promoted: Int32
}
