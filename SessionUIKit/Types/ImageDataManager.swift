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
    
    @discardableResult public func loadImageData(identifier: String, source: DataSource) async -> ProcessedImageData? {
        if let cachedData: ProcessedImageData = cache.object(forKey: identifier as NSString) {
            return cachedData
        }
        
        if let existingTask: Task<ProcessedImageData?, Never> = activeLoadTasks[identifier] {
            return await existingTask.value
        }

        let newTask: Task<ProcessedImageData?, Never> = Task {
            let processedData: ProcessedImageData? = await self.processSourceOnQueue(source)

            if let data: ProcessedImageData = processedData {
                self.cache.setObject(data, forKey: identifier as NSString, cost: data.estimatedCost)
            }
            
            self.activeLoadTasks[identifier] = nil
            return processedData
        }
        
        activeLoadTasks[identifier] = newTask
        return await newTask.value
    }
    
    public func cacheImage(_ image: UIImage, for identifier: String) async {
        let data: ProcessedImageData = ProcessedImageData(type: .staticImage(image))
        cache.setObject(data, forKey: identifier as NSString, cost: data.estimatedCost)
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

    private func processSourceOnQueue(_ dataSource: DataSource) async -> ProcessedImageData? {
        return await withCheckedContinuation { continuation in
            processingQueue.async {
                switch dataSource {
                    /// If we were given a direct `UIImage` value then use it
                    case .image(_, let maybeImage):
                        guard let image: UIImage = maybeImage else {
                            return continuation.resume(returning: nil)
                        }
                        
                        let processedData: ProcessedImageData = ProcessedImageData(
                            type: .staticImage(image)
                        )
                        continuation.resume(returning: processedData)
                        return
                    
                    /// Custom handle `videoUrl` values since it requires thumbnail generation
                    case .videoUrl(let url):
                        let asset: AVURLAsset = AVURLAsset(url: url, options: nil)
                        
                        guard asset.isValidVideo else { return continuation.resume(returning: nil) }
                        
                        let time: CMTime = CMTimeMake(value: 1, timescale: 60)
                        let generator: AVAssetImageGenerator = AVAssetImageGenerator(asset: asset)
                        generator.appliesPreferredTrackTransform = true
                        
                        guard
                            let cgImage: CGImage = try? generator.copyCGImage(at: time, actualTime: nil)
                        else { return continuation.resume(returning: nil) }
                        
                        let image: UIImage = UIImage(cgImage: cgImage)
                        let decodedImage: UIImage = (image.predecodedImage() ?? image)
                        let processedData: ProcessedImageData = ProcessedImageData(
                            type: .staticImage(decodedImage)
                        )
                        continuation.resume(returning: processedData)
                        return
                        
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
                else { return continuation.resume(returning: nil) }
                
                let count: Int = CGImageSourceGetCount(source)
                
                switch count {
                    /// Invalid image
                    case ..<1: return continuation.resume(returning: nil)
                        
                    /// Static image
                    case 1:
                        guard let cgImage: CGImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                            return continuation.resume(returning: nil)
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
                        let processedData: ProcessedImageData = ProcessedImageData(
                            type: .staticImage(decodedImage)
                        )
                        continuation.resume(returning: processedData)
                        return
                        
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
                                else { return continuation.resume(returning: nil) }
                                
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
                        
                        guard !framesArray.isEmpty else {
                            return continuation.resume(returning: nil)
                        }
                        
                        let animatedData: ProcessedImageData = ProcessedImageData(
                            type: .animatedImage(
                                frames: framesArray,
                                frameDurations: durationsArray
                            )
                        )
                        continuation.resume(returning: animatedData)
                }
            }
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
}

// MARK: - ImageDataManager.DataSource

public extension ImageDataManager {
    enum DataSource: Sendable, Equatable, Hashable {
        case url(URL)
        case data(Data)
        case image(String, UIImage?)
        case videoUrl(URL)
        case closure(@Sendable () -> Data?)
        
        public var imageData: Data? {
            switch self {
                case .url(let url): return try? Data(contentsOf: url, options: [.dataReadingMapped])
                case .data(let data): return data
                case .image(_, let image): return image?.pngData()
                case .videoUrl: return nil
                case .closure(let dataRetriever): return dataRetriever()
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
                case (.data(let lhsData), .data(let rhsData)): return (lhsData == rhsData)
                case (.image(let lhsIdentifier, _), .image(let rhsIdentifier, _)):
                    /// `UIImage` is not _really_ equatable so we need to use a separate identifier to use instead
                    return (lhsIdentifier == rhsIdentifier)
                    
                case (.videoUrl(let lhsUrl), .videoUrl(let rhsUrl)): return (lhsUrl == rhsUrl)
                case (.closure, .closure): return false
                default: return false
            }
        }
        
        public func hash(into hasher: inout Hasher) {
            switch self {
                case .url(let url): return url.hash(into: &hasher)
                case .data(let data): return data.hash(into: &hasher)
                case .image(let identifier, _):
                    /// `UIImage` is not actually hashable so we need to provide a separate identifier to use instead
                    return identifier.hash(into: &hasher)
                    
                case .videoUrl(let url): return url.hash(into: &hasher)
                case .closure: break
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
    var sizeFromMetadata: CGSize? {
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

// MARK: - ImageDataManagerType

public protocol ImageDataManagerType {
    @discardableResult func loadImageData(
        identifier: String,
        source: ImageDataManager.DataSource
    ) async -> ImageDataManager.ProcessedImageData?
    
    func cacheImage(_ image: UIImage, for identifier: String) async
    func cachedImage(identifier: String) async -> ImageDataManager.ProcessedImageData?
    func removeImage(identifier: String) async
    func clearCache() async
}
