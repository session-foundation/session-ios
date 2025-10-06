// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import AVFAudio
import AVFoundation
import Combine
import UniformTypeIdentifiers
import GRDB
import SDWebImageWebPCoder
import SessionUtil
import SessionUIKit
import SessionNetworkingKit
import SessionUtilitiesKit

// MARK: - Singleton

public extension Singleton {
    static let attachmentManager: SingletonConfig<AttachmentManager> = Dependencies.create(
        identifier: "attachmentManager",
        createInstance: { dependencies in AttachmentManager(using: dependencies) }
    )
}

// MARK: - Log.Category

public extension Log.Category {
    static let attachmentManager: Log.Category = .create("AttachmentManager", defaultLevel: .info)
}

// MARK: - AttachmentManager

public final class AttachmentManager: Sendable, ThumbnailManager {
    public static let maxAttachmentsAllowed: Int = 32
    
    private let dependencies: Dependencies
    
    // MARK: - Initalization
    
    init(using dependencies: Dependencies) {
        self.dependencies = dependencies
    }
    
    // MARK: - File Paths
    
    public func sharedDataAttachmentsDirPath() -> String {
        let path: String = URL(fileURLWithPath: SessionFileManager.nonInjectedAppSharedDataDirectoryPath)
            .appendingPathComponent("Attachments") // stringlint:ignore
            .path
        try? dependencies[singleton: .fileManager].ensureDirectoryExists(at: path)
        
        return path
    }
    
    private func placeholderUrlPath() -> String {
        let path: String = URL(fileURLWithPath: sharedDataAttachmentsDirPath())
            .appendingPathComponent("uploadPlaceholderUrl")  // stringlint:ignore
            .path
        try? dependencies[singleton: .fileManager].ensureDirectoryExists(at: path)
        
        return path
    }
    
    /// **Note:** Generally the url we get won't have an extension and we don't want to make assumptions until we have the actual
    /// image data so generate a name for the file and then determine the extension separately
    public func path(for urlString: String?) throws -> String {
        guard
            let urlString: String = urlString,
            !urlString.isEmpty
        else { throw AttachmentError.invalidPath }
        
        /// If the provided url is a placeholder url then it _is_ a valid path, so we should just return it directly
        guard !isPlaceholderUploadUrl(urlString) else { return urlString }
        
        /// Otherwise we need to generate the deterministic file path based on the url provided
        let urlHash = try dependencies[singleton: .crypto]
            .tryGenerate(.hash(message: Array(urlString.utf8)))
            .toHexString()
        
        return URL(fileURLWithPath: sharedDataAttachmentsDirPath())
            .appendingPathComponent(urlHash)
            .path
    }
    
    public func pendingUploadPath(for id: String) throws -> String {
        return URL(fileURLWithPath: placeholderUrlPath())
            .appendingPathComponent(id)
            .path
    }
    
    public func isPlaceholderUploadUrl(_ urlString: String?) -> Bool {
        guard
            let urlString: String = urlString,
            let url: URL = URL(string: urlString)
        else { return false }
        
        return url.path.hasPrefix(placeholderUrlPath())
    }
    
    public func temporaryPathForOpening(downloadUrl: String?, mimeType: String?, sourceFilename: String?) throws -> String {
        guard let downloadUrl: String = downloadUrl else { throw AttachmentError.invalidData }
        
        /// Since `mimeType` and/or `sourceFilename` can be null we need to try to resolve them both to values
        let finalExtension: String
        let targetFilenameNoExtension: String
        
        switch (mimeType, sourceFilename) {
            case (.none, .none): throw AttachmentError.invalidData
            case (.none, .some(let sourceFilename)):
                guard
                    let type: UTType = UTType(
                        sessionFileExtension: URL(fileURLWithPath: sourceFilename).pathExtension
                    ),
                    let fileExtension: String = type.sessionFileExtension(sourceFilename: sourceFilename)
                else { throw AttachmentError.invalidData }
                
                finalExtension = fileExtension
                targetFilenameNoExtension = String(sourceFilename.prefix(sourceFilename.count - (1 + fileExtension.count)))
                
            case (.some(let mimeType), let sourceFilename):
                guard
                    let fileExtension: String = UTType(sessionMimeType: mimeType)?
                        .sessionFileExtension(sourceFilename: sourceFilename)
                else { throw AttachmentError.invalidData }
                
                finalExtension = fileExtension
                targetFilenameNoExtension = try {
                    guard let sourceFilename: String = sourceFilename else {
                        return URL(fileURLWithPath: try path(for: downloadUrl)).lastPathComponent
                    }
                    
                    return (sourceFilename.hasSuffix(".\(fileExtension)") ? // stringlint:ignore
                        String(sourceFilename.prefix(sourceFilename.count - (1 + fileExtension.count))) :
                        sourceFilename
                    )
                }()
        }
        
        return URL(fileURLWithPath: dependencies[singleton: .fileManager].temporaryDirectory)
            .appendingPathComponent(targetFilenameNoExtension)
            .appendingPathExtension(finalExtension)
            .path
    }
    
    public func createTemporaryFileForOpening(downloadUrl: String?, mimeType: String?, sourceFilename: String?) throws -> String {
        let path: String = try path(for: downloadUrl)
        
        /// Ensure the original file exists before generating a path for opening or trying to copy it
        guard dependencies[singleton: .fileManager].fileExists(atPath: path) else {
            throw AttachmentError.invalidData
        }
        
        let tmpPath: String = try temporaryPathForOpening(
            downloadUrl: downloadUrl,
            mimeType: mimeType,
            sourceFilename: sourceFilename
        )
        
        /// If the file already exists (since it's deterministically generated) then no need to copy it again
        if !dependencies[singleton: .fileManager].fileExists(atPath: tmpPath) {
            try dependencies[singleton: .fileManager].copyItem(atPath: path, toPath: tmpPath)
        }
        
        return tmpPath
    }
    
    public func resetStorage() {
        try? dependencies[singleton: .fileManager].removeItem(
            atPath: sharedDataAttachmentsDirPath()
        )
    }
    
    // MARK: - ThumbnailManager
    
    private func thumbnailUrl(for url: URL, size: ImageDataManager.ThumbnailSize) throws -> URL {
        guard !url.lastPathComponent.isEmpty else { throw AttachmentError.invalidPath }
        
        /// Thumbnails are written to the caches directory, so that iOS can remove them if necessary
        return URL(fileURLWithPath: SessionFileManager.cachesDirectoryPath)
            .appendingPathComponent(url.lastPathComponent)
            .appendingPathComponent("thumbnail-\(size).jpg") // stringlint:ignore
    }

    public func existingThumbnailImage(url: URL, size: ImageDataManager.ThumbnailSize) -> UIImage? {
        guard let thumbnailUrl: URL = try? thumbnailUrl(for: url, size: size) else { return nil }
        
        return UIImage(contentsOfFile: thumbnailUrl.path)
    }
    
    public func saveThumbnail(data: Data, size: ImageDataManager.ThumbnailSize, url: URL) {
        guard let thumbnailUrl: URL = try? thumbnailUrl(for: url, size: size) else { return }
        
        try? data.write(to: thumbnailUrl)
    }
    
    // MARK: - Validity
    
    public func determineValidityAndDuration(
        contentType: String,
        downloadUrl: String?,
        sourceFilename: String?
    ) -> (isValid: Bool, duration: TimeInterval?) {
        guard let path: String = try? path(for: downloadUrl) else { return (false, nil) }
        
        let pendingAttachment: PendingAttachment = PendingAttachment(
            source: .file(URL(fileURLWithPath: path)),
            utType: UTType(sessionMimeType: contentType),
            sourceFilename: sourceFilename,
            using: dependencies
        )
        
        // Process audio attachments
        if pendingAttachment.utType.isAudio {
            return (pendingAttachment.duration > 0, pendingAttachment.duration)
        }
        
        // Process image attachments
        if pendingAttachment.utType.isImage || pendingAttachment.utType.isAnimated {
            return (pendingAttachment.isValidVisualMedia, nil)
        }
        
        // Process video attachments
        if pendingAttachment.utType.isVideo {
            return (pendingAttachment.isValidVisualMedia, pendingAttachment.duration)
        }
        
        // Any other attachment types are valid and have no duration
        return (true, nil)
    }
}

// MARK: - PendingAttachment

public struct PendingAttachment: Sendable, Equatable, Hashable {
    public let source: DataSource
    public let sourceFilename: String?
    public let metadata: Metadata?
    private let existingAttachmentId: String?
    
    public var utType: UTType { metadata?.utType ?? .invalid }
    public var fileSize: UInt64 { metadata?.fileSize ?? 0 }
    public var duration: TimeInterval {
        switch metadata {
            case .media(let mediaMetadata): return mediaMetadata.duration
            case .file, .none: return 0
        }
    }
    
    // MARK: Initialization
    
    public init(
        source: DataSource,
        utType: UTType? = nil,
        sourceFilename: String? = nil,
        using dependencies: Dependencies
    ) {
        self.source = source
        self.sourceFilename = sourceFilename
        self.metadata = PendingAttachment.metadata(
            for: source,
            utType: utType,
            sourceFilename: sourceFilename,
            using: dependencies
        )
        self.existingAttachmentId = nil
    }
    
    public init(
        attachment: Attachment,
        using dependencies: Dependencies
    ) throws {
        let filePath: String = try dependencies[singleton: .attachmentManager]
            .path(for: attachment.downloadUrl)
        let source: DataSource
        
        switch attachment.variant {
            case .standard: source = .file(URL(fileURLWithPath: filePath))
            case .voiceMessage: source = .voiceMessage(URL(fileURLWithPath: filePath))
        }
        
        self.source = source
        self.sourceFilename = attachment.sourceFilename
        self.metadata = PendingAttachment.metadata(
            for: source,
            utType: UTType(sessionMimeType: attachment.contentType),
            sourceFilename: attachment.sourceFilename,
            using: dependencies
        )
        self.existingAttachmentId = attachment.id
    }
    
    // MARK: - Internal Functions
    
    private static func metadata(
        for dataSource: DataSource,
        utType: UTType?,
        sourceFilename: String?,
        using dependencies: Dependencies
    ) -> Metadata? {
        let maybeFileSize: UInt64? = dataSource.fileSize(using: dependencies)
        
        switch (dataSource, dataSource.visualMediaSource) {
            case (.file(let url), _), (.voiceMessage(let url), _):
                guard
                    let utType: UTType = utType,
                    let fileSize: UInt64 = maybeFileSize
                else { return nil }
                
                /// If the url is actually media then try to load `MediaMetadata`, falling back to the `FileMetadata`
                guard
                    let metadata: MediaUtils.MediaMetadata = MediaUtils.MediaMetadata(
                        from: url.path,
                        utType: utType,
                        sourceFilename: sourceFilename,
                        using: dependencies
                    )
                else { return .file(FileMetadata(utType: utType, fileSize: fileSize)) }
                
                return .media(metadata)
                
            case (_, .image(_, .some(let image))):
                guard let metadata: MediaUtils.MediaMetadata = MediaUtils.MediaMetadata(image: image) else {
                    return nil
                }
                
                return .media(metadata)
                
            case (.displayPicture(let mediaSource), _), (.media(let mediaSource), _):
                guard
                    let fileSize: UInt64 = maybeFileSize,
                    let source: CGImageSource = mediaSource.createImageSource(),
                    let metadata: MediaUtils.MediaMetadata = MediaUtils.MediaMetadata(
                        source: source,
                        fileSize: fileSize
                    )
                else { return nil }
                
                return .media(metadata)
                
            case (.text, _):
                guard
                    let utType: UTType = utType,
                    let fileSize: UInt64 = maybeFileSize
                else { return nil }
                
                return .file(FileMetadata(utType: utType, fileSize: fileSize))
        }
    }
}

// MARK: - PendingAttachment.DataSource

public extension PendingAttachment {
    enum DataSource: Sendable, Equatable, Hashable {
        case displayPicture(ImageDataManager.DataSource)
        case media(ImageDataManager.DataSource)
        case file(URL)
        case voiceMessage(URL)
        case text(String)
        
        // MARK: - Convenience
        
        public static func media(_ url: URL) -> DataSource {
            return .media(.url(url))
        }
        
        public static func media(_ identifier: String, _ data: Data) -> DataSource {
            return .media(.data(identifier, data))
        }
        
        fileprivate var visualMediaSource: ImageDataManager.DataSource? {
            switch self {
                case .displayPicture(let source), .media(let source): return source
                case .file, .voiceMessage, .text: return nil
            }
        }
        
        fileprivate var url: URL? {
            switch (self, visualMediaSource) {
                case (.file(let url), _), (.voiceMessage(let url), _), (_, .url(let url)),
                    (_, .videoUrl(let url, _, _, _)), (_, .urlThumbnail(let url, _, _)):
                    return url
                    
                case (_, .none), (_, .data), (_, .image), (_, .placeholderIcon), (_, .asyncSource), (.displayPicture, _), (.media, _), (.text, _):
                    return nil
            }
        }
        
        fileprivate func fileSize(using dependencies: Dependencies) -> UInt64? {
            switch (self, visualMediaSource) {
                case (.file(let url), _), (.voiceMessage(let url), _), (_, .url(let url)):
                    return dependencies[singleton: .fileManager].fileSize(of: url.path)
                    
                case (_, .data(_, let data)): return UInt64(data.count)
                case (.text(let content), _):
                    return (content.data(using: .ascii)?.count).map { UInt64($0) }
                    
                default: return nil
            }
        }
    }
}

// MARK: - PendingAttachment.Metadata

public extension PendingAttachment {
    enum Metadata: Sendable, Equatable, Hashable {
        case media(MediaUtils.MediaMetadata)
        case file(FileMetadata)
        
        var utType: UTType {
            switch self {
                case .media(let metadata): return (metadata.utType ?? .invalid)
                case .file(let metadata): return metadata.utType
            }
        }
        
        public var fileSize: UInt64 {
            switch self {
                case .media(let metadata): return metadata.fileSize
                case .file(let metadata): return metadata.fileSize
            }
        }
        
        public var pixelSize: CGSize? {
            switch self {
                case .media(let metadata): return metadata.pixelSize
                case .file: return nil
            }
        }
    }
    
    struct FileMetadata: Sendable, Equatable, Hashable {
        public let utType: UTType
        public let fileSize: UInt64
        
        init(utType: UTType, fileSize: UInt64) {
            self.utType = utType
            self.fileSize = fileSize
        }
    }
}

// MARK: - PreparedAttachment

public struct PreparedAttachment: Sendable, Equatable, Hashable {
    public let attachment: Attachment
    public let temporaryFilePath: String
    public let pendingUploadFilePath: String
    
    public init(
        attachment: Attachment,
        temporaryFilePath: String,
        pendingUploadFilePath: String
    ) {
        self.attachment = attachment
        self.temporaryFilePath = temporaryFilePath
        self.pendingUploadFilePath = pendingUploadFilePath
    }
}

// MARK: - Transforms

public extension PendingAttachment {
    enum Transform: Sendable, Equatable, Hashable {
        case compress
        case convertToStandardFormats
        case resize(maxDimension: CGFloat)
        case stripImageMetadata
        case encrypt(legacy: Bool, domain: Crypto.AttachmentDomain)
        
        fileprivate enum Erased: Equatable {
            case compress
            case convertToStandardFormats
            case resize
            case stripImageMetadata
            case encrypt
        }
        
        fileprivate var erased: Erased {
            switch self {
                case .compress: return .compress
                case .convertToStandardFormats: return .convertToStandardFormats
                case .resize: return .resize
                case .stripImageMetadata: return .stripImageMetadata
                case .encrypt: return .encrypt
            }
        }
    }
    
    func toText() -> String? {
        /// Just to be safe ensure the file size isn't crazy large - since we have a character limit of 2,000 - 10,000 characters
        /// (which is ~40Kb) a 100Kb limit should be sufficiend
        guard (metadata?.fileSize ?? 0) < (1024 * 100) else { return nil }
        
        switch (source, source.visualMediaSource) {
            case (.text(let text), _): return text
            case (.file(let fileUrl), _): return try? String(contentsOf: fileUrl, encoding: .utf8)
            case (_, .data(_, let data)): return String(data: data, encoding: .utf8)
            case (.displayPicture, _), (.media, _), (.voiceMessage, _): return nil
        }
    }
    
    func compressAsMp4Video(using dependencies: Dependencies) async throws -> PendingAttachment {
        guard
            case .media(let mediaSource) = source,
            case .url(let url) = mediaSource,
            let exportSession: AVAssetExportSession = AVAssetExportSession(
                asset: AVAsset(url: url),
                presetName: AVAssetExportPresetMediumQuality
            )
        else { throw AttachmentError.invalidData }
        
        let exportPath: String = dependencies[singleton: .fileManager].temporaryFilePath(fileExtension: "mp4")
        let exportUrl: URL = URL(fileURLWithPath: exportPath)
        exportSession.shouldOptimizeForNetworkUse = true
        exportSession.outputFileType = AVFileType.mp4
        exportSession.metadataItemFilter = AVMetadataItemFilter.forSharing()
        exportSession.outputURL = exportUrl
        
        return await withCheckedContinuation { continuation in
            exportSession.exportAsynchronously {
                continuation.resume(
                    returning: PendingAttachment(
                        source: .media(
                            .videoUrl(
                                exportUrl,
                                .mpeg4Movie,
                                sourceFilename,
                                dependencies[singleton: .attachmentManager]
                            )
                        ),
                        utType: .mpeg4Movie,
                        sourceFilename: sourceFilename,
                        using: dependencies
                    )
                )
            }
        }
    }
    
    // MARK: - Encryption and Preparation
    
    func needsPreparationForAttachmentUpload(transformations: Set<Transform>) throws -> Bool {
        switch source {
            case .file: return try fileNeedsPreparation(transformations)
            case .voiceMessage, .displayPicture, .media: return try mediaNeedsPreparation(transformations)
            case .text: return true /// Need to write to a file in order to upload as an attachment
        }
    }
    
    private func fileNeedsPreparation(_ transformations: Set<Transform>) throws -> Bool {
        /// Check the type of `metadata` we have (as if the `file` was actually media then the `metadata` will be `media`
        /// and as such we want to go down the `mediaNeedsPreparation` path)
        switch self.metadata {
            case .none: throw AttachmentError.invalidData
            case .media: return try mediaNeedsPreparation(transformations)
            case .file: break
        }
        
        for transformation in transformations {
            switch transformation {
                case .encrypt: return true
                case .compress, .convertToStandardFormats, .resize, .stripImageMetadata:
                    continue /// None of these are supported for general files
            }
        }
        
        /// None of the requested `transformations` were needed so the file doesn't need preparation
        return false
    }
    
    private func mediaNeedsPreparation(_ transformations: Set<Transform>) throws -> Bool {
        guard case .media(let mediaMatadata) = self.metadata else {
            throw AttachmentError.invalidMediaSource
        }
        guard mediaMatadata.hasValidPixelSize else { throw AttachmentError.invalidDimensions }
        
        for transformation in transformations {
            switch transformation {
                case .encrypt: return true
                case .compress:
                    /// We don't currently want to compress animated images
                    guard mediaMatadata.frameCount == 1 else { continue }
                    
                    return true /// Otherwise if we've been told to expliclty compress then we should do so
                    
                case .convertToStandardFormats:
                    /// We don't currently want to convert animated images
                    guard mediaMatadata.frameCount == 1 else { continue }
                    
                    switch mediaMatadata.utType {
                        case .png: return true  /// Want to convert to a `WebP`
                        default: continue
                    }
                    
                case .resize(let maxDimension):
                    /// We don't currently want to resize animated images
                    guard mediaMatadata.frameCount == 1 else { continue }
                    
                    let maxImageDimension: CGFloat = max(
                        mediaMatadata.pixelSize.width,
                        mediaMatadata.pixelSize.height
                    )
                    
                    if maxImageDimension > maxDimension {
                        return true
                    }
                    continue
                    
                case .stripImageMetadata:
                    /// We don't currently strip metadata from animated images
                    guard mediaMatadata.frameCount == 1 else { continue }
                    
                    return mediaMatadata.hasUnsafeMetadata
            }
        }
        
        /// None of the requested `transformations` were needed so the file doesn't need preparation
        return false
    }
    
    func prepare(transformations: Set<Transform>, using dependencies: Dependencies) throws -> PreparedAttachment {
        /// Perform any source-specific transformations and load the attachment data into memory
        let preparedData: Data
        
        switch source {
            case .displayPicture: preparedData = try prepareImage(transformations)
            case .media where utType.isImage: preparedData = try prepareImage(transformations)
            case .media where utType.isAnimated: preparedData = try prepareImage(transformations)
            case .media where utType.isVideo: preparedData = try prepareVideo(transformations)
            case .media where utType.isAudio:  preparedData = try prepareAudio(transformations)
            case .voiceMessage: preparedData = try prepareAudio(transformations)
            case .text: preparedData = try prepareText(transformations)
            case .file, .media: preparedData = try prepareGeneral(transformations)
        }
        
        /// Generate the temporary path to use while the upload is pending
        ///
        /// **Note:** This is stored alongside other attachments rather that in the temporary directory because the
        /// `AttachmentUploadJob` can exist between launches, but the temporary directory gets cleared on every launch)
        let attachmentId: String = (existingAttachmentId ?? UUID().uuidString)
        let pendingUploadFilePath: String = try dependencies[singleton: .attachmentManager].pendingUploadPath(for: attachmentId)
        
        /// If we don't have the `encrypt` transform then we can just return the `preparedData` (which is unencrypted but should
        /// have all other `Transform` changes applied
        // FIXME: We should store attachments encrypted and decrypt them when we want to render/open them
        guard case .encrypt(let legacyEncryption, let encryptionDomain) = transformations.first(where: { $0.erased == .encrypt }) else {
            let filePath: String = try dependencies[singleton: .fileManager].write(
                dataToTemporaryFile: preparedData
            )
            
            return PreparedAttachment(
                attachment: try prepareAttachment(
                    id: attachmentId,
                    downloadUrl: pendingUploadFilePath,
                    byteCount: UInt(preparedData.count),
                    encryptionKey: nil,
                    digest: nil,
                    using: dependencies
                ),
                temporaryFilePath: filePath,
                pendingUploadFilePath: pendingUploadFilePath
            )
        }
        
        /// Encrypt the data using either the legacy or updated encryption
        typealias EncryptionData = (ciphertext: Data, encryptionKey: Data, digest: Data)
        let encryptedData: EncryptionData
        
        if legacyEncryption {
            encryptedData = try dependencies[singleton: .crypto].tryGenerate(
                .legacyEncryptAttachment(plaintext: preparedData)
            )
            
            /// May as well throw here if we know the attachment is too large to send
            guard encryptedData.ciphertext.count <= Network.maxFileSize else {
                throw AttachmentError.fileSizeTooLarge
            }
        }
        else {
            let encryptedSize: Int = try dependencies[singleton: .crypto].tryGenerate(
                .expectedEncryptedAttachmentSize(plaintext: preparedData)
            )
            
            /// May as well throw here if we know the attachment is too large to send
            guard UInt(encryptedSize) <= Network.maxFileSize else {
                throw AttachmentError.fileSizeTooLarge
            }
            
            let result = try dependencies[singleton: .crypto].tryGenerate(
                .encryptAttachment(plaintext: preparedData, domain: encryptionDomain)
            )
            
            encryptedData = (result.ciphertext, result.encryptionKey, Data())
        }
        
        let filePath: String = try dependencies[singleton: .fileManager]
            .write(dataToTemporaryFile: encryptedData.ciphertext)
        
        return PreparedAttachment(
            attachment: try prepareAttachment(
                id: attachmentId,
                downloadUrl: pendingUploadFilePath,
                byteCount: UInt(preparedData.count),
                encryptionKey: encryptedData.encryptionKey,
                digest: encryptedData.digest,
                using: dependencies
            ),
            temporaryFilePath: filePath,
            pendingUploadFilePath: pendingUploadFilePath
        )
    }
    
    private func prepareImage(_ transformations: Set<Transform>) throws -> Data {
        guard
            let targetSource: ImageDataManager.DataSource = visualMediaSource,
            case .media(let mediaMatadata) = self.metadata
        else { throw AttachmentError.invalidMediaSource }
        
        guard mediaMatadata.hasValidPixelSize else {
            Log.error(.attachmentManager, "Source has invalid image dimensions.")
            throw AttachmentError.invalidDimensions
        }
        
        /// If it's animated then we don't want to do any processing (to performance intensive at this stage, and won't have as big of
        /// an impact due to a smaller number of users actually using them)
        guard mediaMatadata.frameCount == 1 else {
            switch targetSource {
                case .url(let url): return try Data(contentsOf: url, options: [])
                case .data(_, let data): return data
                
                /// None of the other source options support animated images so just fail
                default: throw AttachmentError.invalidData
            }
        }
        
        /// If we can't load the data into a `UIImage` then we can't process it
        var image: UIImage
        var needsReencoding: Bool = (
            transformations.contains(.compress) ||
            transformations.contains(.convertToStandardFormats)
        )
        let originalImageData: Data?
        
        switch targetSource {
            case .image(_, let directImage):
                image = try directImage ?? { throw AttachmentError.invalidData }()
                needsReencoding = true  /// In-memory image always needs encoding
                originalImageData = nil
                
            case .url(let url):
                guard
                    let imageData: Data = try? Data(contentsOf: url, options: []),
                    let loadedImage = UIImage(data: imageData)
                else { throw AttachmentError.invalidImageData }
                
                image = loadedImage
                originalImageData = imageData
                
            case .data(_, let data):
                guard let loadedImage = UIImage(data: data) else {
                    throw AttachmentError.invalidImageData
                }
                
                image = loadedImage
                originalImageData = data
                
            default: throw AttachmentError.invalidMediaSource
        }
        
        /// If we have the `resize` and the resolution is too large then we need to scale it down
        if case .resize(let targetSize) = transformations.first(where: { $0.erased == .resize }) {
            let maxImageDimension: CGFloat = max(mediaMatadata.pixelSize.width, mediaMatadata.pixelSize.height)
            
            if maxImageDimension > targetSize {
                Log.debug(.attachmentManager, "Resizing image to fit in max allows dimension.")
                image = image.resized(toFillPixelSize: CGSize(width: targetSize, height: targetSize))
                needsReencoding = true  /// We've resized the image so need to re-encode it
            }
        }
        
        /// If we don't need to re-encode then just check if we want to strip the metadata and return either the original or stripped
        /// version of the data
        if !needsReencoding {
            guard let originalData: Data = originalImageData else { throw AttachmentError.invalidData }
            
            /// If we don't want to strip the metadata then just return the original data
            guard transformations.contains(.stripImageMetadata) else {
                return originalData
            }
            
            /// Otherwise clear the metadata and return the updated data
            let options: CFDictionary = [
                kCGImageSourceShouldCache: false,
                kCGImageSourceShouldCacheImmediately: false
            ] as CFDictionary
            let outputData: NSMutableData = NSMutableData()
            
            guard
                let source: CGImageSource = CGImageSourceCreateWithData(originalData as CFData, options),
                let sourceType: String = CGImageSourceGetType(source) as? String,
                let cgImage: CGImage = CGImageSourceCreateImageAtIndex(source, 0, nil),
                let destination = CGImageDestinationCreateWithData(outputData as CFMutableData, sourceType as CFString, 1, nil)
            else { throw AttachmentError.invalidData }
            
            CGImageDestinationAddImage(destination, cgImage, nil)
            
            guard CGImageDestinationFinalize(destination) else {
                throw AttachmentError.couldNotResizeImage
            }
            
            return outputData as Data
        }
        
        /// Otherwise, perform the desired re-encoding, images with alpha should be converted to lossless `WebP`
        if mediaMatadata.hasAlpha == true {
            let maybeWebPData: Data? = SDImageWebPCoder.shared.encodedData(
                with: image,
                format: .webP,
                options: [
                    .encodeFirstFrameOnly: true,
                    .encodeWebPLossless: true,
                    .encodeCompressionQuality: 0.25
                ]
            )
            
            guard let webPData: Data = maybeWebPData else {
                throw AttachmentError.couldNotResizeImage
            }
            
            return webPData
        }
        
        /// And opaque images should be converted to `JPEG` with the appropriate quality
        let quality: CGFloat = (transformations.contains(.compress) ? 0.75 : 0.95)
        
        guard let data: Data = image.jpegData(compressionQuality: quality) else {
            throw AttachmentError.couldNotResizeImage
        }
        
        return data
    }
    
    private func prepareVideo(_ transformations: Set<Transform>) throws -> Data {
        guard
            let targetSource: ImageDataManager.DataSource = visualMediaSource,
            case .media(let mediaMatadata) = self.metadata
        else { throw AttachmentError.invalidMediaSource }
        
        guard mediaMatadata.hasValidPixelSize else {
            Log.error(.attachmentManager, "Source has invalid image dimensions.")
            throw AttachmentError.invalidDimensions
        }
        guard mediaMatadata.hasValidDuration else {
            Log.error(.attachmentManager, "Source has invalid duration.")
            throw AttachmentError.invalidDuration
        }
        
        switch targetSource {
            case .data(_, let data): return data
            case .url(let url), .videoUrl(let url, _, _, _):
                return try Data(contentsOf: url, options: [])
            
            default: throw AttachmentError.invalidMediaSource
        }
    }
    
    private func prepareAudio(_ transformations: Set<Transform>) throws -> Data {
        guard case .media(let mediaMatadata) = self.metadata else {
            throw AttachmentError.invalidMediaSource
        }
        
        guard mediaMatadata.hasValidDuration else {
            Log.error(.attachmentManager, "Source has invalid duration.")
            throw AttachmentError.invalidDuration
        }
        
        switch source {
            case .voiceMessage(let url): return try Data(contentsOf: url, options: [])
            case .media(let mediaSource) where utType.isAudio:
                switch mediaSource {
                    case .url(let url): return try Data(contentsOf: url, options: [])
                    case .data(_, let data): return data
                    default: throw AttachmentError.invalidMediaSource
                }
                
            default: throw AttachmentError.invalidMediaSource
        }
    }
    
    private func prepareText(_ transformations: Set<Transform>) throws -> Data {
        guard
            case .text(let text) = source,
            let data: Data = text.data(using: .ascii)
        else { throw AttachmentError.invalidData }
        
        return data
    }
    
    private func prepareGeneral(_ transformations: Set<Transform>) throws -> Data {
        switch source {
            case .file(let url): return try Data(contentsOf: url, options: [])
            case .media(let mediaSource):
                switch mediaSource {
                    case .url(let url): return try Data(contentsOf: url, options: [])
                    case .data(_, let data): return data
                    default: throw AttachmentError.invalidData
                }
                
            default: throw AttachmentError.invalidData
        }
    }
    
    private func prepareAttachment(
        id: String,
        downloadUrl: String,
        byteCount: UInt,
        encryptionKey: Data?,
        digest: Data?,
        using dependencies: Dependencies
    ) throws -> Attachment {
        let contentType: String = {
            guard
                let fileExtension: String = sourceFilename.map({ URL(fileURLWithPath: $0) })?.pathExtension,
                !fileExtension.isEmpty,
                let fileExtensionMimeType: String = UTType(sessionFileExtension: fileExtension)?.preferredMIMEType
            else { return (utType.preferredMIMEType ?? UTType.mimeTypeDefault) }
            
            /// UTTypes are an imperfect means of representing file type; file extensions are also imperfect but far more
            /// reliable and comprehensive so we always prefer to try to deduce MIME type from the file extension
            return fileExtensionMimeType
        }()
        let imageSize: CGSize? = {
            switch metadata {
                case .media(let mediaMetadata): return mediaMetadata.unrotatedSize
                case .file, .none: return nil
            }
        }()
        
        return Attachment(
            id: id,
            serverId: nil,
            variant: {
                switch source {
                    case .voiceMessage: return .voiceMessage
                    default: return .standard
                }
            }(),
            state: .uploading,
            contentType: contentType,
            byteCount: byteCount,
            creationTimestamp: nil,
            sourceFilename: sourceFilename,
            downloadUrl: downloadUrl,
            width: imageSize.map { UInt(floor($0.width)) },
            height: imageSize.map { UInt(floor($0.height)) },
            duration: duration,
            isVisualMedia: utType.isVisualMedia,
            isValid: isValidVisualMedia,
            encryptionKey: encryptionKey,
            digest: digest
        )
    }
}

// MARK: - Convenience

public extension PendingAttachment {
    var visualMediaSource: ImageDataManager.DataSource? { source.visualMediaSource }
    
    /// Returns the file extension for this attachment or nil if no file extension can be identified
    var fileExtension: String? {
        guard
            let fileExtension: String = sourceFilename.map({ URL(fileURLWithPath: $0) })?.pathExtension,
            !fileExtension.isEmpty
        else { return utType.sessionFileExtension(sourceFilename: sourceFilename) }
        
        return fileExtension.filteredFilename
    }
    
    var isValidVisualMedia: Bool {
        guard utType.isImage || utType.isAnimated || utType.isVideo else { return false }
        guard case .media(let mediaMetadata) = metadata else { return false }
        
        return (
            mediaMetadata.hasValidPixelSize &&
            mediaMetadata.hasValidFileSize &&
            mediaMetadata.hasValidDuration
        )
    }
}
