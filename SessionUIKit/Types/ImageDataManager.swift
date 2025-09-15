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
    
    /// Max memory size for a decoded animation to be considered "small" enough to be fully cached
    private static let decodedAnimationCacheLimit: Int = 20 * 1024 * 1024 // 20 M
    private static let maxAnimatedImageDownscaleDimention: CGFloat = 4096
    
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
        
        if let data: ProcessedImageData = processedData, data.isCacheable {
            self.cache.setObject(data, forKey: identifier as NSString, cost: data.estimatedCacheCost)
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
                if
                    let existingThumbnail: UIImage = thumbnailManager.existingThumbnailImage(url: url, size: .large),
                    let existingThumbCgImage: CGImage = existingThumbnail.cgImage,
                    let decodingContext: CGContext = createDecodingContext(
                        width: existingThumbCgImage.width,
                        height: existingThumbCgImage.height
                    ),
                    let decodedImage: UIImage = predecode(cgImage: existingThumbCgImage, using: decodingContext)
                {
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
                
                guard
                    let cgImage: CGImage = try? generator.copyCGImage(at: time, actualTime: nil),
                    let decodingContext: CGContext = createDecodingContext(
                        width: cgImage.width,
                        height: cgImage.height
                    ),
                    let decodedImage: UIImage = predecode(cgImage: cgImage, using: decodingContext)
                else { return nil }
                
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
                if
                    let existingThumbnail: UIImage = thumbnailManager.existingThumbnailImage(url: url, size: .large),
                    let existingThumbCgImage: CGImage = existingThumbnail.cgImage,
                    let decodingContext: CGContext = createDecodingContext(
                        width: existingThumbCgImage.width,
                        height: existingThumbCgImage.height
                    ),
                    let decodedImage: UIImage = predecode(cgImage: existingThumbCgImage, using: decodingContext)
                {
                    let processedData: ProcessedImageData = ProcessedImageData(
                        type: .staticImage(decodedImage)
                    )
                    
                    return processedData
                }
                
                /// Otherwise we need to generate a new one
                let maxDimensionInPixels: CGFloat = await size.pixelDimension()
                let options: [CFString: Any] = [
                    kCGImageSourceShouldCache: false,
                    kCGImageSourceShouldCacheImmediately: false,
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxDimensionInPixels
                ]

                guard
                    let source: CGImageSource = dataSource.createImageSource(options: options),
                    let cgImage: CGImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
                    let decodingContext: CGContext = createDecodingContext(
                        width: cgImage.width,
                        height: cgImage.height
                    ),
                    let decodedImage: UIImage = predecode(cgImage: cgImage, using: decodingContext)
                else { return nil }
                
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
                
            /// Custom handle `placeholderIcon` generation
            case .placeholderIcon(let seed, let text, let size):
                let image: UIImage = PlaceholderIcon.generate(seed: seed, text: text, size: size)
                
                guard
                    let cgImage: CGImage = image.cgImage,
                    let decodingContext: CGContext = createDecodingContext(
                        width: cgImage.width,
                        height: cgImage.height
                    ),
                    let decodedImage: UIImage = predecode(cgImage: cgImage, using: decodingContext)
                else {
                    return ProcessedImageData(
                        type: .staticImage(image)
                    )
                }
                
                return ProcessedImageData(
                    type: .staticImage(decodedImage)
                )
                
            case .asyncSource(_, let sourceRetriever):
                guard let source: DataSource = await sourceRetriever() else { return nil }
                
                return await processSource(source)
                
            default: break
        }
        
        /// Otherwise load the data as either a static or animated image (do quick validation checks here - other checks
        /// require loading the image source anyway so don't bother to include them)
        guard
            let source: CGImageSource = dataSource.createImageSource(),
            let properties: [String: Any] = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
            let sourceWidth: Int = properties[kCGImagePropertyPixelWidth as String] as? Int,
            let sourceHeight: Int = properties[kCGImagePropertyPixelHeight as String] as? Int,
            sourceWidth > 0,
            sourceWidth < ImageDataManager.DataSource.maxValidDimension,
            sourceHeight > 0,
            sourceHeight < ImageDataManager.DataSource.maxValidDimension
        else { return nil }

        /// Get the number of frames in the image
        let count: Int = CGImageSourceGetCount(source)
        
        switch count {
            /// Invalid image
            case ..<1: return nil
                
            /// Static image
            case 1:
                /// Extract image orientation if present
                var orientation: UIImage.Orientation = .up
                
                if
                    let rawCgOrientation: UInt32 = properties[kCGImagePropertyOrientation as String] as? UInt32,
                    let cgOrientation: CGImagePropertyOrientation = CGImagePropertyOrientation(rawValue: rawCgOrientation)
                {
                    orientation = UIImage.Orientation(cgOrientation)
                }
                
                /// Try to decode the image direct from the `CGImage`
                let options: [CFString: Any] = [
                    kCGImageSourceShouldCache: false,
                    kCGImageSourceShouldCacheImmediately: false
                ]
                
                guard
                    let cgImage: CGImage = CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary),
                    let decodingContext = createDecodingContext(width: cgImage.width, height: cgImage.height),
                    let decodedImage: UIImage = predecode(cgImage: cgImage, using: decodingContext),
                    let decodedCgImage: CGImage = decodedImage.cgImage
                else { return nil }
                
                let finalImage: UIImage = UIImage(cgImage: decodedCgImage, scale: 1, orientation: orientation)
                
                return ProcessedImageData(
                    type: .staticImage(finalImage)
                )
                
            /// Animated Image
            default:
                /// Load the first frame
                guard
                    let firstFrameCgImage: CGImage = CGImageSourceCreateImageAtIndex(source, 0, nil),
                    let decodingContext: CGContext = createDecodingContext(
                        width: firstFrameCgImage.width,
                        height: firstFrameCgImage.height
                    ),
                    let decodedFirstFrameImage: UIImage = predecode(cgImage: firstFrameCgImage, using: decodingContext)
                else { return nil }
                
                /// If the memory usage of the full animation when is small enough then we should fully decode and cache the decoded
                /// result in memory, otherwise we don't want to cache the decoded data, but instead want to generate a buffered stream
                /// of frame data to start playing the animation as soon as possible whilst we continue to decode in the background
                let decodedMemoryCost: Int = (firstFrameCgImage.width * firstFrameCgImage.height * 4 * count)
                let durations: [TimeInterval] = getFrameDurations(from: source, count: count)
                
                guard decodedMemoryCost > decodedAnimationCacheLimit else {
                    var frames: [UIImage] = [decodedFirstFrameImage]
                    
                    for i in 1..<count {
                        autoreleasepool {
                            guard
                                let cgImage: CGImage = CGImageSourceCreateImageAtIndex(source, i, nil),
                                let decoded: UIImage = predecode(cgImage: cgImage, using: decodingContext)
                            else {
                                /// If a frame fails then use the previous frame as a fallback, otherwise fail as it was the first frame
                                /// which failed
                                guard let lastFrame: UIImage = frames.last else { return }
                                
                                frames.append(lastFrame)
                                return
                            }
                            frames.append(decoded)
                        }
                    }
                    
                    return ProcessedImageData(
                        type: .animatedImage(frames: frames, durations: durations)
                    )
                }
                
                /// Kick off out buffered frame loading logic for the animation
                let stream: AsyncStream<BufferedFrameStreamEvent> = AsyncStream { continuation in
                    let task = Task.detached(priority: .userInitiated) {
                        var (frameIndexesToBuffer, probeFrames) = await self.calculateHeuristicBuffer(
                            startIndex: 1,  /// We have already decoded the first frame so skip it
                            source: source,
                            durations: durations,
                            using: decodingContext
                        )
                        let lastBufferedFrameIndex: Int = (
                            frameIndexesToBuffer.max() ??
                            probeFrames.count
                        )
                        
                        /// Immediately yield the frames decoded when calculating the buffer size
                        for (index, frame) in probeFrames.enumerated() {
                            if Task.isCancelled { break }
                            
                            /// We `+ 1` because the first frame is always manually assigned
                            continuation.yield(.frame(index: index + 1, frame: frame))
                        }
                        
                        /// Clear out the `proveFrames` array so we don't use the extra memory
                        probeFrames.removeAll(keepingCapacity: false)
                        
                        /// Load in any additional buffer frames needed
                        for i in frameIndexesToBuffer {
                            guard !Task.isCancelled else {
                                continuation.finish()
                                return
                            }
                            
                            var decodedFrame: UIImage?
                            autoreleasepool {
                                decodedFrame = predecode(
                                    cgImage: CGImageSourceCreateImageAtIndex(source, i, nil),
                                    using: decodingContext
                                )
                            }
                            
                            if let frame: UIImage = decodedFrame {
                                continuation.yield(.frame(index: i, frame: frame))
                            }
                        }
                        
                        /// Now that we have buffered enough frames we can start the animation
                        if !Task.isCancelled {
                            continuation.yield(.readyToPlay)
                        }
                        
                        /// Start loading the remaining frames (`+ 1` as we want to start from the index after the last buffered index)
                        if lastBufferedFrameIndex < count {
                            for i in (lastBufferedFrameIndex + 1)..<count {
                                if Task.isCancelled { break }
                                
                                var decodedFrame: UIImage?
                                autoreleasepool {
                                    decodedFrame = predecode(
                                        cgImage: CGImageSourceCreateImageAtIndex(source, i, nil),
                                        using: decodingContext
                                    )
                                }
                                
                                if let frame: UIImage = decodedFrame {
                                    continuation.yield(.frame(index: i, frame: frame))
                                }
                            }
                        }
                        
                        /// Complete the stream
                        continuation.finish()
                    }
                    
                    continuation.onTermination = { @Sendable _ in
                        task.cancel()
                    }
                }
                
                return ProcessedImageData(
                    type: .bufferedAnimatedImage(
                        firstFrame: decodedFirstFrameImage,
                        durations: durations,
                        bufferedFrameStream: stream
                    )
                )
        }
    }
    
    private static func createDecodingContext(width: Int, height: Int) -> CGContext? {
        guard width > 0 && height > 0 else { return nil }
        
        return CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: (width * 4),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: (CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        )
    }
    
    private static func predecode(cgImage: CGImage?, using context: CGContext) -> UIImage? {
        guard let cgImage: CGImage = cgImage else { return nil }
        
        let width: Int = context.width
        let height: Int = context.height
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        return context.makeImage().map { UIImage(cgImage: $0) }
    }
    
    private static func getFrameDurations(from imageSource: CGImageSource, count: Int) -> [TimeInterval] {
        return (0..<count).reduce(into: []) { result, index in
            result.append(ImageDataManager.getFrameDuration(from: imageSource, at: index))
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
    
    private static func calculateHeuristicBuffer(
        startIndex: Int,
        source: CGImageSource,
        durations: [TimeInterval],
        using context: CGContext
    ) async -> (frameIndexesToBuffer: [Int], probeFrames: [UIImage]) {
        let probeFrameCount: Int = 5    /// Number of frames to decode in order to calculate the approx. time to load each frame
        let safetyMargin: Double = 2    /// Number of extra frames to be buffered just in case
        
        guard durations.count > (startIndex + probeFrameCount) else {
            return (Array(startIndex..<durations.count), [])
        }

        var probeFrames: [UIImage] = []
        let startTime: CFTimeInterval = CACurrentMediaTime()
        
        /// Need to skip the first image as it has already been decoded (so using it would throw off the heuristic)
        for i in startIndex..<(startIndex + probeFrameCount) {
            autoreleasepool {
                guard
                    let cgImage = CGImageSourceCreateImageAtIndex(source, i, nil),
                    let decoded: UIImage = predecode(cgImage: cgImage, using: context)
                else { return }
                
                probeFrames.append(decoded)
            }
        }
        
        let totalDecodeTimeForProbe: CFTimeInterval = (CACurrentMediaTime() - startTime)
        let avgDecodeTime: Double = (totalDecodeTimeForProbe / Double(probeFrameCount))
        let avgDisplayDuration: Double = (durations.prefix(probeFrameCount).reduce(0, +) / Double(probeFrameCount))
        
        /// Protect against divide by zero errors
        guard avgDisplayDuration > 0.001 else { return ([], probeFrames) }
        
        let decodeToDisplayRatio: Double = (avgDecodeTime / avgDisplayDuration)
        let calculatedBufferSize: Double = ceil(decodeToDisplayRatio) + safetyMargin
        let finalFramesToBuffer: Int = Int(max(Double(probeFrameCount), min(calculatedBufferSize, 60.0)))
        
        guard finalFramesToBuffer > (startIndex + probeFrameCount) else { return ([], probeFrames) }
        
        return (Array((startIndex + probeFrameCount)..<finalFramesToBuffer), probeFrames)
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
        case placeholderIcon(seed: String, text: String, size: CGFloat)
        case asyncSource(String, @Sendable () async -> DataSource?)
        
        public var identifier: String {
            switch self {
                case .url(let url): return url.absoluteString
                case .data(let identifier, _): return identifier
                case .image(let identifier, _): return identifier
                case .videoUrl(let url, _, _, _): return url.absoluteString
                case .urlThumbnail(let url, let size, _):
                    return "\(url.absoluteString)-\(size)"
                
                case .placeholderIcon(let seed, let text, let size):
                    let content: (intSeed: Int, initials: String) = PlaceholderIcon.content(
                        seed: seed,
                        text: text
                    )
                    
                    return "\(seed)-\(content.initials)-\(Int(floor(size)))"
                
                /// We will use the identifier from the loaded source for caching purposes
                case .asyncSource(let identifier, _): return identifier
            }
        }
        
        public var imageData: Data? {
            switch self {
                case .url(let url): return try? Data(contentsOf: url, options: [.dataReadingMapped])
                case .data(_, let data): return data
                case .image(_, let image): return image?.pngData()
                case .videoUrl: return nil
                case .urlThumbnail: return nil
                case .placeholderIcon: return nil
                case .asyncSource: return nil
            }
        }
        
        public var directImage: UIImage? {
            switch self {
                case .image(_, let image): return image
                default: return nil
            }
        }
        
        fileprivate func createImageSource(options: [CFString: Any]? = nil) -> CGImageSource? {
            let finalOptions: CFDictionary = (
                options ??
                [
                    kCGImageSourceShouldCache: false,
                    kCGImageSourceShouldCacheImmediately: false
                ]
            ) as CFDictionary
            
            switch self {
                case .url(let url): return CGImageSourceCreateWithURL(url as CFURL, finalOptions)
                case .data(_, let data): return CGImageSourceCreateWithData(data as CFData, finalOptions)
                case .urlThumbnail(let url, _, _): return CGImageSourceCreateWithURL(url as CFURL, finalOptions)
                    
                // These cases have special handling which doesn't use `createImageSource`
                case .image, .videoUrl, .placeholderIcon, .asyncSource: return nil
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
                    
                case (.placeholderIcon(let lhsSeed, let lhsText, let lhsSize), .placeholderIcon(let rhsSeed, let rhsText, let rhsSize)):
                    return (
                        lhsSeed == rhsSeed &&
                        lhsText == rhsText &&
                        lhsSize == rhsSize
                    )
                    
                case (.asyncSource(let lhsIdentifier, _), .asyncSource(let rhsIdentifier, _)):
                    return (lhsIdentifier == rhsIdentifier)
                    
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
                    
                case .placeholderIcon(let seed, let text, let size):
                    seed.hash(into: &hasher)
                    text.hash(into: &hasher)
                    size.hash(into: &hasher)
                    
                case .asyncSource(let identifier, _):
                    identifier.hash(into: &hasher)
            }
        }
    }
}

// MARK: - ImageDataManager.DataType

public extension ImageDataManager {
    enum DataType {
        case staticImage(UIImage)
        case animatedImage(frames: [UIImage], durations: [TimeInterval])
        case bufferedAnimatedImage(
            firstFrame: UIImage,
            durations: [TimeInterval],
            bufferedFrameStream: AsyncStream<BufferedFrameStreamEvent>
        )
    }
    
    enum BufferedFrameStreamEvent {
        case frame(index: Int, frame: UIImage)
        case readyToPlay
    }
}

// MARK: - ImageDataManager.isAnimatedImage

public extension ImageDataManager {
    static func isAnimatedImage(_ imageData: Data?) -> Bool {
        guard let data: Data = imageData, let imageSource = CGImageSourceCreateWithData(data as CFData, nil) else {
            return false
        }
        let frameCount = CGImageSourceGetCount(imageSource)
        return frameCount > 1
    }
}

// MARK: - ImageDataManager.ProcessedImageData

public extension ImageDataManager {
    class ProcessedImageData: @unchecked Sendable {
        public let type: DataType
        public let frameCount: Int
        public let estimatedCacheCost: Int
        
        public var isCacheable: Bool {
            switch type {
                case .staticImage, .animatedImage: return true
                case .bufferedAnimatedImage: return false
            }
        }
        
        init(type: DataType) {
            self.type = type
            
            switch type {
                case .staticImage(let image):
                    frameCount = 1
                    estimatedCacheCost = ProcessedImageData.calculateCost(for: [image])
                    
                case .animatedImage(let frames, _):
                    frameCount = frames.count
                    estimatedCacheCost = ProcessedImageData.calculateCost(for: frames)
                    
                case .bufferedAnimatedImage(_, let durations, _):
                    frameCount = durations.count
                    estimatedCacheCost = 0
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
    /// We need to ensure that the image size is "reasonable", otherwise trying to load it could cause out-of-memory crashes
    static let maxValidDimension: Int = 1 << 18 // 262,144 pixels
    
    @MainActor
    var sizeFromMetadata: CGSize? {
        /// There are a number of types which have fixed sizes, in those cases we should return the target size rather than try to
        /// read it from data so we doncan avoid processing
        switch self {
            case .image(_, let image):
                guard let image: UIImage = image else { break }
                
                return image.size
                
            case .urlThumbnail(_, let size, _):
                let dimension: CGFloat = size.pixelDimension()
                return CGSize(width: dimension, height: dimension)
                
            case .placeholderIcon(_, _, let size): return CGSize(width: size, height: size)
                
            case .url, .data, .videoUrl, .asyncSource: break
        }
        
        /// Since we don't have a direct size, try to extract it from the data
        guard
            let source: CGImageSource = createImageSource(),
            let properties: [String: Any] = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
            let sourceWidth: Int = properties[kCGImagePropertyPixelWidth as String] as? Int,
            let sourceHeight: Int = properties[kCGImagePropertyPixelHeight as String] as? Int,
            sourceWidth > 0,
            sourceWidth < ImageDataManager.DataSource.maxValidDimension,
            sourceHeight > 0,
            sourceHeight < ImageDataManager.DataSource.maxValidDimension
        else { return nil }
        
        return CGSize(width: sourceWidth, height: sourceHeight)
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
