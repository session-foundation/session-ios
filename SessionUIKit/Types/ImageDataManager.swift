// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import AVFoundation
import ImageIO

public actor ImageDataManager: ImageDataManagerType {
    private let processingQueue: DispatchQueue = DispatchQueue(
        label: "com.session.animatedimage.processing",  // stringlint:ignore
        qos: .userInitiated,
        attributes: .concurrent
    )
    
    /// `NSCache` has more nuanced memory management systems than just listening for `didReceiveMemoryWarningNotification`
    /// and can clear out values gradually, it can also remove items based on their "cost" so is better suited than our custom `LRUCache`
    private let cache: NSCache<NSString, ProcessedImageData> = {
        let result: NSCache<NSString, ProcessedImageData> = NSCache()
        result.totalCostLimit = 200 * 1024 * 1024 // Max 200MB of image data
        
        return result
    }()
    private var activeLoadTasks: [String: Task<ProcessedImageData?, Never>] = [:]
    
    // MARK: - Initialization
    
    public init() {}
    
    // MARK: - Functions
    
    @discardableResult public func load(_ source: DataSource) async -> ProcessedImageData? {
        let identifier: String = source.identifier
        
        if let cachedData: ProcessedImageData = cache.object(forKey: identifier as NSString) {
            return cachedData
        }
        
        if let existingTask: Task<ProcessedImageData?, Never> = activeLoadTasks[identifier] {
            return await existingTask.value
        }
        
        /// Kick off a new processing task in the background
        let newTask: Task<ProcessedImageData?, Never> = Task.detached(priority: .userInitiated) {
            await ImageDataManager.processSource(source)
        }
        activeLoadTasks[identifier] = newTask
        
        /// Wait for the result then cache and return it
        let processedData: ProcessedImageData? = await newTask.value
        
        if let data: ProcessedImageData = processedData {
            self.cache.setObject(data, forKey: identifier as NSString, cost: data.estimatedCost)
        }
        
        self.activeLoadTasks[identifier] = nil
        return processedData
    }
    
    nonisolated public func load(
        _ source: ImageDataManager.DataSource,
        onComplete: @escaping (ImageDataManager.ProcessedImageData?) -> Void
    ) {
        Task { [weak self] in
            let result: ImageDataManager.ProcessedImageData? = await self?.load(source)
            
            await MainActor.run {
                onComplete(result)
            }
        }
    }
    
    public func cachedImage(identifier: String) async -> ProcessedImageData? {
        return cache.object(forKey: identifier as NSString)
    }
    
    public func removeImage(identifier: String) async {
        cache.removeObject(forKey: identifier as NSString)
    }
    
    public func clearCache() async {
        cache.removeAllObjects()
    }
    
    // MARK: - Internal Functions

    private static func processSource(_ dataSource: DataSource) async -> ProcessedImageData? {
        switch dataSource {
            /// If we were given a direct `UIImage` value then use it
            case .image(_, let maybeImage):
                guard let image: UIImage = maybeImage else { return nil }
                
                return ProcessedImageData(
                    type: .staticImage(image)
                )
            
            /// Custom handle `videoUrl` values since it requires thumbnail generation
            case .videoUrl(let url, let mimeType, let sourceFilename, let thumbnailManager):
                /// If we had already generated a thumbnail then use that
                if let existingThumbnail: UIImage = thumbnailManager.existingThumbnailImage(url: url, size: .large) {
                    let decodedImage: UIImage = (existingThumbnail.predecodedImage() ?? existingThumbnail)
                    let processedData: ProcessedImageData = ProcessedImageData(
                        type: .staticImage(decodedImage)
                    )
                    
                    return processedData
                }
                
                /// Otherwise we need to generate a new one
                let assetInfo: (asset: AVURLAsset, cleanup: () -> Void)? = SNUIKit.asset(
                    for: url.path,
                    mimeType: mimeType,
                    sourceFilename: sourceFilename
                )
                
                guard
                    let asset: AVURLAsset = assetInfo?.asset,
                    asset.isValidVideo
                else { return nil }
                
                let time: CMTime = CMTimeMake(value: 1, timescale: 60)
                let generator: AVAssetImageGenerator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                
                guard let cgImage: CGImage = try? generator.copyCGImage(at: time, actualTime: nil) else {
                    return nil
                }
                
                let image: UIImage = UIImage(cgImage: cgImage)
                let decodedImage: UIImage = (image.predecodedImage() ?? image)
                let processedData: ProcessedImageData = ProcessedImageData(
                    type: .staticImage(decodedImage)
                )
                assetInfo?.cleanup()
                
                /// Since we generated a new thumbnail we should save it to disk
                saveThumbnailToDisk(
                    image: decodedImage,
                    url: url,
                    size: .large,
                    thumbnailManager: thumbnailManager
                )
                
                return processedData
                
            /// Custom handle `urlThumbnail` generation
            case .urlThumbnail(let url, let size, let thumbnailManager):
                /// If we had already generated a thumbnail then use that
                if let existingThumbnail: UIImage = thumbnailManager.existingThumbnailImage(url: url, size: .large) {
                    let decodedImage: UIImage = (existingThumbnail.predecodedImage() ?? existingThumbnail)
                    let processedData: ProcessedImageData = ProcessedImageData(
                        type: .staticImage(decodedImage)
                    )
                    
                    return processedData
                }
                
                /// Otherwise we need to generate a new one
                let maxDimensionInPixels: CGFloat = await size.pixelDimension()
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxDimensionInPixels
                ]

                guard
                    let format: SUIKImageFormat = dataSource.dataForGuessingImageFormat?.suiKitGuessedImageFormat,
                    format != .unknown,
                    let imageSource: CGImageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
                    let thumbnail: CGImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary)
                else { return nil }
                
                let image: UIImage = UIImage(cgImage: thumbnail)
                let decodedImage: UIImage = (image.predecodedImage() ?? image)
                
                /// Since we generated a new thumbnail we should save it to disk
                saveThumbnailToDisk(
                    image: decodedImage,
                    url: url,
                    size: size,
                    thumbnailManager: thumbnailManager
                )
                
                return ProcessedImageData(
                    type: .staticImage(decodedImage)
                )
                
            case .closureThumbnail(_, _, let imageRetrier):
                guard let image: UIImage = await imageRetrier() else { return nil }
                
                /// Since there is likely custom (external) logic used to retrieve this thumbnail we don't save it to disk as there
                /// is no way to know if it _should_ change between generations/launches or not
                let decodedImage: UIImage = (image.predecodedImage() ?? image)
                
                return ProcessedImageData(
                    type: .staticImage(decodedImage)
                )
                
            /// Custom handle `placeholderIcon` generation
            case .placeholderIcon(let seed, let text, let size):
                let image: UIImage = PlaceholderIcon.generate(seed: seed, text: text, size: size)
                let decodedImage: UIImage = (image.predecodedImage() ?? image)
                
                return ProcessedImageData(
                    type: .staticImage(decodedImage)
                )
                
            default: break
        }
        
        /// Otherwise load the data as either a static or animated image (do quick validation checks here - other checks
        /// require loading the image source anyway so don't bother to include them)
        guard
            let imageData: Data = dataSource.imageData,
            let imageFormat: SUIKImageFormat = imageData.suiKitGuessedImageFormat.nullIfUnknown,
            (imageFormat != .gif || imageData.suiKitHasValidGifSize),
            let source: CGImageSource = CGImageSourceCreateWithData(imageData as CFData, nil),
            CGImageSourceGetCount(source) > 0
        else { return nil }
        
        let count: Int = CGImageSourceGetCount(source)
        
        switch count {
            /// Invalid image
            case ..<1: return nil
                
            /// Static image
            case 1:
                guard let cgImage: CGImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                    return nil
                }
                
                /// Extract image orientation if present
                var orientation: UIImage.Orientation = .up
                
                if
                    let imageProperties: [CFString: Any] = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                    let rawCgOrientation: UInt32 = imageProperties[kCGImagePropertyOrientation] as? UInt32,
                    let cgOrientation: CGImagePropertyOrientation = CGImagePropertyOrientation(rawValue: rawCgOrientation)
                {
                    orientation = UIImage.Orientation(cgOrientation)
                }
                
                let image: UIImage = UIImage(cgImage: cgImage, scale: 1, orientation: orientation)
                let decodedImage: UIImage = (image.predecodedImage() ?? image)
                
                return ProcessedImageData(
                    type: .staticImage(decodedImage)
                )
                
            /// Animated Image
            default:
                var framesArray: [UIImage] = []
                var durationsArray: [TimeInterval] = []
                
                for i in 0..<count {
                    guard let cgImage: CGImage = CGImageSourceCreateImageAtIndex(source, i, nil) else {
                        /// If a frame fails then use the previous frame as a fallback, otherwise fail as it was the first frame
                        /// which failed
                        guard
                            let lastFrame: UIImage = framesArray.last,
                            let lastDuration: TimeInterval = durationsArray.last
                        else { return nil }
                        
                        framesArray.append(lastFrame)
                        durationsArray.append(lastDuration)
                        continue
                    }
                    
                    let image: UIImage = UIImage(cgImage: cgImage)
                    let decodedImage: UIImage = (image.predecodedImage() ?? image)
                    let duration: TimeInterval = ImageDataManager.getFrameDuration(from: source, at: i)
                    
                    framesArray.append(decodedImage)
                    durationsArray.append(duration)
                }
                
                guard !framesArray.isEmpty else { return nil }
                
                return ProcessedImageData(
                    type: .animatedImage(
                        frames: framesArray,
                        frameDurations: durationsArray
                    )
                )
        }
    }
    
    private static func getFrameDuration(from source: CGImageSource, at index: Int) -> TimeInterval {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any] else {
            return 0.1
        }

        /// Try to process it as a GIF
        if let gifProps = properties[kCGImagePropertyGIFDictionary as String] as? [String: Any] {
            if
                let unclampedDelayTime = gifProps[kCGImagePropertyGIFUnclampedDelayTime as String] as? Double,
                unclampedDelayTime > 0
            {
                return unclampedDelayTime
            }
            
            if
                let delayTime = gifProps[kCGImagePropertyGIFDelayTime as String] as? Double,
                delayTime > 0
            {
                return delayTime
            }
        }
        
        /// Try to process it as an APNG
        if let pngProps = properties[kCGImagePropertyPNGDictionary as String] as? [String: Any] {
             if
                let delayTime = pngProps[kCGImagePropertyAPNGDelayTime as String] as? Double,
                delayTime > 0
            {
                return delayTime
            }
        }
        
        /// Try to process it as a WebP
        if
            let webpProps = properties[kCGImagePropertyWebPDictionary as String] as? [String: Any],
            let delayTime = webpProps[kCGImagePropertyWebPDelayTime as String] as? Double,
            delayTime > 0
        {
            return delayTime
        }
        
        return 0.1  /// Fallback
    }
    
    private static func saveThumbnailToDisk(
        image: UIImage,
        url: URL,
        size: ImageDataManager.ThumbnailSize,
        thumbnailManager: ThumbnailManager
    ) {
        /// Don't want to block updating the UI so detatch this task
        Task.detached(priority: .background) {
            guard let data: Data = image.jpegData(compressionQuality: 0.85) else { return }
            
            thumbnailManager.saveThumbnail(data: data, size: size, url: url)
        }
    }
}

// MARK: - ImageDataManager.DataSource

public extension ImageDataManager {
    enum DataSource: Sendable, Equatable, Hashable {
        case url(URL)
        case data(String, Data)
        case image(String, UIImage?)
        case videoUrl(URL, String, String?, ThumbnailManager)
        case urlThumbnail(URL, ImageDataManager.ThumbnailSize, ThumbnailManager)
        case closureThumbnail(String, ImageDataManager.ThumbnailSize, @Sendable () async -> UIImage?)
        case placeholderIcon(seed: String, text: String, size: CGFloat)
        
        public var identifier: String {
            switch self {
                case .url(let url): return url.absoluteString
                case .data(let identifier, _): return identifier
                case .image(let identifier, _): return identifier
                case .videoUrl(let url, _, _, _): return url.absoluteString
                case .urlThumbnail(let url, let size, _):
                    return "\(url.absoluteString)-\(size)"
                
                case .closureThumbnail(let identifier, let size, _):
                    return "\(identifier)-\(size)"
                
                case .placeholderIcon(let seed, let text, let size):
                    let content: (intSeed: Int, initials: String) = PlaceholderIcon.content(
                        seed: seed,
                        text: text
                    )
                    
                    return "\(seed)-\(content.initials)-\(Int(floor(size)))"
            }
        }
        
        public var imageData: Data? {
            switch self {
                case .url(let url): return try? Data(contentsOf: url, options: [.dataReadingMapped])
                case .data(_, let data): return data
                case .image(_, let image): return image?.pngData()
                case .videoUrl: return nil
                case .urlThumbnail: return nil
                case .closureThumbnail: return nil
                case .placeholderIcon: return nil
            }
        }
        
        public var dataForGuessingImageFormat: Data? {
            switch self {
                case .url(let url), .urlThumbnail(let url, _, _):
                    guard let fileHandle: FileHandle = try? FileHandle(forReadingFrom: url) else {
                        return nil
                    }
                    
                    defer { fileHandle.closeFile() }
                    return fileHandle.readData(ofLength: 12)
                    
                case .data(_, let data): return data
                case .image, .videoUrl, .closureThumbnail, .placeholderIcon: return nil
            }
        }
        
        public var directImage: UIImage? {
            switch self {
                case .image(_, let image): return image
                default: return nil
            }
        }
        
        public static func == (lhs: DataSource, rhs: DataSource) -> Bool {
            switch (lhs, rhs) {
                case (.url(let lhsUrl), .url(let rhsUrl)): return (lhsUrl == rhsUrl)
                case (.data(let lhsIdentifier, let lhsData), .data(let rhsIdentifier, let rhsData)):
                    return (
                        lhsIdentifier == rhsIdentifier &&
                        lhsData == rhsData
                    )
                case (.image(let lhsIdentifier, _), .image(let rhsIdentifier, _)):
                    /// `UIImage` is not _really_ equatable so we need to use a separate identifier to use instead
                    return (lhsIdentifier == rhsIdentifier)
                    
                case (.videoUrl(let lhsUrl, let lhsMimeType, let lhsSourceFilename, _), .videoUrl(let rhsUrl, let rhsMimeType, let rhsSourceFilename, _)):
                    return (
                        lhsUrl == rhsUrl &&
                        lhsMimeType == rhsMimeType &&
                        lhsSourceFilename == rhsSourceFilename
                    )
                    
                case (.urlThumbnail(let lhsUrl, let lhsSize, _), .urlThumbnail(let rhsUrl, let rhsSize, _)):
                    return (
                        lhsUrl == rhsUrl &&
                        lhsSize == rhsSize
                    )
                    
                case (.closureThumbnail(let lhsIdentifier, let lhsSize, _), .closureThumbnail(let rhsIdentifier, let rhsSize, _)):
                    return (
                        lhsIdentifier == rhsIdentifier &&
                        lhsSize == rhsSize
                    )
                    
                case (.placeholderIcon(let lhsSeed, let lhsText, let lhsSize), .placeholderIcon(let rhsSeed, let rhsText, let rhsSize)):
                    return (
                        lhsSeed == rhsSeed &&
                        lhsText == rhsText &&
                        lhsSize == rhsSize
                    )
                    
                default: return false
            }
        }
        
        public func hash(into hasher: inout Hasher) {
            switch self {
                case .url(let url): url.hash(into: &hasher)
                case .data(let identifier, let data):
                    identifier.hash(into: &hasher)
                    data.hash(into: &hasher)
                    
                case .image(let identifier, _):
                    /// `UIImage` is not actually hashable so we need to provide a separate identifier to use instead
                    identifier.hash(into: &hasher)
                    
                case .videoUrl(let url, let mimeType, let sourceFilename, _):
                    url.hash(into: &hasher)
                    mimeType.hash(into: &hasher)
                    sourceFilename.hash(into: &hasher)
                    
                case .urlThumbnail(let url, let size, _):
                    url.hash(into: &hasher)
                    size.hash(into: &hasher)
                    
                case .closureThumbnail(let identifier, let size, _):
                    identifier.hash(into: &hasher)
                    size.hash(into: &hasher)
                    
                case .placeholderIcon(let seed, let text, let size):
                    seed.hash(into: &hasher)
                    text.hash(into: &hasher)
                    size.hash(into: &hasher)
            }
        }
    }
}

// MARK: - ImageDataManager.DataType

public extension ImageDataManager {
    enum DataType {
        case staticImage(UIImage)
        case animatedImage(frames: [UIImage], frameDurations: [TimeInterval])
    }
}

// MARK: - ImageDataManager.ProcessedImageData

public extension ImageDataManager {
    class ProcessedImageData: @unchecked Sendable {
        public let type: DataType
        public let frameCount: Int
        public let estimatedCost: Int
        
        init(type: DataType) {
            self.type = type
            
            switch type {
                case .staticImage(let image):
                    frameCount = 1
                    estimatedCost = ProcessedImageData.calculateCost(for: [image])
                    
                case .animatedImage(let frames, _):
                    frameCount = frames.count
                    estimatedCost = ProcessedImageData.calculateCost(for: frames)
            }
        }
        
        static func calculateCost(for images: [UIImage]) -> Int {
            return images.reduce(0) { totalCost, image in
                guard let cgImage: CGImage = image.cgImage else { return totalCost }
                
                let bytesPerPixel: Int = (cgImage.bitsPerPixel / 8)
                let imagePixels: Int = (cgImage.width * cgImage.height)
                
                return totalCost + (imagePixels * (bytesPerPixel > 0 ? bytesPerPixel : 4))
            }
        }
    }
}

// MARK: - Convenience

/// Needed for `actor` usage (ie. assume safe access)
extension UIImage: @unchecked Sendable {}

extension UIImage {
    /// When loading an image the OS doesn't immediately decompress the entire image in order to be efficient but since that
    /// decompressing could happen on the main thread it would defeat the purpose of our background processing potentially
    /// re-introducing the jitteriness this class was designed to resolve, so instead this function will decompress the image directly
    func predecodedImage() -> UIImage? {
        guard let cgImage = self.cgImage else { return self }
        
        let width: Int = cgImage.width
        let height: Int = cgImage.height
        
        /// Avoid `CGBitmapContextCreate` error with 0 dimension
        guard width > 0 && height > 0 else { return self }
        
        let colorSpace: CGColorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo: UInt32 = (
            CGImageAlphaInfo.premultipliedFirst.rawValue |
            CGBitmapInfo.byteOrder32Little.rawValue
        )

        guard
            let context: CGContext = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: (width * 4),
                space: colorSpace,
                bitmapInfo: bitmapInfo
            )
        else { return self }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let drawnImage: CGImage = context.makeImage() else { return self }
        
        return UIImage(cgImage: drawnImage, scale: self.scale, orientation: self.imageOrientation)
    }
}

extension AVAsset {
    var isValidVideo: Bool {
        var maxTrackSize = CGSize.zero
        
        for track: AVAssetTrack in tracks(withMediaType: .video) {
            let trackSize: CGSize = track.naturalSize
            maxTrackSize.width = max(maxTrackSize.width, trackSize.width)
            maxTrackSize.height = max(maxTrackSize.height, trackSize.height)
        }
        
        return (
            maxTrackSize.width >= 1 &&
            maxTrackSize.height >= 1 &&
            maxTrackSize.width < (3 * 1024) &&
            maxTrackSize.height < (3 * 1024)
        )
    }
}

public extension ImageDataManager.DataSource {
    @MainActor
    var sizeFromMetadata: CGSize? {
        /// There are a number of types which have fixed sizes, in those cases we should return the target size rather than try to
        /// read it from data so we doncan avoid processing
        switch self {
            case .image(_, let image):
                guard let image: UIImage = image else { break }
                
                return image.size
                
            case .urlThumbnail(_, let size, _), .closureThumbnail(_, let size, _):
                let dimension: CGFloat = size.pixelDimension()
                return CGSize(width: dimension, height: dimension)
                
            case .placeholderIcon(_, _, let size): return CGSize(width: size, height: size)
                
            case .url, .data, .videoUrl: break
        }
        
        /// Since we don't have a direct size, try to extract it from the data
        guard
            let imageData: Data = imageData,
            let imageFormat: SUIKImageFormat = imageData.suiKitGuessedImageFormat.nullIfUnknown
        else { return nil }
        
        /// We can extract the size of a `GIF` directly so do that
        if imageFormat == .gif, let gifSize: CGSize = imageData.suiKitGifSize {
            guard gifSize.suiKitIsValidGifSize else { return nil }
            
            return gifSize
        }
        
        guard
            let source: CGImageSource = CGImageSourceCreateWithData(imageData as CFData, nil),
            CGImageSourceGetCount(source) > 0,
            let imageProperties: [CFString: Any] = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let pixelWidth = imageProperties[kCGImagePropertyPixelWidth] as? Int,
            let pixelHeight = imageProperties[kCGImagePropertyPixelHeight] as? Int,
            pixelWidth > 0,
            pixelHeight > 0
        else { return nil }
        
        return CGSize(width: pixelWidth, height: pixelHeight)
    }
}

// MARK: - ImageDataManager.ThumbnailSize

public extension ImageDataManager {
    enum ThumbnailSize: String, Sendable {
        case small
        case medium
        case large
        
        @MainActor public func pixelDimension() -> CGFloat {
            let scale: CGFloat = UIScreen.main.scale
            
            switch self {
                case .small: return floor(200 * scale)
                case .medium: return floor(450 * scale)
                case .large:
                    /// This size is large enough to render full screen
                    let screenSizePoints: CGSize = UIScreen.main.bounds.size
                    
                    return floor(max(screenSizePoints.width, screenSizePoints.height) * scale)
            }
        }
    }
}

// MARK: - ImageDataManagerType

public protocol ImageDataManagerType {
    @discardableResult func load(_ source: ImageDataManager.DataSource) async -> ImageDataManager.ProcessedImageData?
    nonisolated func load(
        _ source: ImageDataManager.DataSource,
        onComplete: @escaping (ImageDataManager.ProcessedImageData?) -> Void
    )
    
    func cachedImage(identifier: String) async -> ImageDataManager.ProcessedImageData?
    func removeImage(identifier: String) async
    func clearCache() async
}

// MARK: - ThumbnailManager

public protocol ThumbnailManager: Sendable {
    func existingThumbnailImage(url: URL, size: ImageDataManager.ThumbnailSize) -> UIImage?
    func saveThumbnail(data: Data, size: ImageDataManager.ThumbnailSize, url: URL)
}
