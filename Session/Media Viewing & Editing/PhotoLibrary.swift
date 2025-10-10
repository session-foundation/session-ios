// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import Photos
import CoreServices
import UniformTypeIdentifiers
import SignalUtilitiesKit
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit

protocol PhotoLibraryDelegate: AnyObject {
    func photoLibraryDidChange(_ photoLibrary: PhotoLibrary)
}

class PhotoMediaSize {
    var thumbnailSize: CGSize

    init() {
        self.thumbnailSize = .zero
    }

    init(thumbnailSize: CGSize) {
        self.thumbnailSize = thumbnailSize
    }
}

class PhotoPickerAssetItem: PhotoGridItem {

    let asset: PHAsset
    let photoCollectionContents: PhotoCollectionContents
    let size: ImageDataManager.ThumbnailSize
    let pixelDimension: CGFloat

    init(
        asset: PHAsset,
        photoCollectionContents: PhotoCollectionContents,
        size: ImageDataManager.ThumbnailSize,
        pixelDimension: CGFloat
    ) {
        self.asset = asset
        self.photoCollectionContents = photoCollectionContents
        self.size = size
        self.pixelDimension = pixelDimension
    }

    // MARK: PhotoGridItem

    var isVideo: Bool { asset.mediaType == .video }
    var source: ImageDataManager.DataSource {
        return .asyncSource(self.asset.localIdentifier) { [photoCollectionContents, asset, size, pixelDimension] in
            await photoCollectionContents.requestThumbnail(
                for: asset,
                size: size,
                thumbnailSize: CGSize(width: pixelDimension, height: pixelDimension)
            )
        }
    }
}

class PhotoCollectionContents {

    let fetchResult: PHFetchResult<PHAsset>
    let localizedTitle: String?

    enum PhotoLibraryError: Error {
        case assertionError(description: String)
        case unsupportedMediaType
    }

    init(fetchResult: PHFetchResult<PHAsset>, localizedTitle: String?) {
        self.fetchResult = fetchResult
        self.localizedTitle = localizedTitle
    }

    private let imageManager = PHCachingImageManager()

    // MARK: - Asset Accessors

    var assetCount: Int {
        return fetchResult.count
    }

    var lastAsset: PHAsset? {
        guard assetCount > 0 else {
            return nil
        }
        return asset(at: assetCount - 1)
    }

    var firstAsset: PHAsset? {
        guard assetCount > 0 else {
            return nil
        }
        return asset(at: 0)
    }

    func asset(at index: Int) -> PHAsset? {
        guard index >= 0 && index < fetchResult.count else { return nil }
        
        return fetchResult.object(at: index)
    }

    // MARK: - AssetItem Accessors

    func assetItem(at index: Int, size: ImageDataManager.ThumbnailSize, pixelDimension: CGFloat) -> PhotoPickerAssetItem? {
        guard let mediaAsset: PHAsset = asset(at: index) else { return nil }
        
        return PhotoPickerAssetItem(
            asset: mediaAsset,
            photoCollectionContents: self,
            size: size,
            pixelDimension: pixelDimension
        )
    }

    func firstAssetItem(size: ImageDataManager.ThumbnailSize, pixelDimension: CGFloat) -> PhotoPickerAssetItem? {
        guard let mediaAsset = firstAsset else { return nil }
        
        return PhotoPickerAssetItem(
            asset: mediaAsset,
            photoCollectionContents: self,
            size: size,
            pixelDimension: pixelDimension
        )
    }

    func lastAssetItem(size: ImageDataManager.ThumbnailSize, pixelDimension: CGFloat) -> PhotoPickerAssetItem? {
        guard let mediaAsset = lastAsset else { return nil }
        
        return PhotoPickerAssetItem(
            asset: mediaAsset,
            photoCollectionContents: self,
            size: size,
            pixelDimension: pixelDimension
        )
    }

    // MARK: ImageManager
    
    func requestThumbnail(for asset: PHAsset, size: ImageDataManager.ThumbnailSize, thumbnailSize: CGSize) async -> ImageDataManager.DataSource? {
        var hasResumed: Bool = false
        
        /// The `requestImage` function will always return a static thumbnail so if it's an animated image then we need custom
        /// handling (the default PhotoKit resizing can't resize animated images so we need to return the original file)
        switch asset.utType?.isAnimated {
            case .some(true):
                return await withCheckedContinuation { [imageManager] continuation in
                    let options = PHImageRequestOptions()
                    options.deliveryMode = .highQualityFormat
                    options.isNetworkAccessAllowed = true
                    
                    imageManager.requestImageDataAndOrientation(for: asset, options: options) { data, uti, orientation, info in
                        guard !hasResumed else { return }
                        
                        guard let data = data, info?[PHImageErrorKey] == nil else {
                            hasResumed = true
                            continuation.resume(returning: nil)
                            return
                        }
                        
                        // Successfully fetched the data, resume with the animated result
                        hasResumed = true
                        continuation.resume(returning: .data(asset.localIdentifier, data))
                    }
                }
                
            default:
                return await withCheckedContinuation { [imageManager] continuation in
                    let options = PHImageRequestOptions()
                    
                    switch size {
                        case .small: options.deliveryMode = .opportunistic
                        case .medium, .large: options.deliveryMode = .highQualityFormat
                    }
                    
                    imageManager.requestImage(
                        for: asset,
                        targetSize: thumbnailSize,
                        contentMode: .aspectFill,
                        options: options
                    ) { image, info in
                        guard !hasResumed else { return }
                        guard
                            info?[PHImageErrorKey] == nil,
                            (info?[PHImageCancelledKey] as? Bool) != true
                        else {
                            hasResumed = true
                            return continuation.resume(returning: nil)
                        }
                        
                        switch size {
                            case .small: break  // We want the first image, whether it is degraded or not
                            case .medium, .large:
                                // For medium and large thumbnails we want the full image so ignore any
                                // degraded images
                                guard (info?[PHImageResultIsDegradedKey] as? Bool) != true else { return }
                                
                        }
                        
                        continuation.resume(returning: .image("\(asset.localIdentifier)-\(size)", image))
                        hasResumed = true
                    }
                }
        }
    }

    private func requestImageDataSource(
        for asset: PHAsset,
        using dependencies: Dependencies
    ) async throws -> PendingAttachment {
        let options: PHImageRequestOptions = PHImageRequestOptions()
        options.isSynchronous = false
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        
        let pendingAttachment: PendingAttachment = try await withCheckedThrowingContinuation { [imageManager] continuation in
            imageManager.requestImageDataAndOrientation(for: asset, options: options) { imageData, dataUTI, orientation, info in
                if let error: Error = info?[PHImageErrorKey] as? Error {
                    return continuation.resume(throwing: error)
                }
                
                if (info?[PHImageCancelledKey] as? Bool) == true {
                    return continuation.resume(throwing: PhotoLibraryError.assertionError(description: "Image request cancelled"))
                }
                
                // If we get a degraded image then we want to wait for the next callback (which will
                // be the non-degraded version)
                guard (info?[PHImageResultIsDegradedKey] as? Bool) != true else {
                    return
                }
                
                guard let imageData: Data = imageData else {
                    return continuation.resume(throwing: PhotoLibraryError.assertionError(description: "imageData was unexpectedly nil"))
                }
                
                guard let type: UTType = dataUTI.map({ UTType($0) }) else {
                    return continuation.resume(throwing: PhotoLibraryError.assertionError(description: "dataUTI was unexpectedly nil"))
                }
                
                guard let filePath: String = try? dependencies[singleton: .fileManager].write(dataToTemporaryFile: imageData) else {
                    return continuation.resume(throwing: PhotoLibraryError.assertionError(description: "failed to write temporary file"))
                }
                
                continuation.resume(
                    returning: PendingAttachment(
                        source: .media(URL(fileURLWithPath: filePath)),
                        utType: type,
                        using: dependencies
                    )
                )
            }
        }
        
        /// Apple likes to use special formats for media so in order to maintain compatibility with other clients we want to
        /// convert the selected image into a `WebP` if it's not one of the supported output types
        guard UTType.supportedOutputImageTypes.contains(pendingAttachment.utType) else {
            /// Since we need to convert the file we should clean up the temporary one we created earlier (the conversion will create
            /// a new one)
            defer {
                switch pendingAttachment.source {
                    case .file(let url), .media(.url(let url)):
                        if dependencies[singleton: .fileManager].isLocatedInTemporaryDirectory(url.path) {
                            try? dependencies[singleton: .fileManager].removeItem(atPath: url.path)
                        }
                    default: break
                }
            }
            
            let preparedAttachment: PreparedAttachment = try await pendingAttachment.prepare(
                operations: [.convert(to: .webPLossy)],
                using: dependencies
            )
            
            return PendingAttachment(
                source: .media(.url(URL(fileURLWithPath: preparedAttachment.filePath))),
                utType: .webP,
                sourceFilename: pendingAttachment.sourceFilename,
                using: dependencies
            )
        }
        
        return pendingAttachment
    }

    private func requestVideoDataSource(
        for asset: PHAsset,
        using dependencies: Dependencies
    ) async throws -> PendingAttachment {
        let options: PHVideoRequestOptions = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        
        return try await withCheckedThrowingContinuation { [imageManager] continuation in
            imageManager.requestAVAsset(forVideo: asset, options: options) { avAsset, _, info in
                if let error: Error = info?[PHImageErrorKey] as? Error {
                    return continuation.resume(throwing: error)
                }
                
                if (info?[PHImageCancelledKey] as? Bool) == true {
                    return continuation.resume(throwing: PhotoLibraryError.assertionError(description: "Video request cancelled"))
                }
                
                guard let avAsset: AVAsset = avAsset else {
                    return continuation.resume(throwing: PhotoLibraryError.assertionError(description: "avAsset was unexpectedly nil"))
                }
                
                let compatiblePresets = AVAssetExportSession.exportPresets(compatibleWith: avAsset)
                let bestExportPreset: String = (compatiblePresets.contains(AVAssetExportPresetPassthrough) ?
                    AVAssetExportPresetPassthrough :
                    AVAssetExportPresetHighestQuality
                )
                let exportPath: String = dependencies[singleton: .fileManager].temporaryFilePath()
                
                Task {
                    do {
                        /// Apple likes to use special formats for media so in order to maintain compatibility with other clients we want to
                        /// convert the selected video into an `mp4`
                        try await PendingAttachment.convertToMpeg4(
                            asset: avAsset,
                            presetName: bestExportPreset,
                            filePath: exportPath
                        )
                        
                        continuation.resume(
                            returning: PendingAttachment(
                                source: .media(
                                    .videoUrl(
                                        URL(fileURLWithPath: exportPath),
                                        .mpeg4Movie,
                                        nil,
                                        dependencies[singleton: .attachmentManager]
                                    )
                                ),
                                utType: .mpeg4Movie,
                                using: dependencies
                            )
                        )
                    }
                    catch { continuation.resume(throwing: error) }
                }
            }
        }
    }

    func pendingAttachment(for asset: PHAsset, using dependencies: Dependencies) async throws -> PendingAttachment {
        switch asset.mediaType {
            case .image: return try await requestImageDataSource(for: asset, using: dependencies)
            case .video: return try await requestVideoDataSource(for: asset, using: dependencies)
            default: throw PhotoLibraryError.unsupportedMediaType
        }
    }
}

class PhotoCollection {
    public let id: String
    private let collection: PHAssetCollection
    
    // The user never sees this collection, but we use it for a null object pattern
    // when the user has denied photos access.
    static let empty = PhotoCollection(id: "", collection: PHAssetCollection())

    init(id: String, collection: PHAssetCollection) {
        self.id = id
        self.collection = collection
    }

    func localizedTitle() -> String {
        guard let localizedTitle = collection.localizedTitle?.stripped,
            localizedTitle.count > 0 else {
            return "attachmentsAlbumUnnamed".localized()
        }
        return localizedTitle
    }

    // stringlint:ignore_contents
    func contents() -> PhotoCollectionContents {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let fetchResult = PHAsset.fetchAssets(in: collection, options: options)

        return PhotoCollectionContents(fetchResult: fetchResult, localizedTitle: localizedTitle())
    }
}

extension PhotoCollection: Equatable {
    static func == (lhs: PhotoCollection, rhs: PhotoCollection) -> Bool {
        return lhs.collection == rhs.collection
    }
}

class PhotoLibrary: NSObject, PHPhotoLibraryChangeObserver {
    typealias WeakDelegate = Weak<PhotoLibraryDelegate>
    var delegates = [WeakDelegate]()

    public func add(delegate: PhotoLibraryDelegate) {
        delegates.append(WeakDelegate(value: delegate))
    }

    var assetCollection: PHAssetCollection!

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        DispatchQueue.main.async {
            for weakDelegate in self.delegates {
                weakDelegate.value?.photoLibraryDidChange(self)
            }
        }
    }

    override init() {
        super.init()
        PHPhotoLibrary.shared().register(self)
    }

    deinit {
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }
    
    // stringlint:ignore_contents
    private lazy var fetchOptions: PHFetchOptions = {
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "endDate", ascending: true)]
        return fetchOptions
    }()

    func defaultPhotoCollection() -> PhotoCollection {
        var fetchedCollection: PhotoCollection?
        PHAssetCollection.fetchAssetCollections(
            with: .smartAlbum,
            subtype: .smartAlbumUserLibrary,
            options: fetchOptions
        ).enumerateObjects { collection, _, stop in
            fetchedCollection = PhotoCollection(id: collection.localIdentifier, collection: collection)
            stop.pointee = true
        }

        guard let photoCollection = fetchedCollection else {
            Log.debug("[PhotoLibrary] Using empty photo collection.")
            Log.assert(PHPhotoLibrary.authorizationStatus() == .denied)
            return PhotoCollection.empty
        }

        return photoCollection
    }

    func allPhotoCollections() -> [PhotoCollection] {
        var collections = [PhotoCollection]()
        var collectionIds = Set<String>()

        let processPHCollection: ((collection: PHCollection, hideIfEmpty: Bool)) -> Void = { arg in
            let (collection, hideIfEmpty) = arg

            // De-duplicate by id.
            let collectionId: String = collection.localIdentifier
            
            guard !collectionIds.contains(collectionId) else { return }
            collectionIds.insert(collectionId)

            guard let assetCollection = collection as? PHAssetCollection else {
                Log.error("[PhotoLibrary] Asset collection has unexpected type: \(type(of: collection))")
                return
            }
            let photoCollection = PhotoCollection(id: collectionId, collection: assetCollection)
            guard !hideIfEmpty || photoCollection.contents().assetCount > 0 else {
                return
            }

            collections.append(photoCollection)
        }
        let processPHAssetCollections: ((fetchResult: PHFetchResult<PHAssetCollection>, hideIfEmpty: Bool)) -> Void = { arg in
            let (fetchResult, hideIfEmpty) = arg

            fetchResult.enumerateObjects { (assetCollection, _, _) in
                // We're already sorting albums by last-updated. "Recently Added" is mostly redundant
                guard assetCollection.assetCollectionSubtype != .smartAlbumRecentlyAdded else {
                    return
                }

                // undocumented constant
                let kRecentlyDeletedAlbumSubtype = PHAssetCollectionSubtype(rawValue: 1000000201)
                guard assetCollection.assetCollectionSubtype != kRecentlyDeletedAlbumSubtype else {
                    return
                }

                processPHCollection((collection: assetCollection, hideIfEmpty: hideIfEmpty))
            }
        }
        let processPHCollections: ((fetchResult: PHFetchResult<PHCollection>, hideIfEmpty: Bool)) -> Void = { arg in
            let (fetchResult, hideIfEmpty) = arg

            for index in 0..<fetchResult.count {
                processPHCollection((collection: fetchResult.object(at: index), hideIfEmpty: hideIfEmpty))
            }
        }
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "endDate", ascending: true)] // stringlint:ignore

        // Try to add "Camera Roll" first.
        processPHAssetCollections((fetchResult: PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumUserLibrary, options: fetchOptions),
                                   hideIfEmpty: false))

        // Favorites
        processPHAssetCollections((fetchResult: PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumFavorites, options: fetchOptions),
                                   hideIfEmpty: true))

        // Smart albums.
        processPHAssetCollections((fetchResult: PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .albumRegular, options: fetchOptions),
                                   hideIfEmpty: true))

        // User-created albums.
        processPHCollections((fetchResult: PHAssetCollection.fetchTopLevelUserCollections(with: fetchOptions),
                              hideIfEmpty: true))

        return collections
    }
}

private extension PHAsset {
    var utType: UTType? {
        return (value(forKey: "uniformTypeIdentifier") as? String) // stringlint:ignore
            .map { UTType($0) }
    }
}
