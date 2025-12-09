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
    private let cache: StringCache = StringCache(
        totalCostLimit: 5 * 1024 * 1024 /// Max 5MB of url to hash data (approx. 20,000 records)
    )
    
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
        
        /// If the provided url is a placeholder url or located in the temporary directory then it _is_ a valid path, so we should just return
        /// it directly instead of generating a hash
        guard
            !isPlaceholderUploadUrl(urlString) &&
            !dependencies[singleton: .fileManager].isLocatedInTemporaryDirectory(urlString)
        else { return urlString }
        
        /// Otherwise we need to generate the deterministic file path based on the url provided
        ///
        /// **Note:** Now that download urls could contain fragments (or query params I guess) that could result in inconsistent paths
        /// with old attachments so just to be safe we should strip them before generating the `urlHash`
        let urlNoQueryOrFragment: String = urlString
            .components(separatedBy: "?")[0]    // stringlint:disable
            .components(separatedBy: "#")[0]    // stringlint:disable
        let urlHash = try {
            guard let cachedHash: String = cache.object(forKey: urlNoQueryOrFragment) else {
                return try dependencies[singleton: .crypto]
                    .tryGenerate(.hash(message: Array(urlNoQueryOrFragment.utf8)))
                    .toHexString()
            }
            
            return cachedHash
        }()
        
        return URL(fileURLWithPath: sharedDataAttachmentsDirPath())
            .appendingPathComponent(urlHash)
            .path
    }
    
    public func pendingUploadPath(for id: String) -> String {
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
    
    public func temporaryPathForOpening(
        originalPath: String,
        mimeType: String?,
        sourceFilename: String?,
        allowInvalidType: Bool
    ) throws -> String {
        /// Since `mimeType` and/or `sourceFilename` can be null we need to try to resolve them both to values
        let finalExtension: String
        let targetFilenameNoExtension: String
        
        do {
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
                    targetFilenameNoExtension = {
                        guard let sourceFilename: String = sourceFilename else {
                            return URL(fileURLWithPath: originalPath).lastPathComponent
                        }
                        
                        return (sourceFilename.hasSuffix(".\(fileExtension)") ? // stringlint:ignore
                            String(sourceFilename.prefix(sourceFilename.count - (1 + fileExtension.count))) :
                            sourceFilename
                        )
                    }()
            }
        } catch {
            /// If an error was thrown it was because we couldn't get a valid file extension, in which case only continue if we want to
            /// allow invalid types
            guard allowInvalidType else { throw error }
            
            return URL(fileURLWithPath: dependencies[singleton: .fileManager].temporaryDirectory)
                .appendingPathComponent(
                    URL(fileURLWithPath: originalPath)
                        .lastPathComponent
                        .replacingWhitespacesWithUnderscores
                )
                .path
        }

        return URL(fileURLWithPath: dependencies[singleton: .fileManager].temporaryDirectory)
            .appendingPathComponent(targetFilenameNoExtension.replacingWhitespacesWithUnderscores)
            .appendingPathExtension(finalExtension)
            .path
    }
    
    public func createTemporaryFileForOpening(
        downloadUrl: String?,
        mimeType: String?,
        sourceFilename: String?
    ) throws -> String {
        let path: String = try path(for: downloadUrl)
        
        /// Ensure the original file exists before generating a path for opening or trying to copy it
        guard dependencies[singleton: .fileManager].fileExists(atPath: path) else {
            throw AttachmentError.invalidData
        }
        
        let tmpPath: String = try temporaryPathForOpening(
            originalPath: path,
            mimeType: mimeType,
            sourceFilename: sourceFilename,
            allowInvalidType: false
        )
        
        /// If the file already exists (since it's deterministically generated) then no need to copy it again
        if !dependencies[singleton: .fileManager].fileExists(atPath: tmpPath) {
            try dependencies[singleton: .fileManager].copyItem(atPath: path, toPath: tmpPath)
        }
        
        return tmpPath
    }
    
    public func createTemporaryFileForOpening(filePath: String) throws -> String {
        /// Ensure the original file exists before generating a path for opening or trying to copy it
        guard dependencies[singleton: .fileManager].fileExists(atPath: filePath) else {
            throw AttachmentError.invalidData
        }
        
        let originalUrl: URL = URL(fileURLWithPath: filePath)
        let fileName: String = originalUrl.deletingPathExtension().lastPathComponent
        let fileExtension: String = originalUrl.pathExtension
        
        /// Removes white spaces on the filename and replaces it with _
        let filenameNoExtension = fileName
            .replacingWhitespacesWithUnderscores
        
        let tmpPath: String = URL(fileURLWithPath: dependencies[singleton: .fileManager].temporaryDirectory)
            .appendingPathComponent(filenameNoExtension)
            .appendingPathExtension(fileExtension)
            .path
        
        /// If the file already exists then we should remove it as it may not be the same file
        if dependencies[singleton: .fileManager].fileExists(atPath: tmpPath) {
            try dependencies[singleton: .fileManager].removeItem(atPath: tmpPath)
        }
        
        try dependencies[singleton: .fileManager].copyItem(atPath: filePath, toPath: tmpPath)
        
        return tmpPath
    }
    
    public func resetStorage() {
        try? dependencies[singleton: .fileManager].removeItem(
            atPath: sharedDataAttachmentsDirPath()
        )
    }
    
    // MARK: - ThumbnailManager
    
    private func thumbnailPath(for name: String, size: ImageDataManager.ThumbnailSize) throws -> String {
        guard !name.isEmpty else { throw AttachmentError.invalidPath }
        
        /// Thumbnails are written to the caches directory, so that iOS can remove them if necessary
        let thumbnailsUrl: URL = URL(fileURLWithPath: SessionFileManager.cachesDirectoryPath)
            .appendingPathComponent(name)
        try? dependencies[singleton: .fileManager].ensureDirectoryExists(at: thumbnailsUrl.path)
        
        return thumbnailsUrl
            .appendingPathComponent("thumbnail-\(size)") // stringlint:ignore
            .path
    }

    public func existingThumbnail(name: String, size: ImageDataManager.ThumbnailSize) -> ImageDataManager.DataSource? {
        guard
            let thumbnailPath: String = try? thumbnailPath(for: name, size: size),
            dependencies[singleton: .fileManager].fileExists(atPath: thumbnailPath)
        else { return nil }
        
        return .url(URL(fileURLWithPath: thumbnailPath))
    }
    
    public func saveThumbnail(
        name: String,
        frames: [UIImage],
        durations: [TimeInterval],
        hasAlpha: Bool?,
        size: ImageDataManager.ThumbnailSize
    ) {
        guard
            let thumbnailPath: String = try? thumbnailPath(for: name, size: size), (
                frames.count == durations.count ||
                frames.count == 1
            )
        else { return }
        
        let finalFrames: [CGImage] = frames.compactMap { $0.cgImage }
        
        /// Writing a `WebP` is much slower than writing a `GIF` (up to 3-4 times slower) but in many cases the resulting `WebP`
        /// file would end up smaller (about 3 times smaller) - since we are generating a thumbnail the output _generally_ shouldn't be
        /// that large (and the OS can purge files these thumbnails when it wants) so we default to `GIF` thumbnails here due to encoding
        /// speed unless the source has alpha (in which case we need to use `WebP` as `GIF` doesn't have proper alpha support). By
        /// spending less time encoding `GIF` would result in less battery drain that encoding to `WebP` would
        ///
        /// **Note:** The `WebP` encoding runs much slower on debug builds compared to release builds (can be 10 times slower)
        if hasAlpha == true {
            try? PendingAttachment.writeFramesAsWebPToFile(
                frames: finalFrames,
                metadata: MediaUtils.MediaMetadata(
                    pixelSize: (frames.first?.size ?? .zero),
                    frameDurations: (frames.count == 1 ? [0] : durations),
                    hasUnsafeMetadata: false
                ),
                encodeWebPLossless: false,
                encodeCompressionQuality: PendingAttachment.ConversionFormat.defaultWebPCompressionQuality,
                filePath: thumbnailPath,
                using: dependencies
            )
        }
        else {
            try? PendingAttachment.writeFramesAsGifToFile(
                frames: finalFrames,
                metadata: MediaUtils.MediaMetadata(
                    pixelSize: (frames.first?.size ?? .zero),
                    frameDurations: (frames.count == 1 ? [0] : durations),
                    hasUnsafeMetadata: false
                ),
                compressionQuality: PendingAttachment.ConversionFormat.defaultGifCompressionQuality,
                filePath: thumbnailPath
            )
        }
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
        
        // Video and Audio attachments should have durations
        if pendingAttachment.utType.isVideo || pendingAttachment.utType.isAudio {
            return (pendingAttachment.isValid, pendingAttachment.duration)
        }
        
        // Anything else should just be based on standard validity
        return (pendingAttachment.isValid, nil)
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
        self.metadata = PendingAttachment.metadata(
            for: source,
            utType: utType,
            sourceFilename: sourceFilename,
            using: dependencies
        )
        self.sourceFilename = sourceFilename
        self.existingAttachmentId = nil
        
        /// To avoid confusion (and reduce bugs related to checking the `source` type) if we are given a `file` source that is
        /// actually media, then convert it to a `media` source
        switch (source, metadata) {
            case (.file(let url), .media(let mediaMetadata)):
                if let utType: UTType = mediaMetadata.utType, utType.isVideo {
                    self.source = .media(.videoUrl(url, utType, sourceFilename, dependencies[singleton: .attachmentManager]))
                }
                else {
                    self.source = .media(.url(url))
                }
                
            default: self.source = source
        }
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
        
        switch dataSource {
            case .file(let url), .voiceMessage(let url):
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
                
            case .media(.image(_, .some(let image))):
                guard let metadata: MediaUtils.MediaMetadata = MediaUtils.MediaMetadata(image: image) else {
                    return nil
                }
                
                return .media(metadata)
                
            case .media(.videoUrl(let url, _, _, _)):
                guard
                    let metadata: MediaUtils.MediaMetadata = MediaUtils.MediaMetadata(
                        from: url.path,
                        utType: utType,
                        sourceFilename: sourceFilename,
                        using: dependencies
                    )
                else { return nil }
                
                return .media(metadata)
                
            case .media(let mediaSource):
                guard
                    let fileSize: UInt64 = maybeFileSize,
                    let source: CGImageSource = mediaSource.createImageSource(),
                    let metadata: MediaUtils.MediaMetadata = MediaUtils.MediaMetadata(
                        source: source,
                        fileSize: fileSize
                    )
                else { return nil }
                
                return .media(metadata)
                
            case .text:
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
        case media(ImageDataManager.DataSource)
        case file(URL)
        case voiceMessage(URL)
        case text(String)
        
        // MARK: - Convenience
        
        public static func media(_ url: URL) -> DataSource {
            return .media(.url(url))
        }
        
        fileprivate var url: URL? {
            switch self {
                case .file(let url), .voiceMessage(let url), .media(.url(let url)),
                        .media(.videoUrl(let url, _, _, _)), .media(.urlThumbnail(let url, _, _)):
                    return url
                    
                case .text, .media(.data), .media(.image), .media(.placeholderIcon), .media(.asyncSource), .media(.icon):
                    return nil
            }
        }
        
        fileprivate func fileSize(using dependencies: Dependencies) -> UInt64? {
            switch self {
                case .file(let url), .voiceMessage(let url), .media(.url(let url)),
                    .media(.videoUrl(let url, _, _, _)):
                    return dependencies[singleton: .fileManager].fileSize(of: url.path)
                    
                case .media(.data(_, let data)): return UInt64(data.count)
                case .text(let content):
                    return (content.data(using: .ascii)?.count).map { UInt64($0) }
                    
                case .media(.image), .media(.placeholderIcon), .media(.asyncSource),
                    .media(.urlThumbnail), .media(.icon):
                    return nil
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
    public let filePath: String
    
    public init(
        attachment: Attachment,
        filePath: String
    ) {
        self.attachment = attachment
        self.filePath = filePath
    }
}

// MARK: - Operation

public extension PendingAttachment {
    enum Operation: Sendable, Equatable, Hashable {
        case convert(to: ConversionFormat)
        case stripImageMetadata
        case encrypt(domain: Crypto.AttachmentDomain)
        
        fileprivate enum Erased: Equatable {
            case convert
            case stripImageMetadata
            case encrypt
        }
        
        fileprivate var erased: Erased {
            switch self {
                case .convert: return .convert
                case .stripImageMetadata: return .stripImageMetadata
                case .encrypt: return .encrypt
            }
        }
    }
    
    enum ConversionFormat: Sendable, Equatable, Hashable {
        fileprivate static let defaultWebPCompressionQuality: CGFloat = 0.8
        fileprivate static let defaultWebPCompressionEffort: CGFloat = 0.25
        fileprivate static let defaultGifCompressionQuality: CGFloat = 0.8
        fileprivate static let defaultResizeMode: UIImage.ResizeMode = .fit
        
        case current
        case mp4
        case png(maxDimension: CGFloat?, cropRect: CGRect?, resizeMode: UIImage.ResizeMode)
        
        /// A `compressionQuality` value of `0` gives the smallest size and `1` the largest
        case webPLossy(maxDimension: CGFloat?, cropRect: CGRect?, resizeMode: UIImage.ResizeMode, compressionQuality: CGFloat)
        
        /// A `compressionEffort` value of `0` is the fastest (but gives larger files) and a value of `1` is the slowest but compresses the most
        case webPLossless(maxDimension: CGFloat?, cropRect: CGRect?, resizeMode: UIImage.ResizeMode, compressionEffort: CGFloat)
        
        case gif(maxDimension: CGFloat?, cropRect: CGRect?, resizeMode: UIImage.ResizeMode, compressionQuality: CGFloat)
        
        public static var png: ConversionFormat {
            .png(
                maxDimension: nil,
                cropRect: nil,
                resizeMode: defaultResizeMode
            )
        }
        public static func png(
            maxDimension: CGFloat? = nil,
            cropRect: CGRect? = nil,
            resizeMode: UIImage.ResizeMode? = nil
        ) -> ConversionFormat {
            return .png(
                maxDimension: maxDimension,
                cropRect: cropRect,
                resizeMode: (resizeMode ?? defaultResizeMode)
            )
        }

        public static var webPLossy: ConversionFormat {
            .webPLossy(
                maxDimension: nil,
                cropRect: nil,
                resizeMode: defaultResizeMode,
                compressionQuality: defaultWebPCompressionQuality
            )
        }
        public static func webPLossy(
            maxDimension: CGFloat? = nil,
            cropRect: CGRect? = nil,
            resizeMode: UIImage.ResizeMode? = nil
        ) -> ConversionFormat {
            return .webPLossy(
                maxDimension: maxDimension,
                cropRect: cropRect,
                resizeMode: (resizeMode ?? defaultResizeMode),
                compressionQuality: defaultWebPCompressionQuality
            )
        }
        
        public static var webPLossless: ConversionFormat {
            .webPLossless(
                maxDimension: nil,
                cropRect: nil,
                resizeMode: defaultResizeMode,
                compressionEffort: defaultWebPCompressionEffort
            )
        }
        public static func webPLossless(
            maxDimension: CGFloat? = nil,
            cropRect: CGRect? = nil,
            resizeMode: UIImage.ResizeMode? = nil
        ) -> ConversionFormat {
            return .webPLossless(
                maxDimension: maxDimension,
                cropRect: cropRect,
                resizeMode: (resizeMode ?? defaultResizeMode),
                compressionEffort: defaultWebPCompressionEffort
            )
        }
        
        public static var gif: ConversionFormat {
            .gif(
                maxDimension: nil,
                cropRect: nil,
                resizeMode: defaultResizeMode,
                compressionQuality: defaultGifCompressionQuality
            )
        }
        public static func gif(
            maxDimension: CGFloat? = nil,
            cropRect: CGRect? = nil,
            resizeMode: UIImage.ResizeMode? = nil
        ) -> ConversionFormat {
            return .gif(
                maxDimension: maxDimension,
                cropRect: cropRect,
                resizeMode: (resizeMode ?? defaultResizeMode),
                compressionQuality: defaultGifCompressionQuality
            )
        }
        
        var webPIsLossless: Bool {
            switch self {
                case .webPLossless: return true
                default: return false
            }
        }
        
        func utType(metadata: MediaUtils.MediaMetadata) -> UTType {
            switch self {
                case .current: return (metadata.utType ?? .invalid)
                case .mp4: return .mpeg4Movie
                case .png: return .png
                case .webPLossy, .webPLossless: return .webP
                case .gif: return .gif
            }
        }
    }
    
    // MARK: - Encryption and Preparation
    
    /// Checks whether the attachment would need preparation based on the provided `operations`
    ///
    /// **Note:** Any `convert` checks behave as an `OR`
    func needsPreparation(operations: Set<Operation>) -> Bool {
        switch (source, metadata) {
            case (_, .media(let mediaMetadata)):
                return mediaNeedsPreparation(operations, metadata: mediaMetadata)
            
            case (.file, _): return fileNeedsPreparation(operations)
            case (.text, _): return true /// Need to write to a file in order to upload as an attachment
            
            /// These cases are invalid so if they are called then just return `true` so the `prepare` function gets called (which
            /// will then throw when going down an invalid path)
            case (.voiceMessage, _), (.media, _): return true
        }
    }
    
    private func fileNeedsPreparation(_ operations: Set<Operation>) -> Bool {
        /// Check the type of `metadata` we have (as if the `file` was actually media then the `metadata` will be `media`
        /// and as such we want to go down the `mediaNeedsPreparation` path)
        switch self.metadata {
            case .file, .none: break
            case .media(let mediaMetadata):
                return mediaNeedsPreparation(operations, metadata: mediaMetadata)
        }
        
        for operation in operations {
            switch operation {
                case .encrypt: return true
                case .convert, .stripImageMetadata: continue /// None of these are supported for general files
            }
        }
        
        /// None of the requested `operations` were needed so the file doesn't need preparation
        return false
    }
    
    private func mediaNeedsPreparation(
        _ operations: Set<Operation>,
        metadata: MediaUtils.MediaMetadata
    ) -> Bool {
        /// If the media does not have a valid pixel size then just return `true`, this will result in one of the `prepare` functions being
        /// called which will throw due to the invalid size
        guard metadata.hasValidPixelSize else { return true }
        
        let erasedOperations: Set<Operation.Erased> = Set(operations.map { $0.erased })
        
        /// Encryption always needs to happen
        guard !erasedOperations.contains(.encrypt) else { return true }
        
        /// Check if we have unsafe metadata to strip (we don't currently strip metadata from animated images)
        if
            erasedOperations.contains(.stripImageMetadata) &&
            metadata.frameCount == 1 &&
            metadata.hasUnsafeMetadata
        {
            return true
        }
        
        /// Otherwise we need to check the `convert` operations provided (these should behave as an `OR` to allow us to support
        /// multiple possible "allowed" formats
        typealias FormatRequirements = (formats: Set<UTType>, maxDimension: CGFloat?, cropRect: CGRect?)
        let fullRect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        let formatRequirements: FormatRequirements = operations
            .filter { $0.erased == .convert }
            .reduce(FormatRequirements([], nil, nil)) { result, next in
                guard case .convert(let format) = next else { return result }
                
                switch format {
                    case .current, .mp4:
                        return (
                            result.formats.inserting(format.utType(metadata: metadata)),
                            result.maxDimension,
                            result.cropRect
                        )
                        
                    case .png(let maxDimension, let cropRect, _),
                        .webPLossy(let maxDimension, let cropRect, _, _),
                        .webPLossless(let maxDimension, let cropRect, _, _),
                        .gif(let maxDimension, let cropRect, _, _):
                        let finalMax: CGFloat?
                        let finalCrop: CGRect?
                        let validCurrentCrop: CGRect? = (result.cropRect != nil && result.cropRect != fullRect ?
                            result.cropRect :
                            nil
                        )
                        let validNextCrop: CGRect? = (cropRect != nil && cropRect != fullRect ?
                            cropRect :
                            nil
                        )
                        
                        switch (result.maxDimension, maxDimension) {
                            case (.some(let current), .some(let nextMax)): finalMax = min(current, nextMax)
                            case (.some(let current), .none): finalMax = current
                            case (.none, .some(let nextMax)): finalMax = nextMax
                            case (.none, .none): finalMax = nil
                        }
                        
                        switch (validCurrentCrop, validNextCrop) {
                            case (.some(let current), .some(let nextCrop)):
                                /// Smallest area wins
                                let currentArea: CGFloat = (current.width * current.height)
                                let nextArea: CGFloat = (nextCrop.width * nextCrop.height)
                                finalCrop = (currentArea < nextArea ? current : nextCrop)
                            
                            case (.some(let current), .none): finalCrop = current
                            case (.none, .some(let nextCrop)): finalCrop = nextCrop
                            case (.none, .none): finalCrop = nil
                        }
                        
                        return (
                            result.formats.inserting(format.utType(metadata: metadata)),
                            finalMax,
                            finalCrop
                        )
                }
            }
        
        /// If the format doesn't match one of the desired formats then convert
        guard formatRequirements.formats.contains(metadata.utType ?? .invalid) else { return true }
        
        /// If the source is too large then we need to scale
        let maxImageDimension: CGFloat = max(
            metadata.pixelSize.width,
            metadata.pixelSize.height
        )
        
        if let maxDimension: CGFloat = formatRequirements.maxDimension, maxImageDimension > maxDimension {
            return true
        }
        
        /// If we want to crop
        if let cropRect: CGRect = formatRequirements.cropRect, cropRect != fullRect {
            return true
        }
        
        /// None of the requested `operations` were needed so the file doesn't need preparation
        return false
    }
    
    func ensureExpectedEncryptedSize(
        domain: Crypto.AttachmentDomain,
        maxFileSize: UInt,
        using dependencies: Dependencies
    ) throws {
        let encryptedSize: Int
        
        if dependencies[feature: .deterministicAttachmentEncryption] {
            encryptedSize = try dependencies[singleton: .crypto].tryGenerate(
                .expectedEncryptedAttachmentSize(plaintextSize: Int(fileSize))
            )
        }
        else {
            switch domain {
                case .attachment:
                    encryptedSize = try dependencies[singleton: .crypto].tryGenerate(
                        .legacyExpectedEncryptedAttachmentSize(plaintextSize: Int(fileSize))
                    )
                    
                case .profilePicture:
                    encryptedSize = try dependencies[singleton: .crypto].tryGenerate(
                        .legacyEncryptedDisplayPictureSize(plaintextSize: Int(fileSize))
                    )
            }
        }
        
        /// May as well throw here if we know the attachment is too large to send
        guard UInt(encryptedSize) <= maxFileSize else {
            throw AttachmentError.fileSizeTooLarge
        }
    }
    
    func prepare(
        operations: Set<Operation>,
        storeAtPendingAttachmentUploadPath: Bool = false,
        using dependencies: Dependencies
    ) async throws -> PreparedAttachment {
        /// Generate the temporary path to use for the attachment data
        ///
        /// **Note:** If `storeAtPendingAttachmentUploadPath` is `true` then the file is stored alongside other attachments
        /// rather than in the temporary directory because the `AttachmentUploadJob` can exist between launches, but the temporary
        /// directory gets cleared on every launch)
        let attachmentId: String = (existingAttachmentId ?? UUID().uuidString)
        let filePath: String = (storeAtPendingAttachmentUploadPath ?
            dependencies[singleton: .attachmentManager].pendingUploadPath(for: attachmentId) :
            dependencies[singleton: .fileManager].temporaryFilePath()
        )
        
        /// Perform any source-specific operations and load the attachment data into memory
        switch source {
            case .media where (utType.isImage || utType.isAnimated):
                try await prepareImage(operations, filePath: filePath, using: dependencies)
                
            case .media where utType.isVideo:
                try await prepareVideo(operations, filePath: filePath, using: dependencies)
                
            case .media where utType.isAudio:
                try await prepareAudio(operations, filePath: filePath, using: dependencies)
                
            case .voiceMessage:
                try await prepareAudio(operations, filePath: filePath, using: dependencies)
                
            case .text:
                try await prepareText(operations, filePath: filePath, using: dependencies)
                
            case .file, .media:
                try await prepareGeneral(operations, filePath: filePath, using: dependencies)
        }
        
        /// Get the size of the prepared data
        let preparedFileSize: UInt64? = dependencies[singleton: .fileManager].fileSize(of: filePath)
        
        /// If we don't have the `encrypt` transform then we can just return the `preparedData` (which is unencrypted but should
        /// have all other `Operation` changes applied
        // FIXME: We should store attachments encrypted and decrypt them when we want to render/open them
        guard case .encrypt(let encryptionDomain) = operations.first(where: { $0.erased == .encrypt }) else {
            return PreparedAttachment(
                attachment: try prepareAttachment(
                    id: attachmentId,
                    downloadUrl: filePath,
                    byteCount: UInt(preparedFileSize ?? 0),
                    encryptionKey: nil,
                    digest: nil,
                    using: dependencies
                ),
                filePath: filePath
            )
        }
        
        /// May as well throw here if we know the attachment is too large to send
        try ensureExpectedEncryptedSize(
            domain: encryptionDomain,
            maxFileSize: Network.maxFileSize,
            using: dependencies
        )
        
        /// Encrypt the data using either the legacy or updated encryption
        typealias EncryptionData = (ciphertext: Data, encryptionKey: Data, digest: Data)
        let (encryptedData, finalByteCount): (EncryptionData, UInt) = try autoreleasepool {
            do {
                let result: EncryptionData
                let finalByteCount: UInt
                let plaintext: Data = try dependencies[singleton: .fileManager]
                    .contents(atPath: filePath) ?? { throw AttachmentError.invalidData }()
                
                if dependencies[feature: .deterministicAttachmentEncryption] {
                    let encryptionResult = try dependencies[singleton: .crypto].tryGenerate(
                        .encryptAttachment(plaintext: plaintext, domain: encryptionDomain)
                    )
                    
                    /// Ideally we would set this to the `ciphertext` size so that the "download file" UI is accurate but then we'd
                    /// need to update it after the download to be the `plaintext` so the "message info" UI was accurate - this
                    /// also (currently) causes issues on Desktop so for the time being just stick with the `plaintext` size
                    finalByteCount = UInt(preparedFileSize ?? 0)
                    result = (encryptionResult.ciphertext, encryptionResult.encryptionKey, Data())
                }
                else {
                    switch encryptionDomain {
                        case .attachment:
                            result = try dependencies[singleton: .crypto].tryGenerate(
                                .legacyEncryptedAttachment(plaintext: plaintext)
                            )
                            
                            /// For legacy attachments we need to set `byteCount` to the size of the data prior to encryption in
                            /// order to be able to strip the padding correctly
                            finalByteCount = UInt(preparedFileSize ?? 0)
                            
                        case .profilePicture:
                            let encryptionKey: Data = try dependencies[singleton: .crypto]
                                .tryGenerate(.randomBytes(DisplayPictureManager.encryptionKeySize))
                            let ciphertext: Data = try dependencies[singleton: .crypto].tryGenerate(
                                .legacyEncryptedDisplayPicture(data: plaintext, key: encryptionKey)
                            )
                            
                            /// Ideally we would set this to the `ciphertext` size so that the "download file" UI is accurate but then we'd
                            /// need to update it after the download to be the `plaintext` so the "message info" UI was accurate - this
                            /// also (currently) causes issues on Desktop so for the time being just stick with the `plaintext` size
                            finalByteCount = UInt(preparedFileSize ?? 0)
                            result = (ciphertext, encryptionKey, Data())
                    }
                    
                    /// Since the legacy encryption is a little more questionable we should double check the ciphertext size
                    guard result.ciphertext.count <= Network.maxFileSize else {
                        throw AttachmentError.fileSizeTooLarge
                    }
                }
                
                /// Since we successfully encrypted the data we can remove the file with the unencrypted content and replace it with
                /// the encrypted content
                try dependencies[singleton: .fileManager].removeItem(atPath: filePath)
                try dependencies[singleton: .fileManager].write(
                    data: result.ciphertext,
                    toPath: filePath
                )
                
                return (result, finalByteCount)
            }
            catch {
                /// If we failed to encrypt the data then we need to remove the temporary file that we created (as it won't be used)
                try? dependencies[singleton: .fileManager].removeItem(atPath: filePath)
                throw error
            }
        }
        
        return PreparedAttachment(
            attachment: try prepareAttachment(
                id: attachmentId,
                downloadUrl: filePath,
                byteCount: finalByteCount,
                encryptionKey: encryptedData.encryptionKey,
                digest: encryptedData.digest,
                using: dependencies
            ),
            filePath: filePath
        )
    }
    
    private func prepareImage(
        _ operations: Set<Operation>,
        filePath: String,
        using dependencies: Dependencies
    ) async throws {
        guard
            let targetSource: ImageDataManager.DataSource = visualMediaSource,
            case .media(let mediaMatadata) = self.metadata
        else { throw AttachmentError.invalidMediaSource }
        
        guard mediaMatadata.hasValidPixelSize else {
            Log.error(.attachmentManager, "Source has invalid image dimensions.")
            throw AttachmentError.invalidDimensions
        }
        
        /// If we want to convert to a certain format then that's all we need to do
        if case .convert(let format) = operations.first(where: { $0.erased == .convert }) {
            return try await createImage(
                source: targetSource,
                metadata: mediaMatadata,
                format: format,
                filePath: filePath,
                using: dependencies
            )
        }
        
        /// Otherwise if all we want to do is strip the metadata then we should do that
        ///
        /// **Note:** We don't currently support stripping metadata from animated images without conversion (as we need to do
        /// every frame which would have a negative impact on sending things like GIF attachments since it's fairly slow)
        if operations.contains(.stripImageMetadata) && !utType.isAnimated {
            let outputData: NSMutableData = NSMutableData()
            let options: CFDictionary? = dependencies[singleton: .mediaDecoder].defaultImageOptions
            
            guard
                let source: CGImageSource = targetSource.createImageSource(),
                let sourceType: String = CGImageSourceGetType(source) as? String,
                let cgImage: CGImage = CGImageSourceCreateImageAtIndex(source, 0, options),
                let destination = CGImageDestinationCreateWithData(outputData as CFMutableData, sourceType as CFString, 1, nil)
            else { throw AttachmentError.invalidData }
            
            /// Preserve orientation metadata
            let properties: [String: Any]? = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
            let orientation: Any? = properties?[kCGImagePropertyOrientation as String]
            let imageProperties: [CFString: Any] = (
                orientation.map { [kCGImagePropertyOrientation: $0] } ??
                [:]
            )
            
            CGImageDestinationAddImage(destination, cgImage, imageProperties as CFDictionary)
            
            guard CGImageDestinationFinalize(destination) else {
                throw AttachmentError.couldNotResizeImage
            }
            
            return try dependencies[singleton: .fileManager].write(
                data: outputData as Data,
                toPath: filePath
            )
        }
        
        /// If we got here then we don't want to modify the source so we just need to ensure the file exists on disk
        return try await createImage(
            source: targetSource,
            metadata: mediaMatadata,
            format: .current,
            filePath: filePath,
            using: dependencies
        )
    }
    
    private func prepareVideo(
        _ operations: Set<Operation>,
        filePath: String,
        using dependencies: Dependencies
    ) async throws {
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
        
        /// If we want to convert to a certain format then that's all we need to do
        if case .convert(let format) = operations.first(where: { $0.erased == .convert }) {
            return try await createVideo(
                source: targetSource,
                metadata: mediaMatadata,
                format: format,
                filePath: filePath,
                using: dependencies
            )
        }
        
        /// If we got here then we don't want to modify the source so we just need to ensure the file exists on disk
        try await createVideo(
            source: targetSource,
            metadata: mediaMatadata,
            format: .current,
            filePath: filePath,
            using: dependencies
        )
    }
    
    private func prepareAudio(
        _ operations: Set<Operation>,
        filePath: String,
        using dependencies: Dependencies
    ) async throws {
        guard case .media(let mediaMatadata) = self.metadata else {
            throw AttachmentError.invalidMediaSource
        }
        
        guard mediaMatadata.hasValidDuration else {
            Log.error(.attachmentManager, "Source has invalid duration.")
            throw AttachmentError.invalidDuration
        }
        
        switch source {
            case .voiceMessage(let url):
                try dependencies[singleton: .fileManager].copyItem(atPath: url.path, toPath: filePath)
            
            case .media(let mediaSource) where utType.isAudio:
                switch mediaSource {
                    case .url(let url):
                        try dependencies[singleton: .fileManager].copyItem(
                            atPath: url.path,
                            toPath: filePath
                        )
                    
                    case .data(_, let data):
                        try dependencies[singleton: .fileManager].write(data: data, toPath: filePath)
                        
                    default: throw AttachmentError.invalidMediaSource
                }
                
            default: throw AttachmentError.invalidMediaSource
        }
    }
    
    private func prepareText(
        _ operations: Set<Operation>,
        filePath: String,
        using dependencies: Dependencies
    ) async throws {
        guard
            case .text(let text) = source,
            let data: Data = text.data(using: .ascii)
        else { throw AttachmentError.invalidData }
        
        try dependencies[singleton: .fileManager].write(data: data, toPath: filePath)
    }
    
    private func prepareGeneral(
        _ operations: Set<Operation>,
        filePath: String,
        using dependencies: Dependencies
    ) async throws {
        switch source {
            case .media where (utType.isImage || utType.isAnimated):
                try await prepareImage(operations, filePath: filePath, using: dependencies)
                
            case .media where utType.isVideo:
                try await prepareVideo(operations, filePath: filePath, using: dependencies)
                
            case .media where utType.isAudio:
                try await prepareAudio(operations, filePath: filePath, using: dependencies)
                
            case .voiceMessage:
                try await prepareAudio(operations, filePath: filePath, using: dependencies)
                
            case .text:
                try await prepareText(operations, filePath: filePath, using: dependencies)
                
            case .file(let url), .media(.url(let url)):
                try dependencies[singleton: .fileManager].copyItem(
                    atPath: url.path,
                    toPath: filePath
                )
                
            case .media(.data(_, let data)):
                try dependencies[singleton: .fileManager].write(data: data, toPath: filePath)
                
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
                case .media(let mediaMetadata): return mediaMetadata.displaySize
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
            isValid: isValid,
            encryptionKey: encryptionKey,
            digest: digest
        )
    }
}

// MARK: - Convenience

public extension PendingAttachment {
    var visualMediaSource: ImageDataManager.DataSource? {
        guard !utType.isAudio else { return nil }
        guard case .media(let mediaSource) = self.source else { return nil }
        
        return mediaSource
    }
    
    /// Returns the file extension for this attachment or nil if no file extension can be identified
    var fileExtension: String? {
        guard
            let fileExtension: String = sourceFilename.map({ URL(fileURLWithPath: $0) })?.pathExtension,
            !fileExtension.isEmpty
        else { return utType.sessionFileExtension(sourceFilename: sourceFilename) }
        
        return fileExtension.filteredFilename
    }
    
    var isValid: Bool {
        // Process audio attachments
        if utType.isAudio {
            return (duration > 0)
        }
        
        // Process visual attachments
        if utType.isImage || utType.isAnimated || utType.isVideo {
            guard case .media(let mediaMetadata) = metadata else { return false }
            
            return (
                mediaMetadata.hasValidPixelSize &&
                mediaMetadata.hasValidDuration
            )
        }
        
        // Any other attachment types are valid and have no duration
        return true
    }
}

// MARK: - Type Conversions

public extension PendingAttachment {
    func toText() -> String? {
        /// Just to be safe ensure the file size isn't crazy large - since we have a character limit of 2,000 - 10,000 characters
        /// (which is ~40Kb) a 100Kb limit should be sufficiend
        guard (metadata?.fileSize ?? 0) < (1024 * 100) else { return nil }
        
        switch source {
            case .text(let text): return text
            case .file(let fileUrl): return try? String(contentsOf: fileUrl, encoding: .utf8)
            case .media(.data(_, let data)): return String(data: data, encoding: .utf8)
            case .media, .voiceMessage: return nil
        }
    }
    
    private func createVideo(
        source: ImageDataManager.DataSource,
        metadata: MediaUtils.MediaMetadata,
        format: ConversionFormat,
        filePath: String,
        using dependencies: Dependencies
    ) async throws {
        let url: URL
        
        switch source {
            case .url(let targetUrl), .videoUrl(let targetUrl, _, _, _): url = targetUrl
            case .data, .icon, .image, .urlThumbnail, .placeholderIcon, .asyncSource:
                throw AttachmentError.invalidData
        }
        
        /// Ensure the target format is an image format we support
        switch format {
            case .mp4, .current: break
            case .png, .webPLossy, .webPLossless, .gif: throw AttachmentError.couldNotConvert
        }
        
        /// Ensure we _actually_ need to make changes first
        guard mediaNeedsPreparation([.convert(to: format)], metadata: metadata) else {
            try dependencies[singleton: .fileManager].copyItem(atPath: url.path, toPath: filePath)
            return
        }
        
        return try await PendingAttachment.convertToMpeg4(
            asset: AVAsset(url: url),
            presetName: AVAssetExportPresetMediumQuality,
            filePath: filePath
        )
    }
    
    private func createImage(
        source: ImageDataManager.DataSource,
        metadata: MediaUtils.MediaMetadata,
        format: ConversionFormat,
        filePath: String,
        using dependencies: Dependencies
    ) async throws {
        /// Ensure the target format is an image format we support
        let targetMaxDimension: CGFloat?
        let targetCropRect: CGRect?
        let targetResizeMode: UIImage.ResizeMode
        
        switch format {
            case .png(let maxDimension, let cropRect, let resizeMode),
                .gif(let maxDimension, let cropRect, let resizeMode, _),
                .webPLossy(let maxDimension, let cropRect, let resizeMode, _),
                .webPLossless(let maxDimension, let cropRect, let resizeMode, _):
                targetMaxDimension = maxDimension
                targetCropRect = cropRect
                targetResizeMode = resizeMode
                break
            
            case .current:
                targetMaxDimension = nil
                targetCropRect = nil
                targetResizeMode = ConversionFormat.defaultResizeMode
                break
            
            case .mp4: throw AttachmentError.couldNotConvert
        }
        
        /// Ensure we _actually_ need to make changes first
        guard mediaNeedsPreparation([.convert(to: format)], metadata: metadata) else {
            switch source {
                case .url(let url):
                    try dependencies[singleton: .fileManager].copyItem(atPath: url.path, toPath: filePath)
                    
                case .image(_, let directImage):
                    /// For direct image, convert to data first
                    guard
                        let image: UIImage = directImage,
                        let data: Data = image.pngData()
                    else { throw AttachmentError.invalidData }
                    
                    try dependencies[singleton: .fileManager].write(data: data, toPath: filePath)
                    
                case .data(_, let data):
                    try dependencies[singleton: .fileManager].write(data: data, toPath: filePath)
                    
                default: throw AttachmentError.invalidMediaSource
            }
            return
        }
        
        /// Create a task to process the image asyncronously
        let task: Task<Void, Error> = Task.detached(priority: .userInitiated) {
            /// Extract the source
            let imageSource: CGImageSource
            let targetSize: CGSize = (
                targetMaxDimension.map { CGSize(width: $0, height: $0) } ??
                metadata.pixelSize
            )
            let isGif: Bool = {
                switch format {
                    case .gif: return true
                    default: return false
                }
            }()
            let isOpaque: Bool = (
                metadata.hasAlpha != true ||
                isGif /// GIF doesn't support alpha (single transparent color only)
            )
            
            switch source {
                case .image(_, let directImage):
                    /// For direct image, convert to data first
                    guard
                        let image = directImage,
                        let data = image.pngData()
                    else { throw AttachmentError.invalidData }
                    
                    imageSource = try dependencies[singleton: .mediaDecoder].source(for: data) ?? {
                        throw AttachmentError.invalidData
                    }()
                    
                case .url(let url):
                    imageSource = try dependencies[singleton: .mediaDecoder].source(for: url) ?? {
                        throw AttachmentError.invalidData
                    }()
                    
                case .data(_, let data):
                    imageSource = try dependencies[singleton: .mediaDecoder].source(for: data) ?? {
                        throw AttachmentError.invalidData
                    }()
                    
                default: throw AttachmentError.invalidMediaSource
            }
            
            /// Process frames in parallel (in batches) to balance performance and memory usage
            let options: CFDictionary? = dependencies[singleton: .mediaDecoder].defaultImageOptions
            let estimatedFrameMemory: CGFloat = (targetSize.width * targetSize.height * 4)
            let batchSize: Int = max(2, min(8, Int(50_000_000 / estimatedFrameMemory)))
            var frames: [CGImage] = []
            frames.reserveCapacity(metadata.frameCount)
            
            try Task.checkCancellation()
            
            for batchStart in stride(from: 0, to: metadata.frameCount, by: batchSize) {
                typealias FrameResult = (index: Int, frame: CGImage)
                
                try Task.checkCancellation()
                
                let batchEnd: Int = min(batchStart + batchSize, metadata.frameCount)
                let batchFrames: [CGImage] = try await withThrowingTaskGroup(of: FrameResult.self) { group in
                    for i in batchStart..<batchEnd {
                        group.addTask {
                            try Task.checkCancellation()
                            
                            return try autoreleasepool {
                                guard let cgImage = CGImageSourceCreateImageAtIndex(imageSource, i, options) else {
                                    throw AttachmentError.invalidImageData
                                }
                                
                                try Task.checkCancellation()
                                
                                let scaledImage: CGImage = cgImage.resized(
                                    toPixelSize: targetSize,
                                    mode: targetResizeMode,
                                    opaque: isOpaque,
                                    cropRect: targetCropRect,
                                    orientation: (metadata.orientation ?? .up)
                                )
                                
                                return (index: i, frame: scaledImage)
                            }
                        }
                    }
                    
                    return try await group
                        .reduce(into: []) { result, next in result.append(next) }
                        .sorted { $0.index < $1.index }
                        .map { $0.frame }
                }
                
                frames.append(contentsOf: batchFrames)
            }
            
            try Task.checkCancellation()
            
            /// Convert to the target format
            return try autoreleasepool {
                switch format {
                    case .current: throw AttachmentError.invalidFileFormat
                    case .mp4: throw AttachmentError.couldNotConvert
                    case .png:
                        try PendingAttachment.writeFramesAsPngToFile(
                            frames: frames,
                            metadata: metadata,
                            filePath: filePath
                        )
                    
                    case .gif(_, _, _, let quality):
                        try PendingAttachment.writeFramesAsGifToFile(
                            frames: frames,
                            metadata: metadata,
                            compressionQuality: quality,
                            filePath: filePath
                        )
                        
                    case .webPLossy(_, _, _, let quality), .webPLossless(_, _, _, let quality):
                        try PendingAttachment.writeFramesAsWebPToFile(
                            frames: frames,
                            metadata: metadata,
                            encodeWebPLossless: format.webPIsLossless,
                            encodeCompressionQuality: quality,
                            filePath: filePath,
                            using: dependencies
                        )
                }
            }
        }
        
        try await task.value
    }
    
    fileprivate static func writeFramesAsPngToFile(
        frames: [CGImage],
        metadata: MediaUtils.MediaMetadata,
        filePath: String
    ) throws {
        guard frames.count == 1 else { throw AttachmentError.invalidData }
        guard
            let destination: CGImageDestination = CGImageDestinationCreateWithURL(
                URL(fileURLWithPath: filePath) as CFURL,
                UTType.png.identifier as CFString,
                1,
                nil
            )
        else { throw AttachmentError.couldNotResizeImage }
        
        CGImageDestinationAddImage(destination, frames[0], nil)
        
        guard CGImageDestinationFinalize(destination) else {
            throw AttachmentError.couldNotResizeImage
        }
    }
    
    fileprivate static func writeFramesAsGifToFile(
        frames: [CGImage],
        metadata: MediaUtils.MediaMetadata,
        compressionQuality: CGFloat,
        filePath: String
    ) throws {
        guard frames.count == metadata.frameDurations.count else { throw AttachmentError.invalidData }
        guard
            let destination: CGImageDestination = CGImageDestinationCreateWithURL(
                URL(fileURLWithPath: filePath) as CFURL,
                UTType.gif.identifier as CFString,
                frames.count,
                nil
            )
        else { throw AttachmentError.couldNotResizeImage }
        
        // Set GIF properties (loop forever)
        let gifProperties: [String: Any] = [
            kCGImagePropertyGIFDictionary as String: [
                kCGImagePropertyGIFLoopCount as String: 0,
                kCGImagePropertyGIFHasGlobalColorMap as String: true
            ]
        ]
        CGImageDestinationSetProperties(destination, gifProperties as CFDictionary)
        
        // Add each frame
        for (index, frame) in frames.enumerated() {
            let duration = metadata.frameDurations[index]
            
            let frameProperties: [String: Any] = [
                kCGImagePropertyGIFDictionary as String: [
                    kCGImagePropertyGIFDelayTime as String: duration,
                    kCGImagePropertyGIFUnclampedDelayTime as String: duration
                ],
                kCGImageDestinationLossyCompressionQuality as String: compressionQuality
            ]
            
            CGImageDestinationAddImage(destination, frame, frameProperties as CFDictionary)
        }
        
        guard CGImageDestinationFinalize(destination) else {
            throw AttachmentError.couldNotResizeImage
        }
    }
    
    fileprivate static func writeFramesAsWebPToFile(
        frames: [CGImage],
        metadata: MediaUtils.MediaMetadata,
        encodeWebPLossless: Bool,
        encodeCompressionQuality: CGFloat,
        filePath: String,
        using dependencies: Dependencies
    ) throws {
        guard frames.count == metadata.frameDurations.count else { throw AttachmentError.invalidData }
        
        /// Convert to an image (`SDImageWebPCoder` only supports encoding a `UIImage`)
        let sdFrames: [SDImageFrame] = frames.enumerated().map { index, frame in
            autoreleasepool {
                SDImageFrame(
                    image: UIImage(
                        cgImage: frame,
                        scale: 1,
                        orientation: .up /// Since we loaded the frame as a CGImage the orientation will be stripped
                    ),
                    duration: metadata.frameDurations[index]
                )
            }
        }
        
        guard let imageToProcess: UIImage = SDImageCoderHelper.animatedImage(with: sdFrames) else {
            throw AttachmentError.invalidData
        }
    
        /// Peform the encoding
        let outputData: Data = try SDImageWebPCoder.shared.encodedData(
            with: imageToProcess,
            format: .webP,
            options: [
                .encodeWebPLossless: encodeWebPLossless,
                .encodeCompressionQuality: encodeCompressionQuality
            ]
        ) ?? { throw AttachmentError.couldNotConvertToWebP }()
        
        /// Write the converted data to a temporary file
        try dependencies[singleton: .fileManager].write(data: outputData, toPath: filePath)
    }
    
    static func convertToMpeg4(
        asset: AVAsset,
        presetName: String,
        filePath: String
    ) async throws {
        guard
            let exportSession: AVAssetExportSession = AVAssetExportSession(
                asset: asset,
                presetName: presetName
            )
        else { throw AttachmentError.couldNotConvertToMpeg4 }
        
        exportSession.shouldOptimizeForNetworkUse = true
        exportSession.outputFileType = AVFileType.mp4
        exportSession.metadataItemFilter = AVMetadataItemFilter.forSharing()
        exportSession.outputURL = URL(fileURLWithPath: filePath)
        
        return try await withCheckedThrowingContinuation { continuation in
            exportSession.exportAsynchronously { [weak exportSession] in
                guard exportSession?.status == .completed else {
                    return continuation.resume(throwing: AttachmentError.couldNotConvertToMpeg4)
                }
                
                continuation.resume()
            }
        }
    }
}
