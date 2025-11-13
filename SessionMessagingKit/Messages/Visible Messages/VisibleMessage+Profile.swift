// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

// MARK: - VisibleMessage.VMProfile

public extension VisibleMessage {
    struct VMProfile: Codable {
        public let displayName: String?
        public let profileKey: Data?
        public let profilePictureUrl: String?
        public let updateTimestampSeconds: TimeInterval?
        public let blocksCommunityMessageRequests: Bool?
        public let proFeatures: SessionPro.Features?
        
        // MARK: - Initialization

        private init(
            displayName: String,
            profileKey: Data? = nil,
            profilePictureUrl: String? = nil,
            updateTimestampSeconds: TimeInterval? = nil,
            blocksCommunityMessageRequests: Bool? = nil,
            proFeatures: SessionPro.Features? = nil
        ) {
            let hasUrlAndKey: Bool = (profileKey != nil && profilePictureUrl != nil)
            
            self.displayName = displayName
            self.profileKey = (hasUrlAndKey ? profileKey : nil)
            self.profilePictureUrl = (hasUrlAndKey ? profilePictureUrl : nil)
            self.updateTimestampSeconds = updateTimestampSeconds
            self.blocksCommunityMessageRequests = blocksCommunityMessageRequests
            self.proFeatures = proFeatures
        }
        
        internal init(profile: Profile, blocksCommunityMessageRequests: Bool? = nil) {
            self.init(
                displayName: profile.name,
                profileKey: profile.displayPictureEncryptionKey,
                profilePictureUrl: profile.displayPictureUrl,
                updateTimestampSeconds: profile.profileLastUpdated,
                blocksCommunityMessageRequests: blocksCommunityMessageRequests,
                proFeatures: profile.proFeatures
            )
        }

        // MARK: - Proto Conversion

        public static func fromProto(_ proto: ProtoWithProfile) -> VMProfile? {
            guard
                let profileProto = proto.profile,
                let displayName = profileProto.displayName
            else { return nil }
            
            return VMProfile(
                displayName: displayName,
                profileKey: proto.profileKey,
                profilePictureUrl: profileProto.profilePicture,
                updateTimestampSeconds: TimeInterval(profileProto.lastUpdateSeconds),
                blocksCommunityMessageRequests: (proto.hasBlocksCommunityMessageRequests ?
                    proto.blocksCommunityMessageRequests :
                    nil
                ),
                proFeatures: nil // TODO: [PRO] Add these once the protobuf is updated
            )
        }

        public func toProtoBuilder() throws -> SNProtoDataMessage.SNProtoDataMessageBuilder {
            guard let displayName = displayName else { throw MessageError.protoConversionFailed }
            
            let dataMessageProto = SNProtoDataMessage.builder()
            let profileProto = SNProtoLokiProfile.builder()
            profileProto.setDisplayName(displayName)
            
            if let blocksCommunityMessageRequests: Bool = self.blocksCommunityMessageRequests {
                dataMessageProto.setBlocksCommunityMessageRequests(blocksCommunityMessageRequests)
            }
            
            if let profileKey = profileKey, let profilePictureUrl = profilePictureUrl {
                dataMessageProto.setProfileKey(profileKey)
                profileProto.setProfilePicture(profilePictureUrl)
            }
            
            if let updateTimestampSeconds: TimeInterval = updateTimestampSeconds {
                profileProto.setLastUpdateSeconds(UInt64(updateTimestampSeconds))
            }
            
            dataMessageProto.setProfile(try profileProto.build())
            // TODO: [PRO] Add the 'proFeatures' value once the protobuf is updated
            return dataMessageProto
        }
        
        public func toProto() -> SNProtoDataMessage? {
            guard
                let dataMessageProtoBuilder = try? toProtoBuilder(),
                let result = try? dataMessageProtoBuilder.build()
            else {
                Log.warn(.messageSender, "Couldn't construct profile proto from: \(self).")
                return nil
            }
            
            return result
        }
        
        // MARK: - MessageRequestResponse
        
        public func toProto(isApproved: Bool) -> SNProtoMessageRequestResponse? {
            guard let displayName = displayName else {
                Log.warn(.messageSender, "Couldn't construct profile proto from: \(self).")
                return nil
            }
            let messageRequestResponseProto = SNProtoMessageRequestResponse.builder(
                isApproved: isApproved
            )
            let profileProto = SNProtoLokiProfile.builder()
            profileProto.setDisplayName(displayName)
            
            if let profileKey = profileKey, let profilePictureUrl = profilePictureUrl {
                messageRequestResponseProto.setProfileKey(profileKey)
                profileProto.setProfilePicture(profilePictureUrl)
            }
            if let updateTimestampSeconds: TimeInterval = updateTimestampSeconds {
                profileProto.setLastUpdateSeconds(UInt64(updateTimestampSeconds))
            }
            do {
                messageRequestResponseProto.setProfile(try profileProto.build())
                return try messageRequestResponseProto.build()
            } catch {
                Log.warn(.messageSender, "Couldn't construct profile proto from: \(self).")
                return nil
            }
        }
        
        // MARK: Description
        
        public var description: String {
            """
            Profile(
                displayName: \(displayName ?? "null"),
                profileKey: \(profileKey?.description ?? "null"),
                profilePictureUrl: \(profilePictureUrl ?? "null"),
                updateTimestampSeconds: \(updateTimestampSeconds ?? 0)
            )
            """
        }
    }
}

// MARK: - MessageWithProfile

public protocol MessageWithProfile {
    var profile: VisibleMessage.VMProfile? { get set }
}

extension VisibleMessage: MessageWithProfile {}
extension MessageRequestResponse: MessageWithProfile {}
extension GroupUpdateInviteMessage: MessageWithProfile {}
extension GroupUpdatePromoteMessage: MessageWithProfile {}
extension GroupUpdateInviteResponseMessage: MessageWithProfile {}

// MARK: - ProtoWithProfile

public protocol ProtoWithProfile {
    var profileKey: Data? { get }
    var profile: SNProtoLokiProfile? { get }
    
    var hasBlocksCommunityMessageRequests: Bool { get }
    var blocksCommunityMessageRequests: Bool { get }
}

extension SNProtoDataMessage: ProtoWithProfile {}
extension SNProtoMessageRequestResponse: ProtoWithProfile {
    public var hasBlocksCommunityMessageRequests: Bool { return false }
    public var blocksCommunityMessageRequests: Bool { return false }
}
