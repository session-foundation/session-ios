// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

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
    public struct MediaMetadata {
        public let pixelSize: CGSize
        public let frameCount: Int
        public let depthBytes: CGFloat?
        public let hasAlpha: Bool?
        public let colorModel: String?
        public let orientation: UIImage.Orientation?
        
        public var hasValidPixelSize: Bool {
            pixelSize.width > 0 &&
            pixelSize.width < CGFloat(SNUtilitiesKit.maxValidImageDimension) &&
            pixelSize.height > 0 &&
            pixelSize.height < CGFloat(SNUtilitiesKit.maxValidImageDimension)
        }
        
        // MARK: - Initialization
        
        public init?(source: CGImageSource) {
            let count: Int = CGImageSourceGetCount(source)
            
            guard
                count > 0,
                let properties: [CFString: Any] = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                let width: Double = properties[kCGImagePropertyPixelWidth] as? Double,
                let height: Double = properties[kCGImagePropertyPixelHeight] as? Double
            else { return nil }
            
            self.pixelSize = CGSize(width: width, height: height)
            self.frameCount = count
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
        }
        
        public init(
            pixelSize: CGSize,
            depthBytes: CGFloat? = nil,
            hasAlpha: Bool? = nil,
            colorModel: String? = nil,
            orientation: UIImage.Orientation? = nil
        ) {
            self.pixelSize = pixelSize
            self.frameCount = 1
            self.depthBytes = depthBytes
            self.hasAlpha = hasAlpha
            self.colorModel = colorModel
            self.orientation = orientation
        }
        
        public init?(
            from path: String,
            type: UTType?,
            mimeType: String?,
            sourceFilename: String?,
            using dependencies: Dependencies
        ) {
            /// Videos don't have the same metadata as images so need custom handling
            guard type?.isVideo != true else {
                let assetInfo: (asset: AVURLAsset, cleanup: () -> Void)? = AVURLAsset.asset(
                    for: path,
                    mimeType: mimeType,
                    sourceFilename: sourceFilename,
                    using: dependencies
                )
                
                guard
                    let asset: AVURLAsset = assetInfo?.asset,
                    let track: AVAssetTrack = asset.tracks(withMediaType: .video).first
                else { return nil }
                
                let size: CGSize = track.naturalSize
                let transformedSize: CGSize = size.applying(track.preferredTransform)
                let videoSize: CGSize = CGSize(
                    width: abs(transformedSize.width),
                    height: abs(transformedSize.height)
                )
                
                guard videoSize.width > 0, videoSize.height > 0 else { return nil }
                
                self.pixelSize = videoSize
                self.frameCount = -1 /// Rather than try to extract the frames, or give it an "incorrect" value, make it explicitly invalid
                self.depthBytes = nil
                self.hasAlpha = false
                self.colorModel = nil
                self.orientation = nil
                return
            }
            
            guard
                let imageSource = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
                let metadata: MediaMetadata = MediaMetadata(source: imageSource)
            else { return nil }
            
            self = metadata
        }
        
        // MARK: - Functions
        
        public func apply(orientation: UIImage.Orientation) -> CGSize {
            switch orientation {
                case .up, .upMirrored, .down, .downMirrored: return pixelSize
                case .leftMirrored, .left, .rightMirrored, .right:
                    return CGSize(width: pixelSize.height, height: pixelSize.width)
                    
                @unknown default: return pixelSize
            }
        }
    }
    
    public static func isVideoOfValidContentTypeAndSize(path: String, type: String?, using dependencies: Dependencies) -> Bool {
        guard dependencies[singleton: .fileManager].fileExists(atPath: path) else {
            Log.error(.media, "Media file missing.")
            return false
        }
        guard let type: String = type, UTType.isVideo(type) else {
            Log.error(.media, "Media file has invalid content type.")
            return false
        }
        
        guard let fileSize: UInt64 = dependencies[singleton: .fileManager].fileSize(of: path) else {
            Log.error(.media, "Media file has unknown length.")
            return false
        }
        return UInt(fileSize) <= SNUtilitiesKit.maxFileSize
    }
    
    public static func isValidVideo(asset: AVURLAsset) -> Bool {
        var maxTrackSize = CGSize.zero
        
        for track: AVAssetTrack in asset.tracks(withMediaType: .video) {
            let trackSize: CGSize = track.naturalSize
            maxTrackSize.width = max(maxTrackSize.width, trackSize.width)
            maxTrackSize.height = max(maxTrackSize.height, trackSize.height)
        }
        
        return MediaMetadata(pixelSize: maxTrackSize).hasValidPixelSize
    }
    
    /// Use `isValidVideo(asset: AVURLAsset)` if the `AVURLAsset` needs to be generated elsewhere in the code,
    /// otherwise this will be inefficient as it can create a temporary file for the `AVURLAsset` on old iOS versions
    public static func isValidVideo(path: String, mimeType: String?, sourceFilename: String?, using dependencies: Dependencies) -> Bool {
        guard
            let assetInfo: (asset: AVURLAsset, cleanup: () -> Void) = AVURLAsset.asset(
                for: path,
                mimeType: mimeType,
                sourceFilename: sourceFilename,
                using: dependencies
            )
        else { return false }
        
        let result: Bool = isValidVideo(asset: assetInfo.asset)
        assetInfo.cleanup()
        
        return result
    }
    
    public static func isValidImage(data: Data, type: UTType? = nil) -> Bool {
        let options: CFDictionary = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: false
        ] as CFDictionary
        
        guard
            data.count < SNUtilitiesKit.maxFileSize,
            let type: UTType = type,
            (type.isImage || type.isAnimated),
            let source: CGImageSource = CGImageSourceCreateWithData(data as CFData, options),
            let metadata: MediaMetadata = MediaMetadata(source: source)
        else { return false }
        
        return metadata.hasValidPixelSize
    }
    
    public static func isValidImage(at path: String, type: UTType? = nil, using dependencies: Dependencies) -> Bool {
        let options: CFDictionary = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: false
        ] as CFDictionary
        
        guard
            let type: UTType = type,
            let fileSize: UInt64 = dependencies[singleton: .fileManager].fileSize(of: path),
            fileSize <= SNUtilitiesKit.maxFileSize,
            (type.isImage || type.isAnimated),
            let source: CGImageSource = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, options),
            let metadata: MediaMetadata = MediaMetadata(source: source)
        else { return false }
        
        return metadata.hasValidPixelSize
    }
    
    public static func unrotatedSize(
        for path: String,
        type: UTType?,
        mimeType: String?,
        sourceFilename: String?,
        using dependencies: Dependencies
    ) -> CGSize {
        guard
            let metadata: MediaMetadata = MediaMetadata(
                from: path,
                type: type,
                mimeType: mimeType,
                sourceFilename: sourceFilename,
                using: dependencies
            )
        else { return .zero }
        
        /// If the metadata doesn't ahve an orientation then don't rotate the size (WebP and videos shouldn't have orientations)
        guard let orientation: UIImage.Orientation = metadata.orientation else { return metadata.pixelSize }
        
        return metadata.apply(orientation: orientation)
    }
    
    public static func guessedImageFormat(data: Data) -> ImageFormat {
        let twoBytesLength: Int = 2
        
        guard data.count > twoBytesLength else { return .unknown }
        
        var bytes: [UInt8] = [UInt8](repeating: 0, count: twoBytesLength)
        data.copyBytes(to: &bytes, from: (data.startIndex..<data.startIndex.advanced(by: twoBytesLength)))
        
        switch (bytes[0], bytes[1]) {
            case (0x47, 0x49): return .gif
            case (0x89, 0x50): return .png
            case (0xff, 0xd8): return .jpeg
            case (0x42, 0x4d): return .bmp
            case (0x4D, 0x4D): return .tiff // Motorola byte order TIFF
            case (0x49, 0x49): return .tiff // Intel byte order TIFF
            case (0x52, 0x49): return .webp // First two letters of WebP
                
            default: return .unknown
        }
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
