// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import AVFAudio
import AVFoundation
import Combine
import UniformTypeIdentifiers
import GRDB
import SessionUIKit
import SessionSnodeKit
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
    private let dependencies: Dependencies
    
    // MARK: - Initalization
    
    init(using dependencies: Dependencies) {
        self.dependencies = dependencies
    }
    
    // MARK: - General
    
    public func sharedDataAttachmentsDirPath() -> String {
        let path: String = URL(fileURLWithPath: SessionFileManager.nonInjectedAppSharedDataDirectoryPath)
            .appendingPathComponent("Attachments") // stringlint:ignore
            .path
        try? dependencies[singleton: .fileManager].ensureDirectoryExists(at: path)
        
        return path
    }
    
    // MARK: - File Paths
    
    /// **Note:** Generally the url we get won't have an extension and we don't want to make assumptions until we have the actual
    /// image data so generate a name for the file and then determine the extension separately
    public func path(for urlString: String?) throws -> String {
        guard
            let urlString: String = urlString,
            !urlString.isEmpty
        else { throw DisplayPictureError.invalidCall }
        
        let urlHash = try dependencies[singleton: .crypto]
            .tryGenerate(.hash(message: Array(urlString.utf8)))
            .toHexString()
        
        return URL(fileURLWithPath: sharedDataAttachmentsDirPath())
            .appendingPathComponent(urlHash)
            .path
    }
    
    private func placeholderUrlPath() -> String {
        return URL(fileURLWithPath: sharedDataAttachmentsDirPath())
            .appendingPathComponent("uploadPlaceholderUrl")  // stringlint:ignore
            .path
    }
    
    public func uploadPathAndUrl(for id: String) throws -> (url: String, path: String) {
        let fakeLocalUrlPath: String = URL(fileURLWithPath: placeholderUrlPath())
            .appendingPathComponent(URL(fileURLWithPath: id).path)
            .path
        
        return (fakeLocalUrlPath, try path(for: fakeLocalUrlPath))
    }
    
    public func isPlaceholderUploadUrl(_ url: String?) -> Bool {
        return (url?.hasPrefix(placeholderUrlPath()) == true)
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
        guard !url.lastPathComponent.isEmpty else { throw DisplayPictureError.invalidCall }
        
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
        
        // Process audio attachments
        if UTType.isAudio(contentType) {
            do {
                let audioPlayer: AVAudioPlayer = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
                
                return ((audioPlayer.duration > 0), audioPlayer.duration)
            }
            catch {
                switch (error as NSError).code {
                    case Int(kAudioFileInvalidFileError), Int(kAudioFileStreamError_InvalidFile):
                        // Ignore "invalid audio file" errors
                        return (false, nil)
                        
                    default: return (false, nil)
                }
            }
        }
        
        // Process image attachments
        if UTType.isImage(contentType) || UTType.isAnimated(contentType) {
            return (
                Data.isValidImage(at: path, type: UTType(sessionMimeType: contentType), using: dependencies),
                nil
            )
        }
        
        // Process video attachments
        if UTType.isVideo(contentType) {
            let assetInfo: (asset: AVURLAsset, cleanup: () -> Void)? = AVURLAsset.asset(
                for: path,
                mimeType: contentType,
                sourceFilename: sourceFilename,
                using: dependencies
            )
            
            guard
                let asset: AVURLAsset = assetInfo?.asset,
                MediaUtils.isVideoOfValidContentTypeAndSize(
                    path: path,
                    type: contentType,
                    using: dependencies
                ),
                MediaUtils.isValidVideo(asset: asset)
            else {
                assetInfo?.cleanup()
                return (false, nil)
            }
            
            let durationSeconds: TimeInterval = (
                // According to the CMTime docs "value/timescale = seconds"
                TimeInterval(asset.duration.value) / TimeInterval(asset.duration.timescale)
            )
            assetInfo?.cleanup()
            
            return (true, durationSeconds)
        }
        
        // Any other attachment types are valid and have no duration
        return (true, nil)
    }
}
