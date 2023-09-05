// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

public final class ConfigurationMessage: ControlMessage {
    private enum CodingKeys: String, CodingKey {
        case displayName
        case profilePictureUrl
        case profileKey
    }
    
    public var displayName: String?
    public var profilePictureUrl: String?
    public var profileKey: Data?

    public override var isSelfSendValid: Bool { true }

    // MARK: - Initialization

    public init(
        displayName: String?,
        profilePictureUrl: String?,
        profileKey: Data?
    ) {
        super.init()

        self.displayName = displayName
        self.profilePictureUrl = profilePictureUrl
        self.profileKey = profileKey
    }

    // MARK: - Codable

    required init(from decoder: Decoder) throws {
        try super.init(from: decoder)

        let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)

        displayName = try? container.decode(String.self, forKey: .displayName)
        profilePictureUrl = try? container.decode(String.self, forKey: .profilePictureUrl)
        profileKey = try? container.decode(Data.self, forKey: .profileKey)
    }

    public override func encode(to encoder: Encoder) throws {
        try super.encode(to: encoder)

        var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)

        try container.encodeIfPresent(displayName, forKey: .displayName)
        try container.encodeIfPresent(profilePictureUrl, forKey: .profilePictureUrl)
        try container.encodeIfPresent(profileKey, forKey: .profileKey)
    }

    // MARK: - Proto Conversion
    
    public override class func fromProto(_ proto: SNProtoContent, sender: String) -> ConfigurationMessage? {
        guard let configurationProto = proto.configurationMessage else { return nil }
        
        let displayName = configurationProto.displayName
        let profilePictureUrl = configurationProto.profilePicture
        let profileKey = configurationProto.profileKey

        return ConfigurationMessage(
            displayName: displayName,
            profilePictureUrl: profilePictureUrl,
            profileKey: profileKey
        )
    }

    public override func toProto(_ db: Database) -> SNProtoContent? { return nil }

    // MARK: - Description
    
    public var description: String {
        """
        LegacyConfigurationMessage(
            displayName: \(displayName ?? "null"),
            profilePictureUrl: \(profilePictureUrl ?? "null"),
            profileKey: \(profileKey?.toHexString() ?? "null")
        )
        """
    }
}
