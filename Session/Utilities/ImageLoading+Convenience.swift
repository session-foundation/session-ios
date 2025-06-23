// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SwiftUI
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit

// MARK: - ImageDataManagerType Convenience

public extension ImageDataManagerType {
    func loadImage(
        attachment: Attachment,
        using dependencies: Dependencies,
        onComplete: @escaping (ImageDataManager.ProcessedImageData?) -> Void = { _ in }
    ) {
        guard
            attachment.isVisualMedia,
            let path: String = try? dependencies[singleton: .attachmentManager]
                .path(for: attachment.downloadUrl)
        else { return onComplete(nil) }
        
        if attachment.isVideo {
            /// Videos need special handling so handle those specially
            load(
                .videoUrl(
                    URL(fileURLWithPath: path),
                    attachment.contentType,
                    attachment.sourceFilename,
                    dependencies[singleton: .attachmentManager]
                ),
                onComplete: onComplete
            )
        }
        else {
            load(.url(URL(fileURLWithPath: path)), onComplete: onComplete)
        }
    }
    
    func loadThumbnail(
        size: ImageDataManager.ThumbnailSize,
        attachment: Attachment,
        using dependencies: Dependencies,
        onComplete: @escaping (ImageDataManager.ProcessedImageData?) -> Void = { _ in }
    ) {
        guard
            attachment.isVisualMedia,
            let path: String = try? dependencies[singleton: .attachmentManager]
                .path(for: attachment.downloadUrl)
        else { return onComplete(nil) }
        
        if attachment.isAnimated {
            /// Can't thumbnail animated images so just load the full file in this case
            load(.url(URL(fileURLWithPath: path)), onComplete: onComplete)
        }
        else if attachment.isVideo {
            /// Videos have a custom method for generating their thumbnails so use that instead
            load(
                .videoUrl(
                    URL(fileURLWithPath: path),
                    attachment.contentType,
                    attachment.sourceFilename,
                    dependencies[singleton: .attachmentManager]
                ),
                onComplete: onComplete
            )
        }
        else {
            load(
                .urlThumbnail(
                    URL(fileURLWithPath: path),
                    size,
                    dependencies[singleton: .attachmentManager]
                ),
                onComplete: onComplete
            )
        }
    }
    
    func cachedImage(
        attachment: Attachment,
        using dependencies: Dependencies
    ) -> UIImage? {
        guard
            attachment.isVisualMedia,
            let path: String = try? dependencies[singleton: .attachmentManager]
                .path(for: attachment.downloadUrl)
        else { return nil }
        
        let semaphore: DispatchSemaphore = DispatchSemaphore(value: 0)
        var result: ImageDataManager.ProcessedImageData? = nil
        
        if attachment.isVideo {
            /// Videos have a custom method for generating their thumbnails so use that instead
            load(
                .videoUrl(
                    URL(fileURLWithPath: path),
                    attachment.contentType,
                    attachment.sourceFilename,
                    dependencies[singleton: .attachmentManager]
                )
            ) { imageData in
                result = imageData
                semaphore.signal()
            }
        }
        else {
            load(.url(URL(fileURLWithPath: path))) { imageData in
                result = imageData
                semaphore.signal()
            }
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
        guard
            attachment.isVisualMedia,
            let path: String = try? dependencies[singleton: .attachmentManager]
                .path(for: attachment.downloadUrl)
        else {
            onComplete?(false)
            return
        }
        
        if attachment.isVideo {
            /// Videos need special handling so handle those specially
            loadImage(
                .videoUrl(
                    URL(fileURLWithPath: path),
                    attachment.contentType,
                    attachment.sourceFilename,
                    dependencies[singleton: .attachmentManager]
                ),
                onComplete: onComplete
            )
        }
        else {
            loadImage(.url(URL(fileURLWithPath: path)), onComplete: onComplete)
        }
    }
    
    @MainActor
    func loadThumbnail(
        size: ImageDataManager.ThumbnailSize,
        attachment: Attachment,
        using dependencies: Dependencies,
        onComplete: ((Bool) -> Void)? = nil
    ) {
        guard
            attachment.isVisualMedia,
            let path: String = try? dependencies[singleton: .attachmentManager]
                .path(for: attachment.downloadUrl)
        else {
            onComplete?(false)
            return
        }
        
        if attachment.isAnimated {
            /// Can't thumbnail animated images so just load the full file in this case
            loadImage(.url(URL(fileURLWithPath: path)), onComplete: onComplete)
        }
        else if attachment.isVideo {
            /// Videos have a custom method for generating their thumbnails so use that instead
            loadImage(
                .videoUrl(
                    URL(fileURLWithPath: path),
                    attachment.contentType,
                    attachment.sourceFilename,
                    dependencies[singleton: .attachmentManager]
                ),
                onComplete: onComplete
            )
        }
        else {
            loadImage(
                .urlThumbnail(
                    URL(fileURLWithPath: path),
                    size,
                    dependencies[singleton: .attachmentManager]
                ),
                onComplete: onComplete
            )
        }
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
        let source: ImageDataManager.DataSource
        
        if
            attachment.isVisualMedia,
            let path: String = try? dependencies[singleton: .attachmentManager]
                .path(for: attachment.downloadUrl)
        {
            if attachment.isAnimated {
                /// Can't thumbnail animated images so just load the full file in this case
                source = .url(URL(fileURLWithPath: path))
            }
            else if attachment.isVideo {
                /// Videos have a custom method for generating their thumbnails so use that instead
                source = .videoUrl(
                    URL(fileURLWithPath: path),
                    attachment.contentType,
                    attachment.sourceFilename,
                    dependencies[singleton: .attachmentManager]
                )
            }
            else {
                source = .urlThumbnail(
                    URL(fileURLWithPath: path),
                    thumbnailSize,
                    dependencies[singleton: .attachmentManager]
                )
            }
        }
        else {
            /// Fallback in case we don't have a valid source
            source = .image("", nil)
        }
        
        self.init(
            source: source,
            dataManager: dependencies[singleton: .imageDataManager],
            content: content,
            placeholder: placeholder
        )
    }
}
