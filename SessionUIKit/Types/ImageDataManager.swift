// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import Lucide
import AVFoundation
import ImageIO

public actor ImageDataManager: ImageDataManagerType {
    private let processingQueue: DispatchQueue = DispatchQueue(
        label: "com.session.animatedimage.processing",  // stringlint:ignore
        qos: .userInitiated,
        attributes: .concurrent
    )
    
    /// Max memory size for a decoded animation to be considered "small" enough to be fully cached
    private static let maxCachableSize: Int = 20 * 1024 * 1024 // 20 M
    private static let maxAnimatedImageDownscaleDimention: CGFloat = 4096
    
    /// `NSCache` has more nuanced memory management systems than just listening for `didReceiveMemoryWarningNotification`
    /// and can clear out values gradually, it can also remove items based on their "cost" so is better suited than our custom `LRUCache`
    private let cache: NSCache<NSString, FrameBuffer> = {
        let result: NSCache<NSString, FrameBuffer> = NSCache()
        result.totalCostLimit = 200 * 1024 * 1024 // Max 200MB of image data
        
        return result
    }()
    private var activeLoadTasks: [String: Task<FrameBuffer?, Never>] = [:]
    
    // MARK: - Initialization
    
    public init() {}
    
    // MARK: - Functions
    
    @discardableResult public func load(_ source: DataSource) async -> FrameBuffer? {
        let identifier: String = source.identifier
        
        if let cachedData: FrameBuffer = cache.object(forKey: identifier as NSString) {
            return cachedData
        }
        
        if let existingTask: Task<FrameBuffer?, Never> = activeLoadTasks[identifier] {
            return await existingTask.value
        }
        
        /// Kick off a new processing task in the background
        let newTask: Task<FrameBuffer?, Never> = Task.detached(priority: .userInitiated) {
            await ImageDataManager.processSource(source)
        }
        activeLoadTasks[identifier] = newTask
        
        /// Wait for the result then cache and return it
        let maybeBuffer: FrameBuffer? = await newTask.value
        
        if let buffer: FrameBuffer = maybeBuffer {
            self.cache.setObject(buffer, forKey: identifier as NSString, cost: buffer.estimatedCacheCost)
        }
        
        self.activeLoadTasks[identifier] = nil
        return maybeBuffer
    }
    
    @MainActor
    public func load(
        _ source: ImageDataManager.DataSource,
        onComplete: @MainActor @escaping (ImageDataManager.FrameBuffer?) -> Void
    ) {
        Task { [weak self] in
            let result: ImageDataManager.FrameBuffer? = await self?.load(source)
            
            await MainActor.run {
                onComplete(result)
            }
        }
    }
    
    public func cachedImage(identifier: String) async -> FrameBuffer? {
        return cache.object(forKey: identifier as NSString)
    }
    
    public func removeImage(identifier: String) async {
        cache.removeObject(forKey: identifier as NSString)
    }
    
    public func clearCache() async {
        cache.removeAllObjects()
    }
    
    // MARK: - Internal Functions

    private static func processSource(_ dataSource: DataSource) async -> FrameBuffer? {
        switch dataSource {
            case .icon(let icon, let size, let renderingMode):
                guard let image: UIImage = Lucide.image(icon: icon, size: size) else { return nil }
                
                return FrameBuffer(image: image.withRenderingMode(renderingMode))
                
            /// If we were given a direct `UIImage` value then use it
            case .image(_, let maybeImage):
                guard let image: UIImage = maybeImage else { return nil }
                
                return FrameBuffer(image: image)
            
            /// Custom handle `videoUrl` values since it requires thumbnail generation
            case .videoUrl(let url, let utType, let sourceFilename, let thumbnailManager):
                /// If we had already generated a thumbnail then use that
                if
                    let existingThumbnailSource: ImageDataManager.DataSource = thumbnailManager
                        .existingThumbnail(name: url.lastPathComponent, size: .large),
                    let source: CGImageSource = existingThumbnailSource.createImageSource(),
                    let existingThumbCgImage: CGImage = createCGImage(source, index: 0, maxDimensionInPixels: nil),
                    let decodingContext: CGContext = createDecodingContext(
                        width: existingThumbCgImage.width,
                        height: existingThumbCgImage.height
                    ),
                    let decodedImage: UIImage = predecode(cgImage: existingThumbCgImage, using: decodingContext)
                {
                    return FrameBuffer(image: decodedImage)
                }
                
                /// Otherwise we need to generate a new one
                guard
                    let assetInfo: (asset: AVURLAsset, isValidVideo: Bool, cleanup: () -> Void) = SNUIKit.assetInfo(
                        for: url.path,
                        utType: utType,
                        sourceFilename: sourceFilename
                    )
                else { return nil }
                defer { assetInfo.cleanup() }
                
                guard assetInfo.isValidVideo else { return nil }
                
                let time: CMTime = CMTimeMake(value: 1, timescale: 60)
                let generator: AVAssetImageGenerator = AVAssetImageGenerator(asset: assetInfo.asset)
                generator.appliesPreferredTrackTransform = true
                
                guard
                    let cgImage: CGImage = try? generator.copyCGImage(at: time, actualTime: nil),
                    let decodingContext: CGContext = createDecodingContext(
                        width: cgImage.width,
                        height: cgImage.height
                    ),
                    let decodedImage: UIImage = predecode(cgImage: cgImage, using: decodingContext)
                else { return nil }
                
                let result: FrameBuffer = FrameBuffer(image: decodedImage)
                
                /// Since we generated a new thumbnail we should save it to disk
                Task.detached(priority: .background) {
                    saveThumbnailToDisk(
                        name: url.lastPathComponent,
                        frames: [decodedImage],
                        durations: [],      /// Static image so no durations
                        hasAlpha: false,    /// Video can't have alpha
                        size: .large,
                        thumbnailManager: thumbnailManager
                    )
                }
                
                return result
                
            /// Custom handle `urlThumbnail` generation
            case .urlThumbnail(let url, let size, let thumbnailManager):
                let maxDimensionInPixels: CGFloat = size.pixelDimension()
                let flooredPixels: Int = Int(floor(maxDimensionInPixels))
                
                /// If we had already generated a thumbnail then use that
                if
                    let existingThumbnailSource: ImageDataManager.DataSource = thumbnailManager
                        .existingThumbnail(name: url.lastPathComponent, size: size),
                    let source: CGImageSource = existingThumbnailSource.createImageSource()
                {
                    return await createBuffer(
                        source,
                        orientation: .up,   /// Thumbnails will always have their orientation removed
                        sourceWidth: flooredPixels,
                        sourceHeight: flooredPixels
                    )
                }
                
                /// If not then check whether there would be any benefit in creating a thumbnail
                guard
                    let newThumbnailSource: CGImageSource = dataSource.createImageSource(),
                    let properties: [String: Any] = CGImageSourceCopyPropertiesAtIndex(newThumbnailSource, 0, nil) as? [String: Any],
                    let sourceWidth: Int = properties[kCGImagePropertyPixelWidth as String] as? Int,
                    let sourceHeight: Int = properties[kCGImagePropertyPixelHeight as String] as? Int,
                    sourceWidth > 0,
                    sourceHeight > 0
                else { return nil }
                
                /// If the source is smaller than the target thumbnail size then we should just return the target directly
                guard sourceWidth > flooredPixels || sourceHeight > flooredPixels else {
                    return await processSource(.url(url))
                }
                
                /// Otherwise, generate the thumbnail
                guard
                    let result: FrameBuffer = await createBuffer(
                        newThumbnailSource,
                        orientation: .up,   /// Thumbnails will always have their orientation removed
                        sourceWidth: sourceWidth,
                        sourceHeight: sourceHeight,
                        maxDimensionInPixels: maxDimensionInPixels,
                        customLoaderGenerator: {
                            /// If we had already generated a thumbnail then use that
                            if
                                let existingThumbnailSource: ImageDataManager.DataSource = thumbnailManager
                                    .existingThumbnail(name: url.lastPathComponent, size: size),
                                let source: CGImageSource = existingThumbnailSource.createImageSource()
                            {
                                let existingThumbnailBuffer: FrameBuffer? = await createBuffer(
                                    source,
                                    orientation: .up,   /// Thumbnails will always have their orientation removed
                                    sourceWidth: flooredPixels,
                                    sourceHeight: flooredPixels
                                )
                                
                                return await existingThumbnailBuffer?.generateLoadClosure?()
                            }
                            
                            return nil
                        }
                    )
                else { return nil }
                
                /// Since we generated a new thumbnail we should save it to disk (only do this if we created a new thumbnail)
                Task.detached(priority: .background) {
                    let allFrames: [UIImage] = await result.allFramesOnceLoaded()
                    
                    saveThumbnailToDisk(
                        name: url.lastPathComponent,
                        frames: allFrames,
                        durations: result.durations,
                        hasAlpha: (properties[kCGImagePropertyHasAlpha as String] as? Bool),
                        size: size,
                        thumbnailManager: thumbnailManager
                    )
                }
                
                return result
                
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
                else { return FrameBuffer(image: image) }
                
                return FrameBuffer(image: decodedImage)
                
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
        
        return await createBuffer(
            source,
            orientation: orientation(from: properties),
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight
        )
    }
    
    private static func orientation(from properties: [String: Any]) -> UIImage.Orientation {
        if
            let rawCgOrientation: UInt32 = properties[kCGImagePropertyOrientation as String] as? UInt32,
            let cgOrientation: CGImagePropertyOrientation = CGImagePropertyOrientation(rawValue: rawCgOrientation)
        {
            return UIImage.Orientation(cgOrientation)
        }
        
        return .up
    }
    
    private static func createBuffer(
        _ source: CGImageSource,
        orientation: UIImage.Orientation,
        sourceWidth: Int,
        sourceHeight: Int,
        maxDimensionInPixels: CGFloat? = nil,
        customLoaderGenerator: (() async -> AsyncLoadStream.Loader?)? = nil
    ) async -> FrameBuffer? {
        /// Get the number of frames in the image
        let count: Int = CGImageSourceGetCount(source)
        
        /// Invalid image
        guard count > 0 else { return nil }
        
        /// Load the first frame
        guard
            let firstFrameCgImage: CGImage = createCGImage(
                source,
                index: 0,
                maxDimensionInPixels: maxDimensionInPixels
            )
        else { return nil }
        
        /// The share extension has limited RAM (~120Mb on an iPhone X) and pre-decoding an image results in approximately `3x`
        /// the RAM usage of the standard lazy loading (as buffers need to be allocated and image data copied during the pre-decode),
        /// in order to avoid this we check if the estimated pre-decoded image RAM usage is smaller than `80%` of the currently
        /// available RAM and if not we just rely on lazy `UIImage` loading and the OS
        let hasEnoughMemoryToPreDecode: Bool = {
            #if targetEnvironment(simulator)
            /// On the simulator `os_proc_available_memory` seems to always return `0` so just assume we have enough memort
            return true
            #else
            let estimatedMemorySize: Int = (sourceWidth * sourceHeight * 4)
            let estimatedMemorySizeToLoad: Int = (estimatedMemorySize * 3)
            let currentAvailableMemory: Int = os_proc_available_memory()
            
            return (estimatedMemorySizeToLoad < Int(floor(CGFloat(currentAvailableMemory) * 0.8)))
            #endif
        }()
        
        guard hasEnoughMemoryToPreDecode else {
            return FrameBuffer(
                image: UIImage(cgImage: firstFrameCgImage, scale: 1, orientation: orientation)
            )
        }
        
        /// Otherwise we want to "predecode" the first (and other) frames while in the background to reduce the load on the UI thread
        guard
            let firstFrameContext: CGContext = createDecodingContext(
                width: firstFrameCgImage.width,
                height: firstFrameCgImage.height
            ),
            let decodedFirstFrameImage: UIImage = predecode(cgImage: firstFrameCgImage, using: firstFrameContext),
            let decodedCgImage: CGImage = decodedFirstFrameImage.cgImage
        else { return nil }
        
        /// Static image
        guard count > 1 else {
            return FrameBuffer(
                image: UIImage(cgImage: decodedCgImage, scale: 1, orientation: orientation)
            )
        }

        /// Animated Image
        let durations: [TimeInterval] = getFrameDurations(from: source, count: count)
        let standardLoaderGenerator: AsyncLoadStream.Loader = { stream, buffer in
            /// Since the `AsyncLoadStream.Loader` gets run in it's own task we need to create a context within the task
            guard
                let decodingContext: CGContext = createDecodingContext(
                    width: firstFrameCgImage.width,
                    height: firstFrameCgImage.height
                )
            else { return }
        
            var (frameIndexesToBuffer, probeFrames) = await self.calculateHeuristicBuffer(
                startIndex: 1,  /// We have already decoded the first frame so skip it
                source: source,
                durations: durations,
                maxDimensionInPixels: maxDimensionInPixels,
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
                let bufferIndex: Int = (index + 1)
                buffer.setFrame(frame, at: bufferIndex)
                await stream.send(.frameLoaded(index: bufferIndex))
            }
            
            /// Clear out the `proveFrames` array so we don't use the extra memory
            probeFrames.removeAll(keepingCapacity: false)
            
            /// Load in any additional buffer frames needed
            for i in frameIndexesToBuffer {
                guard !Task.isCancelled else {
                    await stream.cancel()
                    return
                }
                
                var decodedFrame: UIImage?
                autoreleasepool {
                    decodedFrame = predecode(
                        cgImage: createCGImage(
                            source,
                            index: i,
                            maxDimensionInPixels: maxDimensionInPixels
                        ),
                        using: decodingContext
                    )
                }
                
                if let frame: UIImage = decodedFrame {
                    buffer.setFrame(frame, at: i)
                    await stream.send(.frameLoaded(index: i))
                }
            }
            
            /// Now that we have buffered enough frames we can start the animation
            if !Task.isCancelled {
                await stream.send(.readyToAnimate)
            }
            
            /// Start loading the remaining frames (`+ 1` as we want to start from the index after the last buffered index)
            if lastBufferedFrameIndex < count {
                for i in (lastBufferedFrameIndex + 1)..<count {
                    if Task.isCancelled { break }
                    
                    var decodedFrame: UIImage?
                    autoreleasepool {
                        decodedFrame = predecode(
                            cgImage: createCGImage(
                                source,
                                index: i,
                                maxDimensionInPixels: maxDimensionInPixels
                            ),
                            using: decodingContext
                        )
                    }
                    
                    if let frame: UIImage = decodedFrame {
                        buffer.setFrame(frame, at: i)
                        await stream.send(.frameLoaded(index: i))
                    }
                }
            }
            
            /// Mark the `frameBuffer` as complete
            buffer.markComplete()
            
            /// Complete the stream
            await stream.send(.completed)
        }
        
        return FrameBuffer(
            firstFrame: decodedFirstFrameImage,
            durations: durations,
            shouldAutoPurgeIfEstimatedCostExceedsLimit: ImageDataManager.maxCachableSize,
            generateLoadClosure: { await customLoaderGenerator?() ?? standardLoaderGenerator }
        )
    }
    
    private static func createCGImage(
        _ source: CGImageSource,
        index: Int,
        maxDimensionInPixels: CGFloat?
    ) -> CGImage? {
        /// If we don't have a `maxDimension` then we should just load the full image
        guard let maxDimension: CGFloat = maxDimensionInPixels else {
            return CGImageSourceCreateImageAtIndex(source, index, SNUIKit.mediaDecoderDefaultImageOptions())
        }
        
        /// Otherwise we should create a thumbnail
        let options: CFDictionary? = SNUIKit.mediaDecoderDefaultThumbnailOptions(maxDimension: maxDimension)

        return CGImageSourceCreateThumbnailAtIndex(source, index, options)
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
        maxDimensionInPixels: CGFloat?,
        using context: CGContext
    ) async -> (frameIndexesToBuffer: [Int], probeFrames: [UIImage]) {
        let probeFrameCount: Int = 8    /// Number of frames to decode in order to calculate the approx. time to load each frame
        let safetyMargin: Double = 4    /// Number of extra frames to be buffered just in case
        
        guard durations.count > (startIndex + probeFrameCount) else {
            return (Array(startIndex..<durations.count), [])
        }

        var probeFrames: [UIImage] = []
        let startTime: CFTimeInterval = CACurrentMediaTime()
        
        /// Need to skip the first image as it has already been decoded (so using it would throw off the heuristic)
        for i in startIndex..<(startIndex + probeFrameCount) {
            autoreleasepool {
                guard
                    let cgImage = createCGImage(source, index: i, maxDimensionInPixels: maxDimensionInPixels),
                    let decoded: UIImage = predecode(cgImage: cgImage, using: context)
                else { return }
                
                probeFrames.append(decoded)
            }
        }
        
        let totalDecodeTimeForProbe: CFTimeInterval = (CACurrentMediaTime() - startTime)
        let avgDecodeTime: Double = (totalDecodeTimeForProbe / Double(probeFrameCount))
        let avgDisplayDuration: Double = (durations.dropFirst(startIndex).prefix(probeFrameCount).reduce(0, +) / Double(probeFrameCount))
        
        /// Protect against divide by zero errors
        guard avgDisplayDuration > 0.001 else { return ([], probeFrames) }
        
        let decodeToDisplayRatio: Double = (avgDecodeTime / avgDisplayDuration)
        let calculatedBufferSize: Double = ceil(decodeToDisplayRatio) + safetyMargin
        let finalFramesToBuffer: Int = Int(max(Double(probeFrameCount), min(calculatedBufferSize, 60.0)))
        
        guard finalFramesToBuffer > (startIndex + probeFrameCount) else { return ([], probeFrames) }
        
        return (Array((startIndex + probeFrameCount)..<finalFramesToBuffer), probeFrames)
    }

    private static func saveThumbnailToDisk(
        name: String,
        frames: [UIImage],
        durations: [TimeInterval],
        hasAlpha: Bool?,
        size: ImageDataManager.ThumbnailSize,
        thumbnailManager: ThumbnailManager
    ) {
        thumbnailManager.saveThumbnail(
            name: name,
            frames: frames,
            durations: durations,
            hasAlpha: hasAlpha,
            size: size
        )
    }
}

// MARK: - ImageDataManager.DataSource

public extension ImageDataManager {
    enum DataSource: Sendable, Equatable, Hashable {
        case url(URL)
        case data(String, Data)
        case icon(Lucide.Icon, size: CGFloat, renderingMode: UIImage.RenderingMode = .alwaysOriginal)
        case image(String, UIImage?)
        case videoUrl(URL, UTType, String?, ThumbnailManager)
        case urlThumbnail(URL, ImageDataManager.ThumbnailSize, ThumbnailManager)
        case placeholderIcon(seed: String, text: String, size: CGFloat)
        case asyncSource(String, @Sendable () async -> DataSource?)
        
        public var identifier: String {
            switch self {
                case .url(let url): return url.absoluteString
                case .data(let identifier, _): return identifier
                case .icon(let icon, let size, let renderingMode):
                    return "\(icon.rawValue)-\(Int(floor(size)))-\(renderingMode.rawValue)"
                
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
        
        public var contentExists: Bool {
            switch self {
                case .url(let url), .videoUrl(let url, _, _, _), .urlThumbnail(let url, _, _):
                    return FileManager.default.fileExists(atPath: url.path)
                    
                case .data(_, let data): return !data.isEmpty
                case .image(_, let image): return (image != nil)
                case .icon, .placeholderIcon: return true
                case .asyncSource: return true /// Need to assume it exists
            }
        }
        
        public func createImageSource() -> CGImageSource? {
            switch self {
                case .url(let url): return SNUIKit.mediaDecoderSource(for: url)
                case .data(_, let data): return SNUIKit.mediaDecoderSource(for: data)
                case .urlThumbnail(let url, _, _): return SNUIKit.mediaDecoderSource(for: url)
                    
                // These cases have special handling which doesn't use `createImageSource`
                case .icon, .image, .videoUrl, .placeholderIcon, .asyncSource: return nil
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
                    
                case (.icon(let lhsIcon, let lhsSize, let lhsRenderingMode), .icon(let rhsIcon, let rhsSize, let rhsRenderingMode)):
                    return (
                        lhsIcon == rhsIcon &&
                        lhsSize == rhsSize &&
                        lhsRenderingMode == rhsRenderingMode
                    )
                    
                case (.image(let lhsIdentifier, _), .image(let rhsIdentifier, _)):
                    /// `UIImage` is not _really_ equatable so we need to use a separate identifier to use instead
                    return (lhsIdentifier == rhsIdentifier)
                    
                case (.videoUrl(let lhsUrl, let lhsUTType, let lhsSourceFilename, _), .videoUrl(let rhsUrl, let rhsUTType, let rhsSourceFilename, _)):
                    return (
                        lhsUrl == rhsUrl &&
                        lhsUTType == rhsUTType &&
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
                    
                case .icon(let icon, let size, let renderingMode):
                    icon.hash(into: &hasher)
                    size.hash(into: &hasher)
                    renderingMode.hash(into: &hasher)
                    
                case .image(let identifier, _):
                    /// `UIImage` is not actually hashable so we need to provide a separate identifier to use instead
                    identifier.hash(into: &hasher)
                    
                case .videoUrl(let url, let utType, let sourceFilename, _):
                    url.hash(into: &hasher)
                    utType.hash(into: &hasher)
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

// MARK: - ImageDataManager.isAnimatedImage

public extension ImageDataManager {
    static func isAnimatedImage(_ source: ImageDataManager.DataSource?) -> Bool {
        guard let source, let imageSource: CGImageSource = source.createImageSource() else { return false }
        
        return (CGImageSourceGetCount(imageSource) > 1)
    }
}

// MARK: - ImageDataManager.FrameBuffer

public extension ImageDataManager {
    enum AsyncLoadEvent: Equatable {
        case frameLoaded(index: Int)
        case readyToAnimate
        case completed
    }
    
    final class FrameBuffer: @unchecked Sendable {
        fileprivate final class Box: @unchecked Sendable {
            var frameBuffer: FrameBuffer?
        }
        
        private let lock: NSLock = NSLock()
        public let frameCount: Int
        public let firstFrame: UIImage
        public let durations: [TimeInterval]
        public let estimatedCacheCost: Int
        public var stream: AsyncStream<ImageDataManager.AsyncLoadEvent> {
            loadIfNeeded()
            return asyncLoadStream.stream
        }
        
        public var isComplete: Bool {
            lock.lock()
            defer { lock.unlock() }
            
            return _isComplete
        }
        public var framesPurged: Bool {
            lock.lock()
            defer { lock.unlock() }
            
            return _framesPurged
        }
        
        fileprivate let generateLoadClosure: (() async -> AsyncLoadStream.Loader)?
        private let asyncLoadStream: AsyncLoadStream
        private let purgeable: Bool
        private var _isLoading: Bool = false
        private var _isComplete: Bool = false
        private var _framesPurged: Bool = false
        private var activeObservers: Set<UUID> = []
        private var otherFrames: [UIImage?]
        
        // MARK: - Initialization
        
        public init(image: UIImage) {
            self.frameCount = 1
            self.firstFrame = image
            self.durations = []
            self.estimatedCacheCost = FrameBuffer.calculateCost(
                forPixelSize: image.size,
                count: 1,
                bitsPerPixel: image.cgImage?.bitsPerPixel
            )
            self.generateLoadClosure = nil
            self.purgeable = false
            self.asyncLoadStream = .completed
            self._isComplete = true
            self.otherFrames = []
        }
        
        fileprivate init(
            firstFrame: UIImage,
            durations: [TimeInterval],
            shouldAutoPurgeIfEstimatedCostExceedsLimit cacheLimit: Int,
            generateLoadClosure: @escaping @Sendable () async -> AsyncLoadStream.Loader
        ) {
            let fullCost: Int = FrameBuffer.calculateCost(
                forPixelSize: firstFrame.size,
                count: durations.count,
                bitsPerPixel: firstFrame.cgImage?.bitsPerPixel
            )
            
            self.frameCount = durations.count
            self.firstFrame = firstFrame
            self.durations = durations
            self.purgeable = (fullCost > cacheLimit)
            self.otherFrames = Array(repeating: nil, count: max(0, (durations.count - 1)))
            self.generateLoadClosure = generateLoadClosure
            self.asyncLoadStream = AsyncLoadStream()
            
            /// For purgeable buffers we don't keep the full images in the cache (just the first frame) and we release the remaining
            /// frames once the final observers have stopped observing
            self.estimatedCacheCost = (!purgeable ?
                fullCost :
                FrameBuffer.calculateCost(
                    forPixelSize: firstFrame.size,
                    count: 1,
                    bitsPerPixel: firstFrame.cgImage?.bitsPerPixel
                )
            )
        }
        
        // MARK: - Functions
        
        public func getFrame(at index: Int) -> UIImage? {
            loadIfNeeded()
            
            if index == 0 {
                return firstFrame
            }
            
            lock.lock()
            defer { lock.unlock() }
            
            let otherIndex: Int = (index - 1)
            guard otherIndex >= 0, otherIndex < otherFrames.count else { return nil }
            
            return otherFrames[otherIndex]
        }
        
        // MARK: - Internal Functions
        
        fileprivate func setFrame(_ frame: UIImage, at index: Int) {
            lock.lock()
            defer { lock.unlock() }
            
            guard index > 0, index < (otherFrames.count + 1) else { return }
            
            otherFrames[index - 1] = frame
        }

        fileprivate func markComplete() {
            lock.lock()
            defer { lock.unlock() }
            
            _isComplete = true
            _isLoading = false
        }
        
        fileprivate func allFramesOnceLoaded() async -> [UIImage] {
            _ = await asyncLoadStream.stream.first(where: { $0 == .completed })
            
            return getAllLoadedFrames()
        }
        
        private func loadIfNeeded() {
            let needsLoad: Bool = {
                lock.lock()
                defer { lock.unlock() }
                
                return (
                    !_isLoading && (
                        _framesPurged ||
                        !_isComplete
                    )
                )
            }()
            
            guard needsLoad, let generateLoadClosure = generateLoadClosure else { return }
            
            /// Update the loading and purged states
            lock.lock()
            _isLoading = true
            _framesPurged = false
            lock.unlock()
            
            Task.detached { [weak self] in
                guard let self else { return }
                
                await asyncLoadStream.start(with: generateLoadClosure(), buffer: self)
            }
        }
        
        private func getAllLoadedFrames() -> [UIImage] {
            lock.lock()
            defer { lock.unlock() }
            
            return [firstFrame] + otherFrames.compactMap { $0 }
        }
        
        fileprivate func purgeIfNeeded() {
            guard purgeable else { return }
            
            lock.lock()
            defer { lock.unlock() }
            
            guard !_framesPurged else { return }
            
            /// Keep first frame, clear others
            otherFrames = Array(repeating: nil, count: otherFrames.count)
            _framesPurged = true
            _isComplete = false
        }
        
        private static func calculateCost(
            forPixelSize size: CGSize,
            count: Int,
            bitsPerPixel: Int?
        ) -> Int {
            /// Assume the standard 32 bits per pixel
            let imagePixels: Int = Int(size.width * size.height)
            let bytesPerPixel: Int = ((bitsPerPixel ?? 32) / 8)
            
            return (count * (imagePixels * bytesPerPixel))
        }
    }
}

// MARK: - Convenience

/// Needed for `actor` usage (ie. assume safe access)
extension UIImage: @unchecked Sendable {}

public extension ImageDataManager.DataSource {
    /// We need to ensure that the image size is "reasonable", otherwise trying to load it could cause out-of-memory crashes
    static let maxValidDimension: Int = 1 << 18 // 262,144 pixels
    
    /// There are a number of types which have fixed sizes, in those cases we should return the target size rather than try to
    /// read it from data on the disk
    var knownDisplaySize: CGSize? {
        switch self {
            case .icon(_, let size, _): return CGSize(width: size, height: size)
            case .image(_, let image):
                guard let image: UIImage = image else { return nil }
                
                return image.size
                
            case .urlThumbnail(_, let size, _):
                let dimension: CGFloat = size.pixelDimension()
                return CGSize(width: dimension, height: dimension)
                
            case .placeholderIcon(_, _, let size): return CGSize(width: size, height: size)
                
            case .url, .data, .videoUrl, .asyncSource: return nil
        }
    }
    
    /// There are a number of types which have fixed orientations, in those cases we should return the target orientation rather than try to
    /// read it from data on the disk
    var knownOrientation: UIImage.Orientation? {
        switch self {
            case .icon, .urlThumbnail, .placeholderIcon: return .up
            case .image(_, let image):
                guard let image: UIImage = image else { return nil }
                
                return image.imageOrientation
                
            case .url, .data, .videoUrl, .asyncSource: return nil
        }
    }
    
    /// Retrieve the display size and orientation of the content from the data itself
    ///
    /// **Note:** This should only be called if `knownDisplaySize` and/or `knownOrientation` returned `nil` (meaning we
    /// don't have an explicit value and need to load it from the data which may involve File I/O)
    func extractDisplayMetadataFromData() -> (displaySize: CGSize, orientation: UIImage.Orientation)? {
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
        
        /// Since we want the "display size" (ie. size after the orientation has been applied) we may need to rotate the resolution
        let orientation: UIImage.Orientation = ImageDataManager.orientation(from: properties)
        let displaySize: CGSize = {
            switch orientation {
                case .up, .upMirrored, .down, .downMirrored:
                    return CGSize(width: sourceWidth, height: sourceHeight)
                
                case .leftMirrored, .left, .rightMirrored, .right:
                    return CGSize(width: sourceHeight, height: sourceWidth)
                
                @unknown default: return CGSize(width: sourceWidth, height: sourceHeight)
            }
        }()
        
        return (displaySize, orientation)
    }
}

// MARK: - ImageDataManager.ThumbnailSize

public extension ImageDataManager {
    enum ThumbnailSize: String, Sendable {
        case small
        case medium
        case large
        
        public func pixelDimension() -> CGFloat {
            switch self {
                case .small: return floor(200 * InitialScreenConstants.scale)
                case .medium: return floor(450 * InitialScreenConstants.scale)
                    
                /// This size is large enough to render full screen
                case .large: return floor(InitialScreenConstants.maxDimension * InitialScreenConstants.scale)
            }
        }
    }
    
    enum InitialScreenConstants {
        /// Initial scale the screen had during launch (Fallback to `1` if `nil` which shouldn't really happen)
        static var scale: CGFloat = (SNUIKit.initialMainScreenScale ?? 1)
        
        /// Initial max dimension the screen had during launch (Fallback to `874` for the max resolution which is the iPhone 17 Pro
        /// height which shouldn't really happen)
        static var maxDimension: CGFloat = (SNUIKit.initialMainScreenMaxDimension ?? 874)
    }
}

// MARK: - ImageDataManagerType

public protocol ImageDataManagerType {
    @discardableResult func load(_ source: ImageDataManager.DataSource) async -> ImageDataManager.FrameBuffer?
    
    @MainActor
    func load(
        _ source: ImageDataManager.DataSource,
        onComplete: @MainActor @escaping (ImageDataManager.FrameBuffer?) -> Void
    )
    
    func cachedImage(identifier: String) async -> ImageDataManager.FrameBuffer?
    func removeImage(identifier: String) async
    func clearCache() async
}

// MARK: - ThumbnailManager

public protocol ThumbnailManager: Sendable {
    func existingThumbnail(name: String, size: ImageDataManager.ThumbnailSize) -> ImageDataManager.DataSource?
    func saveThumbnail(
        name: String,
        frames: [UIImage],
        durations: [TimeInterval],
        hasAlpha: Bool?,
        size: ImageDataManager.ThumbnailSize
    )
}

// MARK: AsyncLoadStream

public actor AsyncLoadStream {
    public typealias Loader = @Sendable (AsyncLoadStream, ImageDataManager.FrameBuffer) async -> Void
    
    fileprivate static let completed: AsyncLoadStream = AsyncLoadStream(isFinished: true)
    
    private var continuations: [UUID: AsyncStream<ImageDataManager.AsyncLoadEvent>.Continuation] = [:]
    private var lastEvent: ImageDataManager.AsyncLoadEvent?
    private var isFinished: Bool = false
    
    /// This being `nonisolated(unsafe)` is ok because it only gets set in `init` or accessed from isolated methods (`send`
    /// and `cancel`)
    private nonisolated(unsafe) var loadingTask: Task<Void, Never>?
    private weak var frameBuffer: ImageDataManager.FrameBuffer?
    
    public nonisolated var stream: AsyncStream<ImageDataManager.AsyncLoadEvent> {
        AsyncStream { continuation in
            let id = UUID()
            Task {
                guard await !self.isFinished else {
                    if let lastEvent = await self.lastEvent {
                        continuation.yield(lastEvent)
                    }
                    
                    /// Don't finish, add to continuations to keep the observer registered and the `FrameBuffer` alive (in case
                    /// it's purgeable)
                    await self.addContinuation(id: id, continuation: continuation)
                    return
                }
                
                // Replay the last event if there is one
                if let lastEvent = await self.lastEvent {
                    continuation.yield(lastEvent)
                }
                
                await self.addContinuation(id: id, continuation: continuation)
            }
            continuation.onTermination = { _ in
                Task { await self.removeContinuation(id: id) }
            }
        }
    }
    
    // MARK: - Initialization
    
    fileprivate init() {}
    
    private init(isFinished: Bool) {
        self.lastEvent = .completed
        self.isFinished = isFinished
        self.loadingTask = nil
    }
    
    // MARK: - Functions
    
    public func start(
        priority: TaskPriority? = nil,
        with load: @escaping Loader,
        buffer: ImageDataManager.FrameBuffer
    ) {
        loadingTask?.cancel()
        loadingTask = nil
        
        lastEvent = nil
        isFinished = false
        frameBuffer = buffer
        loadingTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            
            await load(self, buffer)
        }
    }
    
    public func send(_ event: ImageDataManager.AsyncLoadEvent) {
        guard !isFinished else { return }
        
        lastEvent = event
        continuations.values.forEach { $0.yield(event) }
        
        /// Mark as finished by **don't** `finish` the streams so we don't unintentionally purge memory
        if case .completed = event {
            isFinished = true
            loadingTask = nil
        }
    }
    
    public func cancel() {
        loadingTask?.cancel()
        loadingTask = nil
        continuations.values.forEach { $0.finish() }
        continuations.removeAll()
        isFinished = true
    }
    
    // MARK: - Internal Functions
    
    private func addContinuation(id: UUID, continuation: AsyncStream<ImageDataManager.AsyncLoadEvent>.Continuation) {
        continuations[id] = continuation
    }
    
    private func removeContinuation(id: UUID) {
        continuations.removeValue(forKey: id)
        
        /// When last observer removed, trigger purge check
        if continuations.isEmpty {
            loadingTask?.cancel()
            loadingTask = nil
            
            Task.detached { [weak frameBuffer] in
                frameBuffer?.purgeIfNeeded()
            }
        }
    }
}
