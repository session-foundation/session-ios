// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import GRDB
import SessionUIKit
import SessionUtilitiesKit

public extension MentionSelectionView.ViewModel {
    static func mentions(
        profiles: [Profile],
        threadVariant: SessionThread.Variant,
        currentUserSessionIds: Set<String>,
        adminModIds: [String],
        using dependencies: Dependencies
    ) -> [MentionSelectionView.ViewModel] {
        return profiles.compactMap { profile -> MentionSelectionView.ViewModel? in
            guard let info: ProfilePictureView.Info = ProfilePictureView.Info.generateInfoFrom(
                size: MentionSelectionView.profilePictureViewSize,
                publicKey: profile.id,
                threadVariant: .contact, /// Always show the display picture in 'contact' mode
                displayPictureUrl: nil,
                profile: profile,
                profileIcon: (adminModIds.contains(profile.id) ? .crown : .none),
                using: dependencies
            ).front else { return nil }
            
            return MentionSelectionView.ViewModel(
                profileId: profile.id,
                displayName: profile.displayName(
                    showYouForCurrentUser: true,
                    currentUserSessionIds: currentUserSessionIds,
                    includeSessionIdSuffix: (threadVariant == .community)
                ),
                profilePictureInfo: info
            )
        }
    }
    
    static func mentions(
        for query: String = "",
        threadId: String,
        threadVariant: SessionThread.Variant,
        currentUserSessionIds: Set<String>,
        communityInfo: (server: String, roomToken: String)?,
        using dependencies: Dependencies
    ) async throws -> [MentionSelectionView.ViewModel] {
        let profiles: [Profile] = try await dependencies[singleton: .storage].readAsync { db in
            let pattern: FTS5Pattern? = try? GlobalSearch.pattern(db, searchTerm: query, forTable: Profile.self)
            let targetPrefixes: [SessionId.Prefix] = {
                switch threadVariant {
                    case .contact, .legacyGroup, .group: return [.standard]
                    case .community:
                        let capabilities: Set<Capability.Variant> = ((try? Capability
                            .select(.variant)
                            .filter(Capability.Columns.openGroupServer == communityInfo?.server)
                            .asRequest(of: Capability.Variant.self)
                            .fetchSet(db)) ?? [])
                        
                        guard capabilities.contains(.blind) else {
                            return [.standard]
                        }
                        
                        return [.blinded15, .blinded25]
                }
            }()
            
            return try mentionsQuery(
                threadId: threadId,
                threadVariant: threadVariant,
                targetPrefixes: targetPrefixes,
                currentUserSessionIds: currentUserSessionIds,
                pattern: pattern
            ).fetchAll(db)
        }
        
        let adminModIds: [String] = await {
            switch (threadVariant, communityInfo) {
                case (.contact, _), (.group, _), (.legacyGroup, _), (.community, .none): return []
                case (.community, .some(let communityInfo)):
                    guard let server: CommunityManager.Server = await dependencies[singleton: .communityManager].server(communityInfo.server) else {
                        return []
                    }
                    
                    return (
                        (server.rooms[communityInfo.roomToken]?.admins ?? []) +
                        (server.rooms[communityInfo.roomToken]?.moderators ?? [])
                    )
            }
        }()
        
        return mentions(
            profiles: profiles,
            threadVariant: threadVariant,
            currentUserSessionIds: currentUserSessionIds,
            adminModIds: adminModIds,
            using: dependencies
        )
    }
    
    // stringlint:ignore_contents
    private static func mentionsQuery(
        threadId: String,
        threadVariant: SessionThread.Variant,
        targetPrefixes: [SessionId.Prefix],
        currentUserSessionIds: Set<String>,
        pattern: FTS5Pattern?
    ) -> SQLRequest<Profile> {
        let profile: TypedTableAlias<Profile> = TypedTableAlias()
        let interaction: TypedTableAlias<Interaction> = TypedTableAlias()
        let openGroup: TypedTableAlias<OpenGroup> = TypedTableAlias()
        let groupMember: TypedTableAlias<GroupMember> = TypedTableAlias()
        let prefixesLiteral: SQLExpression = targetPrefixes
            .map { prefix in
                SQL(
                """
                (
                    \(profile[.id]) > '\(SQL(stringLiteral: "\(prefix.rawValue)"))' AND
                    \(profile[.id]) < '\(SQL(stringLiteral: "\(prefix.endOfRangeString)"))'
                )
                """)
            }
            .joined(operator: .or)
        let profileFullTextSearch: SQL = SQL(stringLiteral: Profile.fullTextSearchTableName)
        
        /// The query needs to differ depending on the thread variant because the behaviour should be different:
        ///
        /// **Contact:** We should show the profile directly (filtered out if the pattern doesn't match)
        /// **Group:** We should show all profiles within the group, filtered by the pattern
        /// **Community:** We should show only the 20 most recent profiles which match the pattern
        let hasValidPattern: Bool = (pattern != nil && pattern?.rawPattern != "\"\"*")
        let targetJoin: SQL = {
            guard hasValidPattern else { return "FROM \(Profile.self)" }
            
            return """
                FROM \(profileFullTextSearch)
                JOIN \(Profile.self) ON (
                    \(Profile.self).rowid = \(profileFullTextSearch).rowid AND (
                        \(SQL("\(threadVariant) != \(SessionThread.Variant.community)")) OR
                        \(prefixesLiteral)
                    )
                )
            """
        }()
        let targetWhere: SQL = {
            guard let pattern: FTS5Pattern = pattern, pattern.rawPattern != "\"\"*" else {
                return """
                    WHERE (
                        \(SQL("\(threadVariant) != \(SessionThread.Variant.community)")) OR
                        \(prefixesLiteral)
                    )
                """
            }
            
            let matchLiteral: SQL = SQL(stringLiteral: "\(Profile.Columns.nickname.name):\(pattern.rawPattern) OR \(Profile.Columns.name.name):\(pattern.rawPattern)")
            
            return "WHERE \(profileFullTextSearch) MATCH '\(matchLiteral)'"
        }()
        
        switch threadVariant {
            case .contact:
                return SQLRequest("""
                    SELECT \(Profile.self).*
                    \(targetJoin)
                    \(targetWhere) AND (
                        \(SQL("\(profile[.id]) = \(threadId)")) OR
                        \(SQL("\(profile[.id]) IN \(currentUserSessionIds)"))
                    )
                    ORDER BY \(SQL("\(profile[.id]) IN \(currentUserSessionIds)")) DESC
                """)
                
            case .legacyGroup, .group:
                return SQLRequest("""
                    SELECT \(Profile.self).*
                    \(targetJoin)
                    JOIN \(GroupMember.self) ON (
                        \(SQL("\(groupMember[.groupId]) = \(threadId)")) AND
                        \(groupMember[.profileId]) = \(profile[.id]) AND
                        \(SQL("\(groupMember[.role]) != \(GroupMember.Role.zombie)"))
                    )
                    \(targetWhere)
                    GROUP BY \(profile[.id])
                    ORDER BY
                        \(SQL("\(profile[.id]) IN \(currentUserSessionIds)")) DESC,
                        IFNULL(\(profile[.nickname]), \(profile[.name])) ASC
                """)
                
            case .community:
                return SQLRequest("""
                    SELECT
                        \(Profile.self).*,
                        MAX(\(interaction[.timestampMs]))  -- Want the newest interaction (for sorting)
                
                    \(targetJoin)
                    JOIN \(Interaction.self) ON (
                        \(SQL("\(interaction[.threadId]) = \(threadId)")) AND
                        \(interaction[.authorId]) = \(profile[.id])
                    )
                    JOIN \(OpenGroup.self) ON \(SQL("\(openGroup[.threadId]) = \(threadId)"))
                    \(targetWhere)
                    GROUP BY \(profile[.id])
                    ORDER BY
                        \(SQL("\(profile[.id]) IN \(currentUserSessionIds)")) DESC,
                        \(interaction[.timestampMs].desc)
                    LIMIT 20
                """)
        }
    }
}
