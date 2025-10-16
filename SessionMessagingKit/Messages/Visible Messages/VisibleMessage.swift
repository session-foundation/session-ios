// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

public final class VisibleMessage: Message {
    private enum CodingKeys: String, CodingKey {
        case syncTarget
        case text = "body"
        case attachmentIds = "attachments"
        case dataMessageHasAttachments
        case quote
        case linkPreview
        case profile
        case openGroupInvitation
        case reaction
    }
    
    /// In the case of a sync message, the public key of the person the message was targeted at.
    ///
    /// - Note: `nil` if this isn't a sync message.
    public var syncTarget: String?
    public let text: String?
    public var attachmentIds: [String]
    public let dataMessageHasAttachments: Bool?
    public let quote: VMQuote?
    public let linkPreview: VMLinkPreview?
    public var profile: VMProfile?
    public let openGroupInvitation: VMOpenGroupInvitation?
    public let reaction: VMReaction?

    public override var isSelfSendValid: Bool { true }
    
    // MARK: - Validation
    
    public override func validateMessage(isSending: Bool) throws {
        try super.validateMessage(isSending: isSending)
        
        let hasAttachments: Bool = (!attachmentIds.isEmpty || dataMessageHasAttachments == true)
        let hasOpenGroupInvitation: Bool = (openGroupInvitation != nil)
        let hasReaction: Bool = (reaction != nil)
        let hasText: Bool = (text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        
        if !hasAttachments && !hasOpenGroupInvitation && !hasReaction && !hasText {
            throw MessageError.invalidMessage("Has no content")
        }
    }
    
    // MARK: - Initialization
    
    public init(
        sender: String? = nil,
        sentTimestampMs: UInt64? = nil,
        syncTarget: String? = nil,
        text: String?,
        attachmentIds: [String] = [],
        dataMessageHasAttachments: Bool? = nil,
        quote: VMQuote? = nil,
        linkPreview: VMLinkPreview? = nil,
        profile: VMProfile? = nil,   // Added when sending via the `MessageWithProfile` protocol
        openGroupInvitation: VMOpenGroupInvitation? = nil,
        reaction: VMReaction? = nil
    ) {
        self.syncTarget = syncTarget
        self.text = text
        self.attachmentIds = attachmentIds
        self.dataMessageHasAttachments = dataMessageHasAttachments
        self.quote = quote
        self.linkPreview = linkPreview
        self.profile = profile
        self.openGroupInvitation = openGroupInvitation
        self.reaction = reaction
        
        super.init(
            sentTimestampMs: sentTimestampMs,
            sender: sender
        )
    }
    
    // MARK: - Codable
    
    required init(from decoder: Decoder) throws {
        let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
        
        syncTarget = try? container.decode(String.self, forKey: .syncTarget)
        text = try? container.decode(String.self, forKey: .text)
        attachmentIds = ((try? container.decode([String].self, forKey: .attachmentIds)) ?? [])
        dataMessageHasAttachments = try? container.decode(Bool.self, forKey: .dataMessageHasAttachments)
        quote = try? container.decode(VMQuote.self, forKey: .quote)
        linkPreview = try? container.decode(VMLinkPreview.self, forKey: .linkPreview)
        profile = try? container.decode(VMProfile.self, forKey: .profile)
        openGroupInvitation = try? container.decode(VMOpenGroupInvitation.self, forKey: .openGroupInvitation)
        reaction = try? container.decode(VMReaction.self, forKey: .reaction)
        
        try super.init(from: decoder)
    }
    
    public override func encode(to encoder: Encoder) throws {
        try super.encode(to: encoder)
        
        var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)
        
        try container.encodeIfPresent(syncTarget, forKey: .syncTarget)
        try container.encodeIfPresent(text, forKey: .text)
        try container.encodeIfPresent(attachmentIds, forKey: .attachmentIds)
        try container.encodeIfPresent(dataMessageHasAttachments, forKey: .dataMessageHasAttachments)
        try container.encodeIfPresent(quote, forKey: .quote)
        try container.encodeIfPresent(linkPreview, forKey: .linkPreview)
        try container.encodeIfPresent(profile, forKey: .profile)
        try container.encodeIfPresent(openGroupInvitation, forKey: .openGroupInvitation)
        try container.encodeIfPresent(reaction, forKey: .reaction)
    }

    // MARK: - Proto Conversion
    
    public override class func fromProto(_ proto: SNProtoContent, sender: String, using dependencies: Dependencies) -> VisibleMessage? {
        guard let dataMessage = proto.dataMessage else { return nil }
        
        return VisibleMessage(
            syncTarget: dataMessage.syncTarget,
            text: dataMessage.body,
            attachmentIds: [],    // Attachments are handled in MessageReceiver
            dataMessageHasAttachments: (proto.dataMessage?.attachments.isEmpty == false),
            quote: dataMessage.quote.map { VMQuote.fromProto($0) },
            linkPreview: dataMessage.preview.first.map { VMLinkPreview.fromProto($0) },
            profile: VMProfile.fromProto(dataMessage),
            openGroupInvitation: dataMessage.openGroupInvitation.map { VMOpenGroupInvitation.fromProto($0) },
            reaction: dataMessage.reaction.map { VMReaction.fromProto($0) }
        )
    }

    public override func toProto() -> SNProtoContent? {
        let proto = SNProtoContent.builder()
        if let sigTimestampMs = sigTimestampMs { proto.setSigTimestamp(sigTimestampMs) }
        
        let dataMessage: SNProtoDataMessage.SNProtoDataMessageBuilder
        
        // Profile
        if let profile = profile, let profileProto: SNProtoDataMessage = profile.toProto() {
            dataMessage = profileProto.asBuilder()
        }
        else {
            dataMessage = SNProtoDataMessage.builder()
        }
        
        // Text
        if let text = text { dataMessage.setBody(text) }
        
        // Quote
        
        if let quote = quote, let quoteProto = quote.toProto() {
            dataMessage.setQuote(quoteProto)
        }
        
        // Link preview
        if let linkPreviewAttachmentId = linkPreview?.attachmentId, let index = attachmentIds.firstIndex(of: linkPreviewAttachmentId) {
            attachmentIds.remove(at: index)
        }
        
        if let linkPreview = linkPreview, let linkPreviewProto = linkPreview.toProto() {
            dataMessage.setPreview([ linkPreviewProto ])
        }
        
        // Open group invitation
        if
            let openGroupInvitation = openGroupInvitation,
            let openGroupInvitationProto = openGroupInvitation.toProto()
        {
            dataMessage.setOpenGroupInvitation(openGroupInvitationProto)
        }
        
        // Emoji react
        if let reaction = reaction, let reactionProto = reaction.toProto() {
            dataMessage.setReaction(reactionProto)
        }
        
        // DisappearingMessagesConfiguration
        setDisappearingMessagesConfigurationIfNeeded(on: proto)
        
        // Sync target
        if let syncTarget = syncTarget {
            dataMessage.setSyncTarget(syncTarget)
        }
        
        // Build
        do {
            proto.setDataMessage(try dataMessage.build())
            return try proto.build()
        } catch {
            Log.warn(.messageSender, "Couldn't construct visible message proto from: \(self).")
            return nil
        }
    }
    
    // MARK: - Description
    
    public var description: String {
        """
        VisibleMessage(
            text: \(text ?? "null"),
            attachmentIds: \(attachmentIds),
            quote: \(quote?.description ?? "null"),
            linkPreview: \(linkPreview?.description ?? "null"),
            profile: \(profile?.description ?? "null"),
            reaction: \(reaction?.description ?? "null"),
            openGroupInvitation: \(openGroupInvitation?.description ?? "null")
        )
        """
    }
}
