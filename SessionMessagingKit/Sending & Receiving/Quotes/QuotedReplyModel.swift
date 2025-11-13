// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB

public struct QuotedReplyModel: Sendable, Equatable, Hashable {
    public let threadId: String
    public let quotedInteractionId: Int64?
    public let authorId: String
    public let authorName: String
    public let timestampMs: Int64
    public let body: String?
    public let attachment: Attachment?
    public let contentType: String?
    public let sourceFileName: String?
    public let thumbnailDownloadFailed: Bool
    public let proFeatures: SessionPro.Features
    public let currentUserSessionIds: Set<String>
    
    // MARK: - Initialization
    
    private init(
        threadId: String,
        quotedInteractionId: Int64?,
        authorId: String,
        authorName: String,
        timestampMs: Int64,
        body: String?,
        attachment: Attachment?,
        contentType: String?,
        sourceFileName: String?,
        thumbnailDownloadFailed: Bool,
        proFeatures: SessionPro.Features,
        currentUserSessionIds: Set<String>
    ) {
        self.threadId = threadId
        self.quotedInteractionId = quotedInteractionId
        self.authorId = authorId
        self.authorName = authorName
        self.timestampMs = timestampMs
        self.body = body
        self.attachment = attachment
        self.contentType = contentType
        self.sourceFileName = sourceFileName
        self.thumbnailDownloadFailed = thumbnailDownloadFailed
        self.proFeatures = proFeatures
        self.currentUserSessionIds = currentUserSessionIds
    }
    
    public static func quotedReplyForSending(
        threadId: String,
        quotedInteractionId: Int64?,
        authorId: String,
        authorName: String,
        variant: Interaction.Variant,
        body: String?,
        timestampMs: Int64,
        attachments: [Attachment]?,
        linkPreviewAttachment: Attachment?,
        proFeatures: SessionPro.Features,
        currentUserSessionIds: Set<String>
    ) -> QuotedReplyModel? {
        guard variant == .standardOutgoing || variant == .standardIncoming else { return nil }
        guard (body != nil && body?.isEmpty == false) || attachments?.isEmpty == false else { return nil }
        
        let targetAttachment: Attachment? = (attachments?.first ?? linkPreviewAttachment)
        
        return QuotedReplyModel(
            threadId: threadId,
            quotedInteractionId: quotedInteractionId,
            authorId: authorId,
            authorName: authorName,
            timestampMs: timestampMs,
            body: body,
            attachment: targetAttachment,
            contentType: targetAttachment?.contentType,
            sourceFileName: targetAttachment?.sourceFilename,
            thumbnailDownloadFailed: false,
            proFeatures: proFeatures,
            currentUserSessionIds: currentUserSessionIds
        )
    }
}
