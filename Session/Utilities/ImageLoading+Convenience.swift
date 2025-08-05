// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SwiftUI
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit

// MARK: - ImageDataManager.DataSource Convenience

public extension ImageDataManager.DataSource {
    static func from(
        attachment: Attachment,
        using dependencies: Dependencies
    ) -> ImageDataManager.DataSource? {
        guard
            attachment.isVisualMedia,
            let path: String = try? dependencies[singleton: .attachmentManager]
                .path(for: attachment.downloadUrl)
        else { return nil }
        
        if attachment.isVideo {
            /// Videos need special handling so handle those specially
            return .videoUrl(
                URL(fileURLWithPath: path),
                attachment.contentType,
                attachment.sourceFilename,
                dependencies[singleton: .attachmentManager]
            )
        }
        
        return .url(URL(fileURLWithPath: path))
    }
    
    static func thumbnailFrom(
        attachment: Attachment,
        size: ImageDataManager.ThumbnailSize,
        using dependencies: Dependencies
    ) -> ImageDataManager.DataSource? {
        guard
            attachment.isVisualMedia,
            let path: String = try? dependencies[singleton: .attachmentManager]
                .path(for: attachment.downloadUrl)
        else { return nil }
        
        /// Can't thumbnail animated images so just load the full file in this case
        if attachment.isAnimated {
            return .url(URL(fileURLWithPath: path))
        }
        
        /// Videos have a custom method for generating their thumbnails so use that instead
        if attachment.isVideo {
            return .videoUrl(
                URL(fileURLWithPath: path),
                attachment.contentType,
                attachment.sourceFilename,
                dependencies[singleton: .attachmentManager]
            )
        }
        
        return .urlThumbnail(
            URL(fileURLWithPath: path),
            size,
            dependencies[singleton: .attachmentManager]
        )
    }
}

// MARK: - ImageDataManagerType Convenience

public extension ImageDataManagerType {
    func loadImage(
        attachment: Attachment,
        using dependencies: Dependencies,
        onComplete: @escaping (ImageDataManager.ProcessedImageData?) -> Void = { _ in }
    ) {
        guard let source: ImageDataManager.DataSource = ImageDataManager.DataSource.from(
            attachment: attachment,
            using: dependencies
        ) else { return onComplete(nil) }
        
        load(source, onComplete: onComplete)
    }
    
    func loadThumbnail(
        size: ImageDataManager.ThumbnailSize,
        attachment: Attachment,
        using dependencies: Dependencies,
        onComplete: @escaping (ImageDataManager.ProcessedImageData?) -> Void = { _ in }
    ) {
        guard let source: ImageDataManager.DataSource = ImageDataManager.DataSource.thumbnailFrom(
            attachment: attachment,
            size: size,
            using: dependencies
        ) else { return onComplete(nil) }
        
        load(source, onComplete: onComplete)
    }
    
    func cachedImage(
        attachment: Attachment,
        using dependencies: Dependencies
    ) -> UIImage? {
        guard let source: ImageDataManager.DataSource = ImageDataManager.DataSource.from(
            attachment: attachment,
            using: dependencies
        ) else { return nil }
        
        let semaphore: DispatchSemaphore = DispatchSemaphore(value: 0)
        var result: ImageDataManager.ProcessedImageData? = nil
        
        load(source) { imageData in
            result = imageData
            semaphore.signal()
        }
        
        /// We don't really want to wait at all but it's async logic so give it a very time timeout so it has the chance
        /// to deal with other logic running
        _ = semaphore.wait(timeout: .now() + .milliseconds(10))
        
        switch result?.type {
            case .staticImage(let image): return image
            case .animatedImage(let frames, _): return frames.first
            case .none: return nil
        }
    }
}

// MARK: - SessionImageView Convenience

public extension SessionImageView {
    @MainActor
    func loadImage(from path: String, onComplete: ((Bool) -> Void)? = nil) {
        loadImage(.url(URL(fileURLWithPath: path)), onComplete: onComplete)
    }
    
    @MainActor
    func loadImage(
        attachment: Attachment,
        using dependencies: Dependencies,
        onComplete: ((Bool) -> Void)? = nil
    ) {
        guard let source: ImageDataManager.DataSource = ImageDataManager.DataSource.from(
            attachment: attachment,
            using: dependencies
        ) else {
            onComplete?(false)
            return
        }
        
        loadImage(source, onComplete: onComplete)
    }
    
    @MainActor
    func loadThumbnail(
        size: ImageDataManager.ThumbnailSize,
        attachment: Attachment,
        using dependencies: Dependencies,
        onComplete: ((Bool) -> Void)? = nil
    ) {
        guard let source: ImageDataManager.DataSource = ImageDataManager.DataSource.thumbnailFrom(
            attachment: attachment,
            size: size,
            using: dependencies
        ) else {
            onComplete?(false)
            return
        }
        
        loadImage(source, onComplete: onComplete)
    }
    
    @MainActor
    func loadPlaceholder(seed: String, text: String, size: CGFloat, onComplete: ((Bool) -> Void)? = nil) {
        loadImage(.placeholderIcon(seed: seed, text: text, size: size), onComplete: onComplete)
    }
}

// MARK: - SessionAsyncImage Convenience

public extension SessionAsyncImage {
    init(
        attachment: Attachment,
        thumbnailSize: ImageDataManager.ThumbnailSize,
        using dependencies: Dependencies,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        let source: ImageDataManager.DataSource? = ImageDataManager.DataSource.thumbnailFrom(
            attachment: attachment,
            size: thumbnailSize,
            using: dependencies
        )
        
        /// Fallback in case we don't have a valid source
        self.init(
            source: (source ?? .image("", nil)),
            dataManager: dependencies[singleton: .imageDataManager],
            content: content,
            placeholder: placeholder
        )
    }
}
