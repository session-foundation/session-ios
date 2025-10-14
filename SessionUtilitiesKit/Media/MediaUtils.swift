// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import UIKit
import AVFoundation

// MARK: - Log.Category

public extension Log.Category {
    static let media: Log.Category = .create("MediaUtils", defaultLevel: .warn)
}

// MARK: - MediaError

public enum MediaError: Error {
    case failure(description: String)
}

// MARK: - MediaUtils

public enum MediaUtils {
    public static let unsafeMetadataKeys: Set<CFString> = [
        kCGImagePropertyExifDictionary,             /// Camera settings, dates
        kCGImagePropertyGPSDictionary,              /// Location data
        kCGImagePropertyIPTCDictionary,             /// Copyright, captions
        kCGImagePropertyTIFFDictionary,             /// Camera make/model, software
        kCGImagePropertyMakerAppleDictionary,       /// Apple device info
        kCGImagePropertyExifAuxDictionary,          /// Lens info, etc.
        kCGImageProperty8BIMDictionary,             /// Photoshop data
        kCGImagePropertyDNGDictionary,              /// RAW camera data
        kCGImagePropertyCIFFDictionary,             /// Canon RAW
        kCGImagePropertyMakerCanonDictionary,
        kCGImagePropertyMakerNikonDictionary,
        kCGImagePropertyMakerMinoltaDictionary,
        kCGImagePropertyMakerFujiDictionary,
        kCGImagePropertyMakerOlympusDictionary,
        kCGImagePropertyMakerPentaxDictionary
    ]
    public static let possiblySafeMetadataKeys: Set<CFString> = [
        kCGImagePropertyPNGDictionary,
        kCGImagePropertyGIFDictionary,
        kCGImagePropertyJFIFDictionary,
        kCGImagePropertyHEICSDictionary
    ]
    public static let safeMetadataKeys: Set<CFString> = [
        kCGImagePropertyPixelWidth,
        kCGImagePropertyPixelHeight,
        kCGImagePropertyDepth,
        kCGImagePropertyHasAlpha,
        kCGImagePropertyColorModel,
        kCGImagePropertyOrientation,
        kCGImagePropertyGIFLoopCount,
        kCGImagePropertyGIFHasGlobalColorMap,
        kCGImagePropertyGIFDelayTime,
        kCGImagePropertyGIFUnclampedDelayTime,
        kCGImageDestinationLossyCompressionQuality
    ]
    
    public struct MediaMetadata: Sendable, Equatable, Hashable {
        /// The pixel size of the media (or it's first frame)
        public let pixelSize: CGSize
        
        /// The size of the file this media is stored in
        ///
        /// **Note:** This value could be `0` if initialised with a `UIImage` (since the eventual file size would depend on the the
        /// file type when written to disk)
        public let fileSize: UInt64
        
        /// The duration of each frame (this will contain a single element of `0` for static images, and be empty for anything else)
        public let frameDurations: [TimeInterval]
        
        /// The duration of the content (will be `0` for static images)
        public let duration: TimeInterval
        
        /// A flag indicating whether the media may contain unsafe metadata
        public let hasUnsafeMetadata: Bool
        
        /// The number of bits in each color sample of each pixel
        public let depthBytes: CGFloat?
        
        /// A flag indicating whether the media has transparent content
        public let hasAlpha: Bool?
        
        /// The color model of the image such as "RGB", "CMYK", "Gray", or "Lab"
        public let colorModel: String?
        
        /// The orientation of the media
        public let orientation: UIImage.Orientation?
        
        /// The type of the media content
        public let utType: UTType?
        
        /// The number of frames this media has
        public var frameCount: Int { frameDurations.count }
        
        /// A flag indicating whether the media has valid dimensions (this is primarily here to avoid a "GIF bomb" situation)
        public var hasValidPixelSize: Bool {
            /// If the content isn't visual media then it should have a `zero` size
            guard utType?.isVisualMedia == true else { return (pixelSize == .zero) }
            
            /// Otherwise just ensure it's a sane size
            return (
                pixelSize.width > 0 &&
                pixelSize.width < CGFloat(SNUtilitiesKit.maxValidImageDimension) &&
                pixelSize.height > 0 &&
                pixelSize.height < CGFloat(SNUtilitiesKit.maxValidImageDimension)
            )
        }
        
        /// A flag indicating whether the media has a valid duration for it's type
        public var hasValidDuration: Bool {
            if utType?.isAudio == true || utType?.isVideo == true {
                return (duration > 0)
            }
            
            if utType?.isAnimated == true && frameDurations.count > 1 {
                return (duration > 0)
            }
            
            /// Other types shouldn't have a duration
            return (duration == 0)
        }
        
        public var unrotatedSize: CGSize {
            /// If the metadata doesn't have an orientation then don't rotate the size (WebP and videos shouldn't have orientations)
            guard let orientation: UIImage.Orientation = orientation else { return pixelSize }
            
            switch orientation {
                case .up, .upMirrored, .down, .downMirrored: return pixelSize
                case .leftMirrored, .left, .rightMirrored, .right:
                    return CGSize(width: pixelSize.height, height: pixelSize.width)
                    
                @unknown default: return pixelSize
            }
        }
        
        // MARK: - Initialization
        
        public init?(source: CGImageSource, fileSize: UInt64) {
            let count: Int = CGImageSourceGetCount(source)
            
            guard
                count > 0,
                let properties: [CFString: Any] = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                let width: Double = properties[kCGImagePropertyPixelWidth] as? Double,
                let height: Double = properties[kCGImagePropertyPixelHeight] as? Double
            else { return nil }
            
            self.pixelSize = CGSize(width: width, height: height)
            self.fileSize = fileSize
            self.frameDurations = {
                guard count > 1 else { return [0] }
                
                return (0..<count).map { MediaUtils.getFrameDuration(from: source, at: $0) }
            }()
            self.duration = frameDurations.reduce(0, +)
            self.hasUnsafeMetadata = {
                let allKeys: Set<CFString> = Set(properties.keys)
                
                /// If we have one of the unsafe metadata keys then no need to process further
                guard allKeys.isDisjoint(with: unsafeMetadataKeys) else {
                    return true
                }
                
                /// A number of the properties required for media decoding are included at both the top level and in child data so
                /// we need to check if there are any "non-allowed" keys in the child data in order to make a decision
                for key in possiblySafeMetadataKeys {
                    guard
                        let childProperties: [CFString: Any] = properties[key] as? [CFString: Any],
                        !childProperties.isEmpty
                    else { continue }
                    
                    let allChildKeys: Set<CFString> = Set(childProperties.keys)
                    let unsafeKeys: Set<CFString> = allChildKeys.subtracting(safeMetadataKeys)
                    
                    if !unsafeKeys.isEmpty {
                        return true
                    }
                    
                    continue
                }
                
                /// If we get here then there is no unsafe metadata
                return false
            }()
            self.depthBytes = {
                /// The number of bits in each color sample of each pixel. The value of this key is a CFNumberRef
                guard let depthBits: UInt = properties[kCGImagePropertyDepth] as? UInt else { return nil }
                
                /// This should usually be 1
                return ceil(CGFloat(depthBits) / 8.0)
            }()
            self.hasAlpha = (properties[kCGImagePropertyHasAlpha] as? Bool)
            /// The color model of the image such as "RGB", "CMYK", "Gray", or "Lab", the value of this key is CFStringRef
            self.colorModel = (properties[kCGImagePropertyColorModel] as? String)
            self.orientation = {
                guard
                    let rawCgOrientation: UInt32 = properties[kCGImagePropertyOrientation] as? UInt32,
                    let cgOrientation: CGImagePropertyOrientation = CGImagePropertyOrientation(rawValue: rawCgOrientation)
                else { return nil }
        
                return UIImage.Orientation(cgOrientation)
            }()
            self.utType = (CGImageSourceGetType(source) as? String).map { UTType($0) }
        }
        
        public init(
            pixelSize: CGSize,
            fileSize: UInt64 = 0,
            frameDurations: [TimeInterval] = [0],
            hasUnsafeMetadata: Bool,
            depthBytes: CGFloat? = nil,
            hasAlpha: Bool? = nil,
            colorModel: String? = nil,
            orientation: UIImage.Orientation? = nil,
            utType: UTType? = nil
        ) {
            self.pixelSize = pixelSize
            self.fileSize = fileSize
            self.frameDurations = frameDurations
            self.duration = frameDurations.reduce(0, +)
            self.hasUnsafeMetadata = hasUnsafeMetadata
            self.depthBytes = depthBytes
            self.hasAlpha = hasAlpha
            self.colorModel = colorModel
            self.orientation = orientation
            self.utType = utType
        }
        
        public init?(image: UIImage) {
            guard let cgImage = image.cgImage else { return nil }
            
            self.pixelSize = image.size
            self.fileSize = 0  /// Unknown for `UIImage` in memory
            self.frameDurations = [0]
            self.duration = 0
            self.hasUnsafeMetadata = false  /// `UIImage` in memory has no file metadata
            self.depthBytes = {
                let bitsPerPixel = cgImage.bitsPerPixel
                return ceil(CGFloat(bitsPerPixel) / 8.0)
            }()
            let hasAlphaChannel: Bool = {
                switch cgImage.alphaInfo {
                    case .none, .noneSkipFirst, .noneSkipLast: return false
                    case .first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly: return true
                    @unknown default: return false
                }
            }()
            self.hasAlpha = hasAlphaChannel
            self.colorModel = {
                switch cgImage.colorSpace?.model {
                    case .monochrome: return "Gray"
                    case .rgb: return "RGB"
                    case .cmyk: return "CMYK"
                    case .lab: return "Lab"
                    default: return nil
                }
            }()
            self.orientation = image.imageOrientation
            self.utType = nil  /// An in-memory `UIImage` is just decoded pixels so doesn't have a `UTType`
        }
        
        public init?(
            from path: String,
            utType: UTType?,
            sourceFilename: String?,
            using dependencies: Dependencies
        ) {
            /// Videos don't have the same metadata as images so need custom handling
            guard utType?.isVideo != true else {
                let assetInfo: (asset: AVURLAsset, cleanup: () -> Void)? = AVURLAsset.asset(
                    for: path,
                    utType: utType,
                    sourceFilename: sourceFilename,
                    using: dependencies
                )
                defer { assetInfo?.cleanup() }
                
                guard
                    let fileSize: UInt64 = dependencies[singleton: .fileManager].fileSize(of: path),
                    let asset: AVURLAsset = assetInfo?.asset,
                    !asset.tracks(withMediaType: .video).isEmpty
                else { return nil }
                
                /// Get the maximum size of any video track in the file
                var maxTrackSize: CGSize = asset.maxVideoTrackSize
                
                guard maxTrackSize.width > 0, maxTrackSize.height > 0 else { return nil }
                
                self.pixelSize = maxTrackSize
                self.fileSize = fileSize
                self.frameDurations = [] /// Rather than try to extract the frames, or give it an "incorrect" value, make it explicitly invalid
                self.duration = (    /// According to the CMTime docs "value/timescale = seconds"
                    TimeInterval(asset.duration.value) / TimeInterval(asset.duration.timescale)
                )
                self.hasUnsafeMetadata = false  /// Don't current support stripping this so just hard-code
                self.depthBytes = nil
                self.hasAlpha = false
                self.colorModel = nil
                self.orientation = nil
                self.utType = utType
                return
            }
            
            /// Audio also needs custom handling
            guard utType?.isAudio != true else {
                guard let fileSize: UInt64 = dependencies[singleton: .fileManager].fileSize(of: path) else {
                    return nil
                }
                
                self.pixelSize = .zero
                self.fileSize = fileSize
                self.frameDurations = []
                
                do { self.duration = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: path)).duration }
                catch { return nil }
                
                self.hasUnsafeMetadata = false  /// Don't current support stripping this so just hard-code
                self.depthBytes = nil
                self.hasAlpha = false
                self.colorModel = nil
                self.orientation = nil
                self.utType = utType
                return
            }
            
            /// Load the image source and use that initializer to extract the metadata
            let options: CFDictionary = [
                kCGImageSourceShouldCache: false,
                kCGImageSourceShouldCacheImmediately: false
            ] as CFDictionary
            
            guard
                let fileSize: UInt64 = dependencies[singleton: .fileManager].fileSize(of: path),
                let imageSource = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, options),
                let metadata: MediaMetadata = MediaMetadata(source: imageSource, fileSize: fileSize)
            else { return nil }
            
            self = metadata
        }
    }
    
    public static func isValidVideo(asset: AVURLAsset) -> Bool {
        return MediaMetadata(
            pixelSize: asset.maxVideoTrackSize,
            hasUnsafeMetadata: false
        ).hasValidPixelSize
    }
    
    /// Use `isValidVideo(asset: AVURLAsset)` if the `AVURLAsset` needs to be generated elsewhere in the code,
    /// otherwise this will be inefficient as it can create a temporary file for the `AVURLAsset` on old iOS versions
    public static func isValidVideo(path: String, utType: UTType?, sourceFilename: String?, using dependencies: Dependencies) -> Bool {
        guard
            let assetInfo: (asset: AVURLAsset, cleanup: () -> Void) = AVURLAsset.asset(
                for: path,
                utType: utType,
                sourceFilename: sourceFilename,
                using: dependencies
            )
        else { return false }
        
        let result: Bool = isValidVideo(asset: assetInfo.asset)
        assetInfo.cleanup()
        
        return result
    }
    
    public static func unrotatedSize(
        for path: String,
        utType: UTType?,
        sourceFilename: String?,
        using dependencies: Dependencies
    ) -> CGSize {
        guard
            let metadata: MediaMetadata = MediaMetadata(
                from: path,
                utType: utType,
                sourceFilename: sourceFilename,
                using: dependencies
            )
        else { return .zero }
        
        return metadata.unrotatedSize
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

// MARK: - Convenience

public extension MediaUtils.MediaMetadata {
    var isValidImage: Bool {
        guard
            let utType: UTType = utType,
            (utType.isImage || utType.isAnimated)
        else { return false }
        
        return (hasValidPixelSize && hasValidDuration)
    }
}

private extension UIImage.Orientation {
    init(_ cgOrientation: CGImagePropertyOrientation) {
        switch cgOrientation {
            case .up: self = .up
            case .upMirrored: self = .upMirrored
            case .down: self = .down
            case .downMirrored: self = .downMirrored
            case .left: self = .left
            case .leftMirrored: self = .leftMirrored
            case .right: self = .right
            case .rightMirrored: self = .rightMirrored
        }
    }
}
