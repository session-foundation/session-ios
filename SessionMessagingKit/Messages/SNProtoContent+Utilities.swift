// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

public extension SNProtoContent {
    /// Add attachment proto information if required
    ///
    /// **Note:** This function expects the `attachments` array to be sorted in a way that matches the order of the
    /// `InteractionAttachment` values
    func addingAttachmentsIfNeeded(
        _ message: Message,
        _ attachments: [Attachment]? = nil
    ) throws -> SNProtoContent? {
        guard
            let message: VisibleMessage = message as? VisibleMessage, (
                !message.attachmentIds.isEmpty ||
                message.linkPreview?.attachmentId != nil
            )
        else { return self }
        
        /// Calculate attachment information
        let expectedAttachmentUploadCount: Int = (
            message.attachmentIds.count +
            (message.linkPreview?.attachmentId != nil ? 1 : 0)
        )
        let uniqueAttachmentIds: Set<String> = Set(message.attachmentIds)
            .inserting(message.linkPreview?.attachmentId)
        
        /// We need to ensure we don't send a message which should have uploaded files but hasn't, we do this by comparing the
        /// `attachmentIds` on the `VisibleMessage` to the `attachments` value
        guard expectedAttachmentUploadCount == (attachments?.count ?? 0) else {
            throw MessageSenderError.attachmentsNotUploaded
        }
        
        /// Ensure we haven't incorrectly included the `linkPreview` or `quote` attachments in the main `attachmentIds`
        guard uniqueAttachmentIds.count == expectedAttachmentUploadCount else {
            throw MessageSenderError.attachmentsInvalid
        }
        
        do {
            var processedAttachments: [Attachment] = (attachments ?? [])
            
            /// Recreate the builder for the proto
            guard let dataMessage = dataMessage?.asBuilder() else {
                Log.warn(.messageSender, "Couldn't recreate dataMessage builder from: \(message).")
                return nil
            }
            
            let builder = self.asBuilder()
            var attachmentIds: [String] = message.attachmentIds
            
            /// Link preview
            if let attachmentId: String = message.linkPreview?.attachmentId {
                if let index: Array<String>.Index = attachmentIds.firstIndex(of: attachmentId) {
                    attachmentIds.remove(at: index)
                }
                
                if
                    let linkPreviewBuilder = self.dataMessage?.preview.first?.asBuilder(),
                    let attachment: Attachment = processedAttachments.first(where: { $0.id == attachmentId }),
                    let attachmentProto = attachment.buildProto()
                {
                    linkPreviewBuilder.setImage(attachmentProto)
                    try dataMessage.setPreview([ linkPreviewBuilder.build() ])
                }
                
                /// Remove the `linkPreview` attachment from the general attachments set
                processedAttachments = processedAttachments.filter { $0.id != attachmentId }
            }
            
            /// Attachments
            let attachmentProtos = processedAttachments.compactMap { $0.buildProto() }
            dataMessage.setAttachments(attachmentProtos)
        
            /// Build
            builder.setDataMessage(try dataMessage.build())
            return try builder.build()
        } catch {
            Log.warn(.messageSender, "Couldn't add attachments to proto from: \(message).")
            return nil
        }
    }
}
