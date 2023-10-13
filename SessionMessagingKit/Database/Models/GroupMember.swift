// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

public struct GroupMember: Codable, Equatable, Hashable, FetchableRecord, PersistableRecord, TableRecord, ColumnExpressible {
    public static var databaseTableName: String { "groupMember" }
    internal static let openGroupForeignKey = ForeignKey([Columns.groupId], to: [OpenGroup.Columns.threadId])
    internal static let closedGroupForeignKey = ForeignKey([Columns.groupId], to: [ClosedGroup.Columns.threadId])
    public static let openGroup = belongsTo(OpenGroup.self, using: openGroupForeignKey)
    public static let closedGroup = belongsTo(ClosedGroup.self, using: closedGroupForeignKey)
    public static let profile = hasOne(Profile.self, using: Profile.groupMemberForeignKey)
    
    public typealias Columns = CodingKeys
    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case groupId
        case profileId
        case role
        case roleStatus
        case isHidden
    }
    
    public enum Role: Int, Codable, DatabaseValueConvertible {
        case standard
        case zombie
        case moderator
        case admin
    }
    
    public enum RoleStatus: Int, Codable, DatabaseValueConvertible {
        case accepted
        case pending
        case failed
    }

    public let groupId: String
    public let profileId: String
    public let role: Role
    public let roleStatus: RoleStatus
    public let isHidden: Bool
    
    // MARK: - Relationships
    
    public var openGroup: QueryInterfaceRequest<OpenGroup> {
        request(for: GroupMember.openGroup)
    }
    
    public var closedGroup: QueryInterfaceRequest<ClosedGroup> {
        request(for: GroupMember.closedGroup)
    }
    
    public var profile: QueryInterfaceRequest<Profile> {
        request(for: GroupMember.profile)
    }
    
    // MARK: - Initialization
    
    public init(
        groupId: String,
        profileId: String,
        role: Role,
        roleStatus: RoleStatus,
        isHidden: Bool
    ) {
        self.groupId = groupId
        self.profileId = profileId
        self.role = role
        self.roleStatus = roleStatus
        self.isHidden = isHidden
    }
}

// MARK: - Decoding

extension GroupMember {
    public init(from decoder: Decoder) throws {
        let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
        
        self = GroupMember(
            groupId: try container.decode(String.self, forKey: .groupId),
            profileId: try container.decode(String.self, forKey: .profileId),
            role: try container.decode(Role.self, forKey: .role),
            // Added in `_018_GroupsRebuildChanges`
            roleStatus: ((try? container.decode(RoleStatus.self, forKey: .roleStatus)) ?? .accepted),
            // Added in `_006_FixHiddenModAdminSupport`
            isHidden: ((try? container.decode(Bool.self, forKey: .isHidden)) ?? false)
        )
    }
}
