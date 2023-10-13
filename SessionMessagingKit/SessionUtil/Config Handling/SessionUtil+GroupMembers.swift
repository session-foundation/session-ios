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
        groupSessionId: SessionId,
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
                lastBlocksCommunityMessageRequests: nil
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
            .filter(GroupMember.Columns.groupId == groupSessionId.hexString)
            .fetchSet(db))
            .defaulting(to: [])
        let updatedMembers: Set<GroupMember> = result
            .map { data in
                GroupMember(
                    groupId: groupSessionId.hexString,
                    profileId: data.memberId,
                    role: (data.admin || (data.promoted > 0) ? .admin : .standard),
                    roleStatus: {
                        switch (data.invited, data.promoted, data.admin) {
                            case (2, _, _), (_, 2, false): return .failed           // Explicitly failed
                            case (1..., _, _), (_, 1..., false): return .pending    // Pending if not accepted
                            default: return .accepted                               // Otherwise it's accepted
                        }
                    }(),
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
            .filter(GroupMember.Columns.groupId == groupSessionId.hexString)
            .filter(
                (
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
    static func update(
        _ db: Database,
        groupSessionId: String,
        groupIdentityPrivateKey: Data? = nil,
        members: [(id: String, profile: Profile?, isAdmin: Bool)],
        using dependencies: Dependencies
    ) throws {
        // Reduce the members list to ensure we don't accidentally insert duplicates (which can crash)
        let finalMembers: [String: (profile: Profile?, isAdmin: Bool)] = members
            .reduce(into: [:]) { result, next in result[next.0] = (profile: next.1, isAdmin: next.2)}
        
        try SessionUtil.performAndPushChange(
            db,
            for: .groupMembers,
            sessionId: SessionId(.group, hex: groupSessionId),
            using: dependencies
        ) { config in
            guard case .object(let conf) = config else { throw SessionUtilError.invalidConfigObject }
            
            try finalMembers.forEach { memberId, info in
                var profilePic: user_profile_pic = user_profile_pic()
                
                if
                    let picUrl: String = info.profile?.profilePictureUrl,
                    let picKey: Data = info.profile?.profileEncryptionKey
                {
                    profilePic.url = picUrl.toLibSession()
                    profilePic.key = picKey.toLibSession()
                }

                try CExceptionHelper.performSafely {
                    var member: config_group_member = config_group_member(
                        session_id: memberId.toLibSession(),
                        name: (info.profile?.name ?? "").toLibSession(),
                        profile_pic: profilePic,
                        admin: info.isAdmin,
                        invited: 0,
                        promoted: 0
                    )
                    
                    groups_members_set(conf, &member)
                }
            }
        }
    }
}

// MARK: - MemberData

private struct MemberData {
    let memberId: String
    let profile: Profile?
    let admin: Bool
    let invited: Int32
    let promoted: Int32
}
