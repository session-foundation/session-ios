// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

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
    
    public enum Role: Int, Codable, Comparable, DatabaseValueConvertible {
        case standard
        case zombie
        case moderator
        case admin
    }
    
    public enum RoleStatus: Int, Codable, Comparable, DatabaseValueConvertible {
        case accepted
        case sending
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

// MARK: - Convenience

public extension GroupMember {
    var statusDescription: String? {
        switch (role, roleStatus) {
            case (_, .accepted): return nil                 // Nothing for "final" state
            case (.zombie, _), (.moderator, _): return nil  // Unused cases
            case (.standard, .sending): return "GROUP_MEMBER_STATUS_SENDING".localized()
            case (.standard, .pending): return "GROUP_MEMBER_STATUS_SENT".localized()
            case (.standard, .failed): return "GROUP_MEMBER_STATUS_FAILED".localized()
            case (.admin, .sending): return "GROUP_ADMIN_STATUS_SENDING".localized()
            case (.admin, .pending): return "GROUP_ADMIN_STATUS_SENT".localized()
            case (.admin, .failed): return "GROUP_ADMIN_STATUS_FAILED".localized()
        }
    }
    
    var statusDescriptionColor: ThemeValue {
        switch (role, roleStatus) {
            case (.zombie, _), (.moderator, _): return .textPrimary
            case (_, .failed): return .danger
            default: return .textPrimary
        }
    }
}

extension GroupMember: ProfileAssociated {
    public func itemDescription(using dependencies: Dependencies) -> String? { return statusDescription }
    public func itemDescriptionColor(using dependencies: Dependencies) -> ThemeValue { return statusDescriptionColor }
    
}
