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
    
    public typealias Columns = CodingKeys
    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case id
        
        case name
        case nickname
        
        case displayPictureUrl
        case displayPictureEncryptionKey
        
        case profileLastUpdated
        
        case blocksCommunityMessageRequests
        
        case proFeatures
        case proExpiryUnixTimestampMs
        case proGenIndexHashHex
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
    
    /// The Session Pro features enabled for this profile
    public let proFeatures: SessionPro.ProfileFeatures
    
    /// The unix timestamp (in milliseconds) when Session Pro expires for this profile
    public let proExpiryUnixTimestampMs: UInt64
    
    /// Hash of the generation index for this users Session Pro
    public let proGenIndexHashHex: String?
    
    // MARK: - Initialization
    
    public static func with(
        id: String,
        name: String,
        nickname: String? = nil,
        displayPictureUrl: String? = nil,
        displayPictureEncryptionKey: Data? = nil,
        profileLastUpdated: TimeInterval? = nil,
        blocksCommunityMessageRequests: Bool? = nil,
        proFeatures: SessionPro.ProfileFeatures = .none,
        proExpiryUnixTimestampMs: UInt64 = 0,
        proGenIndexHashHex: String? = nil
    ) -> Profile {
        return Profile(
            id: id,
            name: name,
            nickname: nickname,
            displayPictureUrl: displayPictureUrl,
            displayPictureEncryptionKey: displayPictureEncryptionKey,
            profileLastUpdated: profileLastUpdated,
            blocksCommunityMessageRequests: blocksCommunityMessageRequests,
            proFeatures: proFeatures,
            proExpiryUnixTimestampMs: proExpiryUnixTimestampMs,
            proGenIndexHashHex: proGenIndexHashHex
        )
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
            proFeatures: \(proFeatures),
            proExpiryUnixTimestampMs: \(proExpiryUnixTimestampMs),
            proGenIndexHashHex: \(proGenIndexHashHex.map { "\($0)" } ?? "null")
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
            nickname: try container.decodeIfPresent(String.self, forKey: .nickname),
            displayPictureUrl: displayPictureUrl,
            displayPictureEncryptionKey: displayPictureKey,
            profileLastUpdated: try container.decodeIfPresent(TimeInterval.self, forKey: .profileLastUpdated),
            blocksCommunityMessageRequests: try container.decodeIfPresent(Bool.self, forKey: .blocksCommunityMessageRequests),
            proFeatures: try container.decode(SessionPro.ProfileFeatures.self, forKey: .proFeatures),
            proExpiryUnixTimestampMs: try container.decode(UInt64.self, forKey: .proExpiryUnixTimestampMs),
            proGenIndexHashHex: try container.decodeIfPresent(String.self, forKey: .proGenIndexHashHex)
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
        try container.encode(proFeatures, forKey: .proFeatures)
        try container.encode(proExpiryUnixTimestampMs, forKey: .proExpiryUnixTimestampMs)
        try container.encodeIfPresent(proGenIndexHashHex, forKey: .proGenIndexHashHex)
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
        }
        
        if let profileLastUpdated: TimeInterval = profileLastUpdated {
            profileProto.setLastUpdateSeconds(UInt64(profileLastUpdated))
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
        customFallback: String? = nil
    ) -> String {
        let existingDisplayName: String? = (try? Profile.fetchOne(db, id: id))?.displayName()
        
        return (existingDisplayName ?? (customFallback ?? id))
    }
    
    static func displayNameNoFallback(
        _ db: ObservingDatabase,
        id: ID,
        threadVariant: SessionThread.Variant = .contact,
        suppressId: Bool = false
    ) -> String? {
        return (try? Profile.fetchOne(db, id: id))?.displayName()
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
            proFeatures: .none,
            proExpiryUnixTimestampMs: 0,
            proGenIndexHashHex: nil
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
    /// The name to display in the UI for a given thread variant
    func displayName(
        messageProfile: VisibleMessage.VMProfile? = nil,
        ignoreNickname: Bool = false,
        showYouForCurrentUser: Bool = true,
        currentUserSessionIds: Set<String> = [],
        includeSessionIdSuffix: Bool = false
    ) -> String {
        return Profile.displayName(
            id: id,
            name: (messageProfile?.displayName?.nullIfEmpty ?? name),
            nickname: (ignoreNickname ? nil : nickname),
            showYouForCurrentUser: showYouForCurrentUser,
            currentUserSessionIds: currentUserSessionIds,
            includeSessionIdSuffix: includeSessionIdSuffix
        )
    }
    
    static func displayName(
        id: String,
        name: String?,
        nickname: String?,
        showYouForCurrentUser: Bool = true,
        currentUserSessionIds: Set<String> = [],
        includeSessionIdSuffix: Bool = false,
        customFallback: String? = nil
    ) -> String {
        if showYouForCurrentUser && currentUserSessionIds.contains(id) {
            return "you".localized()
        }
        
        // stringlint:ignore_contents
        switch (nickname, name, customFallback, includeSessionIdSuffix) {
            case (.some(let value), _, _, false) where !value.isEmpty && value != id,
                (_, .some(let value), _, false) where !value.isEmpty && value != id,
                (_, _, .some(let value), false) where !value.isEmpty && value != id:
                return value
                
            case (.some(let value), _, _, true) where !value.isEmpty && value != id,
                (_, .some(let value), _, true) where !value.isEmpty && value != id,
                (_, _, .some(let value), true) where !value.isEmpty && value != id:
                return (Dependencies.isRTL ?
                    "(\(id.truncated(prefix: 4, suffix: 4))) \(value)" :
                    "​\(value) (\(id.truncated(prefix: 4, suffix: 4)))"
                )
            
            default: return id.truncated(prefix: 4, suffix: 4)
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
    var profileIcon: ProfilePictureView.Info.ProfileIcon { get }
    
    func itemDescription(using dependencies: Dependencies) -> String?
    func itemDescriptionColor(using dependencies: Dependencies) -> ThemeValue
    static func compare(lhs: WithProfile<Self>, rhs: WithProfile<Self>) -> Bool
}

public extension ProfileAssociated {
    var profileIcon: ProfilePictureView.Info.ProfileIcon { return .none }
    
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
        nickname: Update<String?> = .useExisting,
        displayPictureUrl: Update<String?> = .useExisting,
        displayPictureEncryptionKey: Update<Data?> = .useExisting,
        profileLastUpdated: Update<TimeInterval?> = .useExisting,
        blocksCommunityMessageRequests: Update<Bool?> = .useExisting,
        proFeatures: Update<SessionPro.ProfileFeatures> = .useExisting,
        proExpiryUnixTimestampMs: Update<UInt64> = .useExisting,
        proGenIndexHashHex: Update<String?> = .useExisting
    ) -> Profile {
        return Profile(
            id: id,
            name: (name ?? self.name),
            nickname: nickname.or(self.nickname),
            displayPictureUrl: displayPictureUrl.or(self.displayPictureUrl),
            displayPictureEncryptionKey: displayPictureEncryptionKey.or(self.displayPictureEncryptionKey),
            profileLastUpdated: profileLastUpdated.or(self.profileLastUpdated),
            blocksCommunityMessageRequests: blocksCommunityMessageRequests.or(self.blocksCommunityMessageRequests),
            proFeatures: proFeatures.or(self.proFeatures),
            proExpiryUnixTimestampMs: proExpiryUnixTimestampMs.or(self.proExpiryUnixTimestampMs),
            proGenIndexHashHex: proGenIndexHashHex.or(self.proGenIndexHashHex)
        )
    }
}
