// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import Combine
import UniformTypeIdentifiers
import GRDB
import SessionUIKit
import SessionUtilitiesKit
import SessionNetworkingKit

public struct LinkPreview: Codable, Equatable, Hashable, FetchableRecord, PersistableRecord, TableRecord, ColumnExpressible {
    public static var databaseTableName: String { "linkPreview" }
    internal static let interactionForeignKey = ForeignKey(
        [Columns.url],
        to: [Interaction.Columns.linkPreviewUrl]
    )
    internal static let interactions = hasMany(Interaction.self, using: Interaction.linkPreviewForeignKey)
    public static let attachment = hasOne(Attachment.self, using: Attachment.linkPreviewForeignKey)
    
    /// We want to cache url previews to the nearest 100,000 seconds (~28 hours - simpler than 86,400) to ensure the user isn't shown a preview that is too stale
    internal static let timstampResolution: Double = 100000
    internal static let maxImageDimension: CGFloat = 600
    
    public typealias Columns = CodingKeys
    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case url
        case timestamp
        case variant
        case title
        case attachmentId
    }
    
    public enum Variant: Int, Codable, Hashable, DatabaseValueConvertible {
        case standard
        case openGroupInvitation
    }
    
    /// The url for the link preview
    public let url: String
    
    /// The number of seconds since epoch rounded down to the nearest 100,000 seconds (~day) - This
    /// allows us to optimise against duplicate urls without having "stale" data last too long
    public let timestamp: TimeInterval
    
    /// The type of link preview
    public let variant: Variant
    
    /// The title for the link
    public let title: String?
    
    /// The id for the attachment for the link preview image
    public let attachmentId: String?
    
    // MARK: - Relationships
    
    public var attachment: QueryInterfaceRequest<Attachment> {
        request(for: LinkPreview.attachment)
    }
    
    // MARK: - Initialization
    
    public init(
        url: String,
        timestamp: TimeInterval? = nil,
        variant: Variant = .standard,
        title: String?,
        attachmentId: String? = nil,
        using dependencies: Dependencies
    ) {
        self.url = url
        self.timestamp = (timestamp ?? LinkPreview.timestampFor(
            sentTimestampMs: dependencies[cache: .snodeAPI].currentOffsetTimestampMs()  // Default to now
        ))
        self.variant = variant
        self.title = title
        self.attachmentId = attachmentId
    }
}

// MARK: - Protobuf

public extension LinkPreview {
    init?(_ db: ObservingDatabase, proto: SNProtoDataMessage, sentTimestampMs: TimeInterval) throws {
        guard let previewProto = proto.preview.first else { throw LinkPreviewError.noPreview }
        guard URL(string: previewProto.url) != nil else { throw LinkPreviewError.invalidInput }
        guard LinkPreviewManager.isValidLinkUrl(previewProto.url) else { throw LinkPreviewError.invalidInput }
        
        // Try to get an existing link preview first
        let timestamp: TimeInterval = LinkPreview.timestampFor(sentTimestampMs: sentTimestampMs)
        let maybeLinkPreview: LinkPreview? = try? LinkPreview
            .filter(LinkPreview.Columns.url == previewProto.url)
            .filter(LinkPreview.Columns.timestamp == timestamp)
            .fetchOne(db)
        
        if let linkPreview: LinkPreview = maybeLinkPreview {
            self = linkPreview
            return
        }
        
        self.url = previewProto.url
        self.timestamp = timestamp
        self.variant = .standard
        self.title = LinkPreviewManager.normalizeTitle(title: previewProto.title)
        
        if let imageProto = previewProto.image {
            let attachment: Attachment = Attachment(proto: imageProto)
            try attachment.insert(db)
            
            self.attachmentId = attachment.id
        }
        else {
            self.attachmentId = nil
        }
        
        // Make sure the quote is valid before completing
        guard self.title != nil || self.attachmentId != nil else { throw LinkPreviewError.invalidInput }
    }
}

// MARK: - Convenience

public extension LinkPreview {
    static func timestampFor(sentTimestampMs: Double) -> TimeInterval {
        // We want to round the timestamp down to the nearest 100,000 seconds (~28 hours - simpler
        // than 86,400) to optimise LinkPreview storage without having too stale data
        return (floor(sentTimestampMs / 1000 / LinkPreview.timstampResolution) * LinkPreview.timstampResolution)
    }
    
    static func prepareAttachmentIfPossible(
        urlString: String,
        imageSource: ImageDataManager.DataSource?,
        using dependencies: Dependencies
    ) async throws -> PreparedAttachment? {
        guard let imageSource: ImageDataManager.DataSource = imageSource, imageSource.contentExists else {
            return nil
        }
        
        let pendingAttachment: PendingAttachment = PendingAttachment(
            source: .media(imageSource),
            using: dependencies
        )
        let targetFormat: PendingAttachment.ConversionFormat = (dependencies[feature: .usePngInsteadOfWebPForFallbackImageType] ?
            .png(maxDimension: LinkPreview.maxImageDimension) : .webPLossy(maxDimension: LinkPreview.maxImageDimension)
        )
        
        return try await pendingAttachment.prepare(
            operations: [
                .convert(to: targetFormat),
                .stripImageMetadata
            ],
            /// We only call `prepareAttachmentIfPossible` before sending so always store at the pending upload path
            storeAtPendingAttachmentUploadPath: true,
            using: dependencies
        )
    }
}
