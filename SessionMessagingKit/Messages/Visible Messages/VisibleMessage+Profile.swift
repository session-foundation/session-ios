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
        public let sessionProProof: String?
        
        // MARK: - Initialization

        internal init(
            displayName: String,
            profileKey: Data? = nil,
            profilePictureUrl: String? = nil,
            updateTimestampSeconds: TimeInterval? = nil,
            blocksCommunityMessageRequests: Bool? = nil,
            sessionProProof: String? = nil
        ) {
            let hasUrlAndKey: Bool = (profileKey != nil && profilePictureUrl != nil)
            
            self.displayName = displayName
            self.profileKey = (hasUrlAndKey ? profileKey : nil)
            self.profilePictureUrl = (hasUrlAndKey ? profilePictureUrl : nil)
            self.updateTimestampSeconds = updateTimestampSeconds
            self.blocksCommunityMessageRequests = blocksCommunityMessageRequests
            self.sessionProProof = sessionProProof
        }

        // MARK: - Proto Conversion

        public static func fromProto(_ proto: SNProtoDataMessage) -> VMProfile? {
            guard
                let profileProto = proto.profile,
                let displayName = profileProto.displayName
            else { return nil }
            
            return VMProfile(
                displayName: displayName,
                profileKey: proto.profileKey,
                profilePictureUrl: profileProto.profilePicture,
                updateTimestampSeconds: TimeInterval(profileProto.lastUpdateSeconds),
                blocksCommunityMessageRequests: (proto.hasBlocksCommunityMessageRequests ? proto.blocksCommunityMessageRequests : nil),
                sessionProProof: nil // TODO: Add Session Pro Proof to profile proto
            )
        }

        public func toProtoBuilder() throws -> SNProtoDataMessage.SNProtoDataMessageBuilder {
            guard let displayName = displayName else { throw MessageSenderError.protoConversionFailed }
            
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
        
        public static func fromProto(_ proto: SNProtoMessageRequestResponse) -> VMProfile? {
            guard
                let profileProto = proto.profile,
                let displayName = profileProto.displayName
            else { return nil }
            
            return VMProfile(
                displayName: displayName,
                profileKey: proto.profileKey,
                profilePictureUrl: profileProto.profilePicture,
                updateTimestampSeconds: TimeInterval(profileProto.lastUpdateSeconds),
                sessionProProof: nil // TODO: Add Session Pro Proof to profile proto
            )
        }
        
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
                UpdateTimestampSeconds: \(updateTimestampSeconds ?? 0)
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
