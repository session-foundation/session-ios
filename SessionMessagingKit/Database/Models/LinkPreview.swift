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

public struct LinkPreview: Sendable, Codable, Equatable, Hashable, FetchableRecord, PersistableRecord, TableRecord, ColumnExpressible {
    public static var databaseTableName: String { "linkPreview" }
    
    /// We want to cache url previews to the nearest 100,000 seconds (~28 hours - simpler than 86,400) to ensure the user isn't shown a preview that is too stale
    public static let timstampResolution: Double = 100000
    internal static let maxImageDimension: CGFloat = 600
    
    public typealias Columns = CodingKeys
    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case url
        case timestamp
        case variant
        case title
        case attachmentId
    }
    
    public enum Variant: Int, Sendable, Codable, Hashable, CaseIterable, DatabaseValueConvertible {
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
    
    // MARK: - Initialization
    
    public init(
        url: String,
        messageSentTimestampMs: UInt64? = nil,
        variant: Variant = .standard,
        title: String?,
        attachmentId: String? = nil,
        using dependencies: Dependencies
    ) {
        self.url = url
        self.variant = variant
        self.title = title
        self.attachmentId = attachmentId
        
        switch variant {
            case .openGroupInvitation:
                /// For an open group invitation we want to store the _actual_ timestamp rather than the rounded one because
                /// when we render we want to match the message to the specific link preview (if we don't do this then sending
                /// the url as a standard link preview within `timstampResolution` can cause the standard link to render as a
                /// community invitation or vice-versa
                self.timestamp = TimeInterval((messageSentTimestampMs ?? dependencies.networkOffsetTimestampMs()) / 1000)
                
            default:
                self.timestamp = LinkPreview.timestampFor(
                    sentTimestampMs: (messageSentTimestampMs ?? dependencies.networkOffsetTimestampMs())
                )
        }
    }
}

// MARK: - Protobuf

public extension LinkPreview {
    init?(
        _ db: ObservingDatabase,
        linkPreview: VisibleMessage.VMLinkPreview,
        sentTimestampMs: UInt64
    ) throws {
        guard LinkPreviewManager.isValidLinkUrl(linkPreview.url) else { throw LinkPreviewError.invalidInput }
        
        // Try to get an existing link preview first
        let timestamp: TimeInterval = LinkPreview.timestampFor(sentTimestampMs: sentTimestampMs)
        let maybeLinkPreview: LinkPreview? = try? LinkPreview
            .filter(LinkPreview.Columns.url == linkPreview.url)
            .filter(LinkPreview.Columns.timestamp == timestamp)
            .filter(LinkPreview.Columns.variant == LinkPreview.Variant.standard)
            .fetchOne(db)
        
        if let linkPreview: LinkPreview = maybeLinkPreview {
            self = linkPreview
            return
        }
        
        self.url = linkPreview.url
        self.timestamp = timestamp
        self.variant = .standard
        self.title = LinkPreviewManager.normalizeTitle(title: linkPreview.title)
        
        if let attachment: Attachment = linkPreview.nonInsertedAttachment {
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
    struct URLMatchResult {
        let urlString: String
        let matchRange: NSRange
    }
    
    static func timestampFor(sentTimestampMs: UInt64) -> TimeInterval {
        // We want to round the timestamp down to the nearest 100,000 seconds (~28 hours - simpler
        // than 86,400) to optimise LinkPreview storage without having too stale data
        return (floor(Double(sentTimestampMs) / 1000 / LinkPreview.timstampResolution) * LinkPreview.timstampResolution)
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
            .linkPreview,
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
