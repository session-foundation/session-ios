// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

public extension VisibleMessage {
    struct VMLinkPreview: Codable {
        public let url: String
        public let title: String?
        public let attachmentId: String?
        public let nonInsertedAttachment: Attachment?

        public func validateMessage(isSending: Bool) throws {
            if !url.isEmpty { throw MessageError.invalidMessage("url") }
        }
        
        // MARK: - Initialization

        internal init(
            url: String,
            title: String?,
            attachmentId: String?,
            nonInsertedAttachment: Attachment?
        ) {
            self.url = url
            self.title = title
            self.attachmentId = attachmentId
            self.nonInsertedAttachment = nonInsertedAttachment
        }
        
        // MARK: - Proto Conversion

        public static func fromProto(_ proto: SNProtoDataMessagePreview) -> VMLinkPreview? {
            guard
                !proto.url.isEmpty,
                LinkPreview.isValidLinkUrl(proto.url)
            else { return nil }
            
            return VMLinkPreview(
                url: proto.url,
                title: proto.title,
                attachmentId: nil,
                nonInsertedAttachment: proto.image.map { Attachment(proto: $0) }
            )
        }

        public func toProto() -> SNProtoDataMessagePreview? {
            let linkPreviewProto = SNProtoDataMessagePreview.builder(url: url)
            if let title: String = title, !title.isEmpty { linkPreviewProto.setTitle(title) }
            
            do {
                return try linkPreviewProto.build()
            } catch {
                Log.warn(.messageSender, "Couldn't construct link preview proto from: \(self).")
                return nil
            }
        }
        
        // MARK: - Description
        
        public var description: String {
            """
            LinkPreview(
                url: \(url),
                title: \(title ?? "null"),
                attachmentId: \(attachmentId ?? "null"),
                nonInsertedAttachment: \(nonInsertedAttachment.map { "\($0)" } ?? "null")
            )
            """
        }
    }
}

// MARK: - Database Type Conversion

public extension VisibleMessage.VMLinkPreview {
    static func from(linkPreview: LinkPreview) -> VisibleMessage.VMLinkPreview {
        return VisibleMessage.VMLinkPreview(
            url: linkPreview.url,
            title: linkPreview.title,
            attachmentId: linkPreview.attachmentId,
            nonInsertedAttachment: nil
        )
    }
}
