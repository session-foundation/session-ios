// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import AVFAudio
import AVFoundation
import Combine
import UniformTypeIdentifiers
import GRDB
import SessionUtilitiesKit
import SessionSnodeKit
import SessionUIKit

public struct Attachment: Codable, Identifiable, Equatable, Hashable, FetchableRecord, PersistableRecord, TableRecord, ColumnExpressible {
    public static var databaseTableName: String { "attachment" }
    internal static let linkPreviewForeignKey = ForeignKey([Columns.id], to: [LinkPreview.Columns.attachmentId])
    public static let interactionAttachments = hasOne(InteractionAttachment.self)
    public static let interaction = hasOne(
        Interaction.self,
        through: interactionAttachments,
        using: InteractionAttachment.interaction
    )
    fileprivate static let linkPreview = belongsTo(LinkPreview.self, using: linkPreviewForeignKey)
    
    public typealias Columns = CodingKeys
    public enum CodingKeys: String, CodingKey, ColumnExpression, CaseIterable {
        case id
        case serverId
        case variant
        case state
        case contentType
        case byteCount
        case creationTimestamp
        case sourceFilename
        case downloadUrl
        case width
        case height
        case duration
        case isVisualMedia
        case isValid
        case encryptionKey
        case digest
        case caption
    }
    
    public enum Variant: Int, Codable, DatabaseValueConvertible {
        case standard
        case voiceMessage
    }
    
    public enum State: Int, Codable, DatabaseValueConvertible {
        case failedDownload
        case pendingDownload
        case downloading
        case downloaded
        case failedUpload
        case uploading
        case uploaded
        
        case invalid = 100
    }
    
    /// A unique identifier for the attachment
    public let id: String
    
    /// The id for the attachment returned by the server
    ///
    /// This will be null for attachments which haven’t completed uploading
    ///
    /// **Note:** This value is not unique as multiple SOGS could end up having the same file id
    public let serverId: String?
    
    /// The type of this attachment, used to distinguish logic handling
    public let variant: Variant
    
    /// The current state of the attachment
    public let state: State
    
    /// The MIMEType for the attachment
    public let contentType: String
    
    /// The size of the attachment in bytes
    ///
    /// **Note:** This may be `0` for some legacy attachments
    public let byteCount: UInt
    
    /// Timestamp in seconds since epoch for when this attachment was created
    ///
    /// **Uploaded:** This will be the timestamp the file finished uploading
    /// **Downloaded:** This will be the timestamp the file finished downloading
    /// **Other:** This will be null
    public let creationTimestamp: TimeInterval?
    
    /// Represents the "source" filename sent or received in the protos, not the filename on disk
    public let sourceFilename: String?
    
    /// The url the attachment can be downloaded from, this will be `null` for attachments which haven’t yet been uploaded
    ///
    /// **Note:** The url is a fully constructed url but the clients just extract the id from the end of the url to perform the actual download
    public let downloadUrl: String?
    
    /// The width of the attachment, this will be `null` for non-visual attachment types
    public let width: UInt?
    
    /// The height of the attachment, this will be `null` for non-visual attachment types
    public let height: UInt?
    
    /// The number of seconds the attachment plays for (this will only be set for video and audio attachment types)
    public let duration: TimeInterval?
    
    /// A flag indicating whether the attachment data is visual media
    public let isVisualMedia: Bool
    
    /// A flag indicating whether the attachment data downloaded is valid for it's content type
    public let isValid: Bool
    
    /// The key used to decrypt the attachment
    public let encryptionKey: Data?
    
    /// The computed digest for the attachment (generated from `iv || encrypted data || hmac`)
    public let digest: Data?
    
    /// Caption for the attachment
    public let caption: String?
    
    // MARK: - Initialization
    
    public init(
        id: String = UUID().uuidString,
        serverId: String? = nil,
        variant: Variant,
        state: State = .pendingDownload,
        contentType: String,
        byteCount: UInt,
        creationTimestamp: TimeInterval? = nil,
        sourceFilename: String? = nil,
        downloadUrl: String? = nil,
        width: UInt? = nil,
        height: UInt? = nil,
        duration: TimeInterval? = nil,
        isVisualMedia: Bool? = nil,
        isValid: Bool = false,
        encryptionKey: Data? = nil,
        digest: Data? = nil,
        caption: String? = nil
    ) {
        self.id = id
        self.serverId = serverId
        self.variant = variant
        self.state = state
        self.contentType = contentType
        self.byteCount = byteCount
        self.creationTimestamp = creationTimestamp
        self.sourceFilename = sourceFilename
        self.downloadUrl = downloadUrl
        self.width = width
        self.height = height
        self.duration = duration
        self.isVisualMedia = (isVisualMedia ?? UTType.isVisualMedia(contentType))
        self.isValid = isValid
        self.encryptionKey = encryptionKey
        self.digest = digest
        self.caption = caption
    }
    
    /// This initializer should only be used when converting from either a LinkPreview or a SignalAttachment to an Attachment (prior to upload)
    public init?(
        id: String = UUID().uuidString,
        variant: Variant = .standard,
        contentType: String,
        dataSource: any DataSource,
        sourceFilename: String? = nil,
        caption: String? = nil,
        using dependencies: Dependencies
    ) {
        guard
            let uploadInfo: (url: String, path: String) = try? dependencies[singleton: .attachmentManager]
                .uploadPathAndUrl(for: id),
            case .success = Result(try dataSource.write(to: uploadInfo.path))
        else { return nil }
        
        let imageSize: CGSize? = MediaUtils.unrotatedSize(
            for: uploadInfo.path,
            type: UTType(sessionMimeType: contentType),
            mimeType: contentType,
            sourceFilename: sourceFilename,
            using: dependencies
        )
        let (isValid, duration): (Bool, TimeInterval?) = dependencies[singleton: .attachmentManager].determineValidityAndDuration(
            contentType: contentType,
            downloadUrl: uploadInfo.url,
            sourceFilename: sourceFilename
        )
        
        self.id = id
        self.serverId = nil
        self.variant = variant
        self.state = .uploading
        self.contentType = contentType
        self.byteCount = UInt(dataSource.dataLength)
        self.creationTimestamp = nil
        self.sourceFilename = sourceFilename
        self.downloadUrl = uploadInfo.url   /// This value will be replaced once the upload is successful
        self.width = imageSize.map { UInt(floor($0.width)) }
        self.height = imageSize.map { UInt(floor($0.height)) }
        self.duration = duration
        self.isVisualMedia = UTType.isVisualMedia(contentType)
        self.isValid = isValid
        self.encryptionKey = nil
        self.digest = nil
        self.caption = caption
    }
}

// MARK: - CustomStringConvertible

extension Attachment: CustomStringConvertible {
    public struct DescriptionInfo: FetchableRecord, Decodable, Equatable, Hashable, ColumnExpressible {
        public typealias Columns = CodingKeys
        public enum CodingKeys: String, CodingKey, ColumnExpression, CaseIterable {
            case id
            case variant
            case contentType
            case sourceFilename
        }
        
        let id: String
        let variant: Attachment.Variant
        let contentType: String
        let sourceFilename: String?
        
        public init(
            id: String,
            variant: Attachment.Variant,
            contentType: String,
            sourceFilename: String?
        ) {
            self.id = id
            self.variant = variant
            self.contentType = contentType
            self.sourceFilename = sourceFilename
        }
        
        public init(id: String, proto: SNProtoAttachmentPointer, sourceFilename: String? = nil) {
            self.init(
                id: id,
                variant: {
                    let voiceMessageFlag: Int32 = SNProtoAttachmentPointer.SNProtoAttachmentPointerFlags
                        .voiceMessage
                        .rawValue
                    
                    guard proto.hasFlags && ((proto.flags & UInt32(voiceMessageFlag)) > 0) else {
                        return .standard
                    }
                    
                    return .voiceMessage
                }(),
                contentType: (
                    proto.contentType ??
                    Attachment.inferContentType(from: proto.fileName)
                ),
                sourceFilename: sourceFilename
            )
        }
    }
    
    public var descriptionInfo: DescriptionInfo {
        Attachment.DescriptionInfo(
            id: id,
            variant: variant,
            contentType: contentType,
            sourceFilename: sourceFilename
        )
    }
    
    public static func description(for descriptionInfo: DescriptionInfo?, count: Int?) -> String? {
        guard let descriptionInfo: DescriptionInfo = descriptionInfo else {
            return nil
        }
        
        return description(for: descriptionInfo, count: (count ?? 1))
    }
    
    public static func description(for descriptionInfo: DescriptionInfo, count: Int) -> String {
        // We only support multi-attachment sending of images so we can just default to the image attachment
        // if there were multiple attachments
        guard count == 1 else {
            return "attachmentsNotification"
                .put(key: "emoji", value: emoji(for: UTType.mimeTypeJpeg))
                .localized()
        }
        
        if UTType.isAudio(descriptionInfo.contentType) {
            // a missing filename is the legacy way to determine if an audio attachment is
            // a voice note vs. other arbitrary audio attachments.
            if
                descriptionInfo.variant == .voiceMessage ||
                descriptionInfo.sourceFilename == nil ||
                (descriptionInfo.sourceFilename?.count ?? 0) == 0
            {
                return "messageVoiceSnippet"
                    .put(key: "emoji", value: "🎙️")
                    .localized()
            }
        }
        
        return "attachmentsNotification"
            .put(key: "emoji", value: emoji(for: descriptionInfo.contentType))
            .localized()
    }
    
    // stringlint:ignore_contents
    public static func emoji(for contentType: String) -> String {
        if UTType.isAnimated(contentType) {
            return "🎡"
        }
        else if UTType.isVideo(contentType) {
            return "🎥"
        }
        else if UTType.isAudio(contentType) {
            return "🎧"
        }
        else if UTType.isImage(contentType) {
            return "📷"
        }
        
        return "📎"
    }
    
    public var description: String {
        return Attachment.description(
            for: DescriptionInfo(
                id: id,
                variant: variant,
                contentType: contentType,
                sourceFilename: sourceFilename
            ),
            count: 1
        )
    }
}

// MARK: - Mutation

extension Attachment {
    public func with(
        serverId: String? = nil,
        state: State? = nil,
        creationTimestamp: TimeInterval? = nil,
        downloadUrl: String? = nil,
        encryptionKey: Data? = nil,
        digest: Data? = nil,
        using dependencies: Dependencies
    ) -> Attachment {
        /// If the `downloadUrl` previously had a value and we are updating it then we need to move the file from it's current location
        /// to the hash that would be generated for the new location
        ///
        /// We default `finalDownloadUrl` to the current `downloadUrl` just in case moving the file fails (in which case we don't
        /// want to update it or we won't be able to resolve the stored file), but if we don't currently have a `downloadUrl` then we can
        /// just use the new one
        var finalDownloadUrl: String? = (self.downloadUrl ?? downloadUrl)
        
        if
            let newUrl: String = downloadUrl,
            let oldUrl: String = self.downloadUrl,
            newUrl != oldUrl
        {
            if
                let oldPath: String = try? dependencies[singleton: .attachmentManager].path(for: oldUrl),
                let newPath: String = try? dependencies[singleton: .attachmentManager].path(for: newUrl)
            {
                do {
                    try dependencies[singleton: .fileManager].moveItem(atPath: oldPath, toPath: newPath)
                    finalDownloadUrl = newUrl
                }
                catch {}
            }
        }
        
        let (isValid, duration): (Bool, TimeInterval?) = {
            switch (self.state, state) {
                case (_, .downloaded):
                    return dependencies[singleton: .attachmentManager].determineValidityAndDuration(
                        contentType: contentType,
                        downloadUrl: finalDownloadUrl,
                        sourceFilename: sourceFilename
                    )
                
                // Assume the data is already correct for "uploading" attachments (and don't override it)
                case (.uploading, _), (.uploaded, _), (.failedUpload, _): return (self.isValid, self.duration)
                case (_, .failedDownload): return (false, nil)
                    
                default: return (self.isValid, self.duration)
            }
        }()
        // Regenerate this just in case we added support since the attachment was inserted into
        // the database (eg. manually downloaded in a later update)
        let isVisualMedia: Bool = UTType.isVisualMedia(contentType)
        let attachmentResolution: CGSize? = {
            if let width: UInt = self.width, let height: UInt = self.height, width > 0, height > 0 {
                return CGSize(width: Int(width), height: Int(height))
            }
            guard
                isVisualMedia,
                state == .downloaded,
                let path: String = try? dependencies[singleton: .attachmentManager]
                    .path(for: finalDownloadUrl)
            else { return nil }
            
            return MediaUtils.unrotatedSize(
                for: path,
                type: UTType(sessionMimeType: contentType),
                mimeType: contentType,
                sourceFilename: sourceFilename,
                using: dependencies
            )
        }()
        
        return Attachment(
            id: self.id,
            serverId: (serverId ?? self.serverId),
            variant: variant,
            state: (state ?? self.state),
            contentType: contentType,
            byteCount: byteCount,
            creationTimestamp: (creationTimestamp ?? self.creationTimestamp),
            sourceFilename: sourceFilename,
            downloadUrl: finalDownloadUrl,
            width: attachmentResolution.map { UInt($0.width) },
            height: attachmentResolution.map { UInt($0.height) },
            duration: duration,
            isVisualMedia: (
                // Regenerate this just in case we added support since the attachment was inserted into
                // the database (eg. manually downloaded in a later update)
                UTType.isVisualMedia(contentType)
            ),
            isValid: isValid,
            encryptionKey: (encryptionKey ?? self.encryptionKey),
            digest: (digest ?? self.digest),
            caption: self.caption
        )
    }
}

// MARK: - Protobuf

extension Attachment {
    public static func inferContentType(from filename: String?) -> String {
        guard
            let fileName: String = filename,
            let fileExtension: String = URL(string: fileName)?.pathExtension
        else { return UTType.mimeTypeDefault }
        
        return (UTType.sessionMimeType(for: fileExtension) ?? UTType.mimeTypeDefault)
    }
    
    public init(proto: SNProtoAttachmentPointer) {
        self.id = UUID().uuidString
        self.serverId = "\(proto.id)"
        self.variant = {
            let voiceMessageFlag: Int32 = SNProtoAttachmentPointer.SNProtoAttachmentPointerFlags
                .voiceMessage
                .rawValue
            
            guard proto.hasFlags && ((proto.flags & UInt32(voiceMessageFlag)) > 0) else {
                return .standard
            }
            
            return .voiceMessage
        }()
        self.state = .pendingDownload
        self.contentType = (proto.contentType ?? Attachment.inferContentType(from: proto.fileName))
        self.byteCount = UInt(proto.size)
        self.creationTimestamp = nil
        self.sourceFilename = proto.fileName
        self.downloadUrl = proto.url
        self.width = (proto.hasWidth && proto.width > 0 ? UInt(proto.width) : nil)
        self.height = (proto.hasHeight && proto.height > 0 ? UInt(proto.height) : nil)
        self.duration = nil         // Needs to be downloaded to be set
        self.isVisualMedia = UTType.isVisualMedia(contentType)
        self.isValid = false        // Needs to be downloaded to be set
        self.encryptionKey = proto.key
        self.digest = proto.digest
        self.caption = (proto.hasCaption ? proto.caption : nil)
    }
    
    public func buildProto() -> SNProtoAttachmentPointer? {
        /// The `id` value on the protobuf is deprecated, rely on `url` instead
        ///
        /// **Note:** We need to continue to send this because it seems that the Desktop client _does_ in fact still use this
        /// id for downloading attachments. Desktop will be updated to remove it's use but in order to fix attachments for old
        /// versions we set this value again
        let legacyId: UInt64 = (Attachment.fileId(for: self.downloadUrl).map { UInt64($0) } ?? 0)
        let builder = SNProtoAttachmentPointer.builder(id: legacyId)
        builder.setContentType(contentType)
        
        if let sourceFilename: String = sourceFilename, !sourceFilename.isEmpty {
            builder.setFileName(sourceFilename)
        }
        
        if let caption: String = self.caption, !caption.isEmpty {
            builder.setCaption(caption)
        }
        
        builder.setSize(UInt32(byteCount))
        builder.setFlags(variant == .voiceMessage ?
            UInt32(SNProtoAttachmentPointer.SNProtoAttachmentPointerFlags.voiceMessage.rawValue) :
            0
        )
        
        if let encryptionKey: Data = encryptionKey, let digest: Data = digest {
            builder.setKey(encryptionKey)
            builder.setDigest(digest)
        }
        
        if
            let width: UInt = self.width,
            let height: UInt = self.height,
            width > 0,
            width < Int.max,
            height > 0,
            height < Int.max
        {
            builder.setWidth(UInt32(width))
            builder.setHeight(UInt32(height))
        }
        
        if let downloadUrl: String = self.downloadUrl {
            builder.setUrl(downloadUrl)
        }
        
        do {
            return try builder.build()
        }
        catch {
            Log.warn(.messageSender, "Couldn't construct attachment proto from: \(self).")
            return nil
        }
    }
}

// MARK: - GRDB Interactions

extension Attachment {
    public struct StateInfo: FetchableRecord, Decodable {
        public let attachmentId: String
        public let interactionId: Int64
        public let state: Attachment.State
        public let downloadUrl: String?
        public let albumIndex: Int
    }
    
    public static func stateInfo(authorId: String, state: State? = nil) -> SQLRequest<Attachment.StateInfo> {
        let attachment: TypedTableAlias<Attachment> = TypedTableAlias()
        let interaction: TypedTableAlias<Interaction> = TypedTableAlias()
        let interactionAttachment: TypedTableAlias<InteractionAttachment> = TypedTableAlias()
        let linkPreview: TypedTableAlias<LinkPreview> = TypedTableAlias()
        
        // Note: In GRDB all joins need to run via their "association" system which doesn't support the type
        // of query we have below (a required join based on one of 3 optional joins) so we have to construct
        // the query manually
        return """
            SELECT DISTINCT
                \(attachment[.id]) AS attachmentId,
                \(interaction[.id]) AS interactionId,
                \(attachment[.state]) AS state,
                \(attachment[.downloadUrl]) AS downloadUrl,
                IFNULL(\(interactionAttachment[.albumIndex]), 0) AS albumIndex
        
            FROM \(Attachment.self)
            
            JOIN \(Interaction.self) ON
                \(SQL("\(interaction[.authorId]) = \(authorId)")) AND (
                    \(interaction[.id]) = \(interactionAttachment[.interactionId]) OR
                    (
                        \(interaction[.linkPreviewUrl]) = \(linkPreview[.url]) AND
                        \(Interaction.linkPreviewFilterLiteral())
                    )
                )
            
            LEFT JOIN \(InteractionAttachment.self) ON \(interactionAttachment[.attachmentId]) = \(attachment[.id])
            LEFT JOIN \(LinkPreview.self) ON
                \(linkPreview[.attachmentId]) = \(attachment[.id]) AND
                \(SQL("\(linkPreview[.variant]) = \(LinkPreview.Variant.standard)"))
        
            WHERE
                (
                    \(SQL("\(state) IS NULL")) OR
                    \(SQL("\(attachment[.state]) = \(state)"))
                )
        
            ORDER BY interactionId DESC
        """
    }

    public static func stateInfo(interactionId: Int64, state: State? = nil) -> SQLRequest<Attachment.StateInfo> {
        let attachment: TypedTableAlias<Attachment> = TypedTableAlias()
        let interaction: TypedTableAlias<Interaction> = TypedTableAlias()
        let interactionAttachment: TypedTableAlias<InteractionAttachment> = TypedTableAlias()
        let linkPreview: TypedTableAlias<LinkPreview> = TypedTableAlias()
        
        // Note: In GRDB all joins need to run via their "association" system which doesn't support the type
        // of query we have below (a required join based on one of 3 optional joins) so we have to construct
        // the query manually
        return """
            SELECT DISTINCT
                \(attachment[.id]) AS attachmentId,
                \(interaction[.id]) AS interactionId,
                \(attachment[.state]) AS state,
                \(attachment[.downloadUrl]) AS downloadUrl,
                IFNULL(\(interactionAttachment[.albumIndex]), 0) AS albumIndex
        
            FROM \(Attachment.self)
            
            JOIN \(Interaction.self) ON
                \(SQL("\(interaction[.id]) = \(interactionId)")) AND (
                    \(interaction[.id]) = \(interactionAttachment[.interactionId]) OR
                    (
                        \(interaction[.linkPreviewUrl]) = \(linkPreview[.url]) AND
                        \(Interaction.linkPreviewFilterLiteral())
                    )
                )
            
            LEFT JOIN \(InteractionAttachment.self) ON \(interactionAttachment[.attachmentId]) = \(attachment[.id])
            LEFT JOIN \(LinkPreview.self) ON
                \(linkPreview[.attachmentId]) = \(attachment[.id]) AND
                \(SQL("\(linkPreview[.variant]) = \(LinkPreview.Variant.standard)"))
        
            WHERE
                (
                    \(SQL("\(state) IS NULL")) OR
                    \(SQL("\(attachment[.state]) = \(state)"))
                )
        """
    }
}

// MARK: - Convenience

extension Attachment {
    public var isImage: Bool { UTType.isImage(contentType) }
    public var isVideo: Bool { UTType.isVideo(contentType) }
    public var isAnimated: Bool { UTType.isAnimated(contentType) }
    public var isAudio: Bool { UTType.isAudio(contentType) }
    public var isText: Bool { UTType.isText(contentType) }
    public var isMicrosoftDoc: Bool { UTType.isMicrosoftDoc(contentType) }
    
    public var documentFileName: String {
        if let sourceFilename: String = sourceFilename { return sourceFilename }
        return shortDescription
    }
    
    public var shortDescription: String {
        if isImage { return "image".localized() }
        if isAudio { return "audio".localized() }
        if isVideo { return "video".localized() }
        return "document".localized()
    }
    
    public var documentFileInfo: String {
        switch duration {
            case .some(let duration) where duration > 0:
                return "\(Format.fileSize(byteCount)), \(Format.duration(duration))"
                
            default: return Format.fileSize(byteCount)
        }
    }
    
    public func readDataFromFile(using dependencies: Dependencies) throws -> Data? {
        guard
            let downloadUrl: String = downloadUrl,
            let path: String = try? dependencies[singleton: .attachmentManager].path(for: downloadUrl)
        else { return nil }
        
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }
    
    public func write(data: Data, using dependencies: Dependencies) throws -> Bool {
        guard
            let downloadUrl: String = downloadUrl,
            let path: String = try? dependencies[singleton: .attachmentManager].path(for: downloadUrl)
        else { return false }

        try data.write(to: URL(fileURLWithPath: path))

        return true
    }
    
    public static func fileId(for downloadUrl: String?) -> String? {
        return downloadUrl
            .map { urlString -> String? in
                urlString
                    .split(separator: "/")  // stringlint:ignore
                    .last
                    .map { String($0) }
            }
    }
}
