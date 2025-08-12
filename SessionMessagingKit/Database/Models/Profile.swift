// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import DifferenceKit
import SessionUIKit
import SessionUtilitiesKit

/// This type is duplicate in both the database and within the LibSession config so should only ever have it's data changes via the
/// `updateAllAndConfig` function. Updating it elsewhere could result in issues with syncing data between devices
public struct Profile: Codable, Sendable, Identifiable, Equatable, Hashable, FetchableRecord, PersistableRecord, TableRecord, ColumnExpressible, Differentiable {
    public static var databaseTableName: String { "profile" }
    internal static let interactionForeignKey = ForeignKey([Columns.id], to: [Interaction.Columns.authorId])
    internal static let contactForeignKey = ForeignKey([Columns.id], to: [Contact.Columns.id])
    internal static let groupMemberForeignKey = ForeignKey([GroupMember.Columns.profileId], to: [Columns.id])
    public static let contact = hasOne(Contact.self, using: contactForeignKey)
    public static let groupMembers = hasMany(GroupMember.self, using: groupMemberForeignKey)
    
    public typealias Columns = CodingKeys
    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case id
        
        case name
        case nickname
        
        case displayPictureUrl
        case displayPictureEncryptionKey
        
        case profileLastUpdated
        
        case blocksCommunityMessageRequests
        
        case sessionProProof
    }

    /// The id for the user that owns the profile (Note: This could be a sessionId, a blindedId or some future variant)
    public let id: String
    
    /// The name of the contact. Use this whenever you need the "real", underlying name of a user (e.g. when sending a message).
    public let name: String
    
    /// A custom name for the profile set by the current user
    public let nickname: String?

    /// The URL from which to fetch the contact's profile picture
    ///
    /// **Note:** This won't be updated until the display picture has actually been downloaded
    public let displayPictureUrl: String?

    /// The key with which the profile is encrypted.
    public let displayPictureEncryptionKey: Data?
    
    /// The timestamp (in seconds since epoch) that the profile was last updated
    public let profileLastUpdated: TimeInterval?
    
    /// A flag indicating whether this profile has reported that it blocks community message requests
    public let blocksCommunityMessageRequests: Bool?
    
    /// The Pro Proof for when this profile is updated
    // TODO: Implement this when the structure of Session Pro Proof is determined
    public let sessionProProof: String?
    
    // MARK: - Initialization
    
    public init(
        id: String,
        name: String,
        nickname: String? = nil,
        displayPictureUrl: String? = nil,
        displayPictureEncryptionKey: Data? = nil,
        profileLastUpdated: TimeInterval? = nil,
        blocksCommunityMessageRequests: Bool? = nil,
        sessionProProof: String? = nil
    ) {
        self.id = id
        self.name = name
        self.nickname = nickname
        self.displayPictureUrl = displayPictureUrl
        self.displayPictureEncryptionKey = displayPictureEncryptionKey
        self.profileLastUpdated = profileLastUpdated
        self.blocksCommunityMessageRequests = blocksCommunityMessageRequests
        self.sessionProProof = sessionProProof
    }
}

// MARK: - Description

extension Profile: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        """
        Profile(
            name: \(name),
            profileKey: \(displayPictureEncryptionKey?.description ?? "null"),
            profilePictureUrl: \(displayPictureUrl ?? "null")
        )
        """
    }
    
    public var debugDescription: String {
        return """
        Profile(
            id: \(id),
            name: \(name),
            nickname: \(nickname.map { "\($0)" } ?? "null"),
            displayPictureUrl: \(displayPictureUrl.map { "\"\($0)\"" } ?? "null"),
            displayPictureEncryptionKey: \(displayPictureEncryptionKey?.toHexString() ?? "null"),
            profileLastUpdated: \(profileLastUpdated.map { "\($0)" } ?? "null"),
            blocksCommunityMessageRequests: \(blocksCommunityMessageRequests.map { "\($0)" } ?? "null"),
            sessionProProof: \(sessionProProof.map { "\($0)" } ?? "null")
        )
        """
    }
}

// MARK: - Codable

public extension Profile {
    init(from decoder: Decoder) throws {
        let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
        
        var displayPictureKey: Data?
        var displayPictureUrl: String?
        
        // If we have both a `profileKey` and a `profilePicture` then the key MUST be valid
        if
            let displayPictureKeyData: Data = try? container.decode(Data?.self, forKey: .displayPictureEncryptionKey),
            let displayPictureUrlValue: String = try? container.decode(String?.self, forKey: .displayPictureUrl)
        {
            displayPictureKey = displayPictureKeyData
            displayPictureUrl = displayPictureUrlValue
        }
        
        self = Profile(
            id: try container.decode(String.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            nickname: try? container.decode(String?.self, forKey: .nickname),
            displayPictureUrl: displayPictureUrl,
            displayPictureEncryptionKey: displayPictureKey,
            profileLastUpdated: try? container.decode(TimeInterval?.self, forKey: .profileLastUpdated),
            blocksCommunityMessageRequests: try? container.decode(Bool?.self, forKey: .blocksCommunityMessageRequests),
            sessionProProof: try? container.decode(String?.self, forKey: .sessionProProof)
        )
    }
    
    func encode(to encoder: Encoder) throws {
        var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(nickname, forKey: .nickname)
        try container.encodeIfPresent(displayPictureUrl, forKey: .displayPictureUrl)
        try container.encodeIfPresent(displayPictureEncryptionKey, forKey: .displayPictureEncryptionKey)
        try container.encodeIfPresent(profileLastUpdated, forKey: .profileLastUpdated)
        try container.encodeIfPresent(blocksCommunityMessageRequests, forKey: .blocksCommunityMessageRequests)
        try container.encodeIfPresent(sessionProProof, forKey: .sessionProProof)
    }
}

// MARK: - Protobuf

public extension Profile {
    func toProto() -> SNProtoDataMessage? {
        let dataMessageProto = SNProtoDataMessage.builder()
        let profileProto = SNProtoLokiProfile.builder()
        profileProto.setDisplayName(name)
        
        if
            let displayPictureEncryptionKey: Data = displayPictureEncryptionKey,
            let displayPictureUrl: String = displayPictureUrl
        {
            dataMessageProto.setProfileKey(displayPictureEncryptionKey)
            profileProto.setProfilePicture(displayPictureUrl)
            // TODO: Add ProProof if needed
        }
        
        if let profileLastUpdated: TimeInterval = profileLastUpdated {
            profileProto.setProfileUpdateTimestamp(UInt64(profileLastUpdated))
        }
        
        do {
            dataMessageProto.setProfile(try profileProto.build())
            return try dataMessageProto.build()
        }
        catch {
            Log.warn(.messageSender, "Couldn't construct profile proto from: \(self).")
            return nil
        }
    }
}

// MARK: - GRDB Interactions

public extension Profile {
    static func displayName(
        _ db: ObservingDatabase,
        id: ID,
        threadVariant: SessionThread.Variant = .contact,
        customFallback: String? = nil
    ) -> String {
        let existingDisplayName: String? = (try? Profile.fetchOne(db, id: id))?
            .displayName(for: threadVariant)
        
        return (existingDisplayName ?? (customFallback ?? id))
    }
    
    static func displayNameNoFallback(
        _ db: ObservingDatabase,
        id: ID,
        threadVariant: SessionThread.Variant = .contact
    ) -> String? {
        return (try? Profile.fetchOne(db, id: id))?
            .displayName(for: threadVariant)
    }
    
    // MARK: - Fetch or Create
    
    static func defaultFor(_ id: String) -> Profile {
        return Profile(
            id: id,
            name: "",
            nickname: nil,
            displayPictureUrl: nil,
            displayPictureEncryptionKey: nil,
            profileLastUpdated: nil,
            blocksCommunityMessageRequests: nil,
            sessionProProof: nil
        )
    }
    
    /// Fetches or creates a Profile for the specified user
    ///
    /// **Note:** This method intentionally does **not** save the newly created Profile,
    /// it will need to be explicitly saved after calling
    static func fetchOrCreate(_ db: ObservingDatabase, id: String) -> Profile {
        return (
            (try? Profile.fetchOne(db, id: id)) ??
            defaultFor(id)
        )
    }
}

// MARK: - Deprecated GRDB Interactions

public extension Profile {
    @available(*, deprecated, message: "This function should be avoided as it uses a blocking database query to retrieve the result. Use an async method instead.")
    static func displayName(
        id: ID,
        threadVariant: SessionThread.Variant = .contact,
        customFallback: String? = nil,
        using dependencies: Dependencies
    ) -> String {
        let semaphore: DispatchSemaphore = DispatchSemaphore(value: 0)
        var displayName: String?
        dependencies[singleton: .storage].readAsync(
            retrieve: { db in Profile.displayName(db, id: id, threadVariant: threadVariant) },
            completion: { result in
                switch result {
                    case .failure: break
                    case .success(let name): displayName = name
                }
                semaphore.signal()
            }
        )
        semaphore.wait()
        return (displayName ?? (customFallback ?? id))
    }
    
    @available(*, deprecated, message: "This function should be avoided as it uses a blocking database query to retrieve the result. Use an async method instead.")
    static func displayNameNoFallback(
        id: ID,
        threadVariant: SessionThread.Variant = .contact,
        using dependencies: Dependencies
    ) -> String? {
        let semaphore: DispatchSemaphore = DispatchSemaphore(value: 0)
        var displayName: String?
        dependencies[singleton: .storage].readAsync(
            retrieve: { db in Profile.displayNameNoFallback(db, id: id, threadVariant: threadVariant) },
            completion: { result in
                switch result {
                    case .failure: break
                    case .success(let name): displayName = name
                }
                semaphore.signal()
            }
        )
        semaphore.wait()
        return displayName
    }
}


// MARK: - Search Queries

public extension Profile {
    struct FullTextSearch: Decodable, ColumnExpressible {
        public typealias Columns = CodingKeys
        public enum CodingKeys: String, CodingKey, ColumnExpression, CaseIterable {
            case nickname
            case name
        }
        
        let nickname: String?
        let name: String
    }
}

// MARK: - Convenience

public extension Profile {
    func displayNameForMention(
        for threadVariant: SessionThread.Variant = .contact,
        ignoringNickname: Bool = false,
        currentUserSessionIds: Set<String> = []
    ) -> String {
        guard !currentUserSessionIds.contains(id) else {
            return "you".localized()
        }
        return displayName(for: threadVariant, ignoringNickname: ignoringNickname)
    }
    
    /// The name to display in the UI for a given thread variant
    func displayName(
        for threadVariant: SessionThread.Variant = .contact,
        messageProfile: VisibleMessage.VMProfile? = nil,
        ignoringNickname: Bool = false,
        suppressId: Bool = false
    ) -> String {
        return Profile.displayName(
            for: threadVariant,
            id: id,
            name: (messageProfile?.displayName?.nullIfEmpty ?? name),
            nickname: (ignoringNickname ? nil : nickname),
            suppressId: suppressId
        )
    }
    
    static func displayName(
        for threadVariant: SessionThread.Variant,
        id: String,
        name: String?,
        nickname: String?,
        suppressId: Bool,
        customFallback: String? = nil
    ) -> String {
        if let nickname: String = nickname, !nickname.isEmpty { return nickname }
        
        guard let name: String = name, name != id, !name.isEmpty else {
            return (customFallback ?? id.truncated(threadVariant: threadVariant))
        }
        
        switch (threadVariant, suppressId) {
            case (.contact, _), (.legacyGroup, _), (.group, _), (.community, true): return name
                
            case (.community, false):
                // In open groups, where it's more likely that multiple users have the same name,
                // we display a bit of the Session ID after a user's display name for added context
                return "\(name) (\(id.truncated()))"
        }
    }
}

// MARK: - WithProfile<T>

public struct WithProfile<T: ProfileAssociated>: Equatable, Hashable, Comparable {
    public let value: T
    public let profile: Profile?
    public let currentUserSessionId: SessionId
    
    public var profileId: String { value.profileId }
    
    public init(value: T, profile: Profile?, currentUserSessionId: SessionId) {
        self.value = value
        self.profile = profile
        self.currentUserSessionId = currentUserSessionId
    }
    
    public func itemDescription(using dependencies: Dependencies) -> String? {
        return value.itemDescription(using: dependencies)
    }
    
    public func itemDescriptionColor(using dependencies: Dependencies) -> ThemeValue {
        return value.itemDescriptionColor(using: dependencies)
    }
    
    public static func < (lhs: WithProfile<T>, rhs: WithProfile<T>) -> Bool {
        return T.compare(lhs: lhs, rhs: rhs)
    }
}

extension WithProfile: Differentiable where T: Differentiable {}

public protocol ProfileAssociated: Equatable, Hashable {
    var profileId: String { get }
    var profileIcon: ProfilePictureView.ProfileIcon { get }
    
    func itemDescription(using dependencies: Dependencies) -> String?
    func itemDescriptionColor(using dependencies: Dependencies) -> ThemeValue
    static func compare(lhs: WithProfile<Self>, rhs: WithProfile<Self>) -> Bool
}

public extension ProfileAssociated {
    var profileIcon: ProfilePictureView.ProfileIcon { return .none }
    
    func itemDescription(using dependencies: Dependencies) -> String? { return nil }
    func itemDescriptionColor(using dependencies: Dependencies) -> ThemeValue { return .textPrimary }
}

public extension FetchRequest where RowDecoder: FetchableRecord & ProfileAssociated {
    func fetchAllWithProfiles(_ db: ObservingDatabase, using dependencies: Dependencies) throws -> [WithProfile<RowDecoder>] {
        let originalResult: [RowDecoder] = try self.fetchAll(db)
        let profiles: [String: Profile]? = try? Profile
            .fetchAll(db, ids: originalResult.map { $0.profileId }.asSet())
            .reduce(into: [:]) { result, next in result[next.id] = next }
        
        return originalResult.map {
            WithProfile(
                value: $0,
                profile: profiles?[$0.profileId],
                currentUserSessionId: dependencies[cache: .general].sessionId
            )
        }
    }
}

// MARK: - Convenience

public extension Profile {
    func with(
        name: String? = nil,
        nickname: String?? = nil,
        displayPictureUrl: String?? = nil
    ) -> Profile {
        return Profile(
            id: id,
            name: (name ?? self.name),
            nickname: (nickname ?? self.nickname),
            displayPictureUrl: (displayPictureUrl ?? self.displayPictureUrl),
            displayPictureEncryptionKey: displayPictureEncryptionKey,
            profileLastUpdated: profileLastUpdated,
            blocksCommunityMessageRequests: blocksCommunityMessageRequests,
            sessionProProof: self.sessionProProof
        )
    }
}
