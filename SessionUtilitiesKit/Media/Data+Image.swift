// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import AVKit
import ImageIO
import UniformTypeIdentifiers

public extension Data {
    private struct ImageDimensions {
        let pixelSize: CGSize
        let depthBytes: CGFloat
    }
    
    var isValidImage: Bool {
        let imageFormat: ImageFormat = self.guessedImageFormat
        let isAnimated: Bool = (imageFormat == .gif)
        let maxFileSize: UInt = (isAnimated ?
            MediaUtils.maxFileSizeAnimatedImage :
            MediaUtils.maxFileSizeImage
        )
        
        return (
            count < maxFileSize &&
            isValidImage(type: nil, format: imageFormat) &&
            hasValidImageDimensions(isAnimated: isAnimated)
        )
    }
    
    var guessedImageFormat: ImageFormat {
        let twoBytesLength: Int = 2
        
        guard count > twoBytesLength else { return .unknown }

        var bytes: [UInt8] = [UInt8](repeating: 0, count: twoBytesLength)
        self.copyBytes(to: &bytes, from: (self.startIndex..<self.startIndex.advanced(by: twoBytesLength)))

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
    
    // Parse the GIF header to prevent the "GIF of death" issue.
    //
    // See: https://blog.flanker017.me/cve-2017-2416-gif-remote-exec/
    // See: https://www.w3.org/Graphics/GIF/spec-gif89a.txt
    var hasValidGifSize: Bool {
        let signatureLength: Int = 3
        let versionLength: Int = 3
        let widthLength: Int = 2
        let heightLength: Int = 2
        let prefixLength: Int = (signatureLength + versionLength)
        let bufferLength: Int = (signatureLength + versionLength + widthLength + heightLength)
        
        guard count > bufferLength else { return false }

        var bytes: [UInt8] = [UInt8](repeating: 0, count: bufferLength)
        self.copyBytes(to: &bytes, from: (self.startIndex..<self.startIndex.advanced(by: bufferLength)))

        let gif87APrefix: [UInt8] = [0x47, 0x49, 0x46, 0x38, 0x37, 0x61]
        let gif89APrefix: [UInt8] = [0x47, 0x49, 0x46, 0x38, 0x39, 0x61]
        
        guard bytes.starts(with: gif87APrefix) || bytes.starts(with: gif89APrefix) else {
            return false
        }
        
        let width: UInt = (UInt(bytes[prefixLength]) | (UInt(bytes[prefixLength + 1]) << 8))
        let height: UInt = (UInt(bytes[prefixLength + 2]) | (UInt(bytes[prefixLength + 3]) << 8))

        // We need to ensure that the image size is "reasonable"
        // We impose an arbitrary "very large" limit on image size
        // to eliminate harmful values
        let maxValidSize: UInt = (1 << 18)

        return (width > 0 && width < maxValidSize && height > 0 && height < maxValidSize)
    }
    
    var sizeForWebpData: CGSize {
        guard
            guessedImageFormat == .webp,
            let source: CGImageSource = CGImageSourceCreateWithData(self as CFData, nil)
        else { return .zero }
        
        // Check if there's at least one image
        let count: Int = CGImageSourceGetCount(source)
        guard count > 0 else {
            return .zero
        }
        
        // Get properties of the first frame
        guard let properties: [CFString: Any] = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return .zero
        }
        
        // Try to get dimensions from properties
        if
            let width: Int = properties[kCGImagePropertyPixelWidth] as? Int,
            let height: Int = properties[kCGImagePropertyPixelHeight] as? Int,
            width > 0,
            height > 0
        {
            return CGSize(width: width, height: height)
        }
        
        // If we can't get dimensions from properties, try creating an image
        if let image: CGImage = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            return CGSize(width: image.width, height: image.height)
        }
        
        return .zero
    }
    
    // MARK: - Initialization
    
    init?(validImageDataAt path: String, type: UTType? = nil, using dependencies: Dependencies) throws {
        let fileUrl: URL = URL(fileURLWithPath: path)
        
        guard
            let type: UTType = type,
            let fileSize: UInt64 = dependencies[singleton: .fileManager].fileSize(of: path),
            fileSize <= SNUtilitiesKit.maxFileSize,
            (type.isImage || type.isAnimated)
        else { return nil }
        
        self = try Data(contentsOf: fileUrl, options: [.dataReadingMapped])
    }
    
    // MARK: - Functions
    
    func hasValidImageDimensions(isAnimated: Bool) -> Bool {
        guard
            let dataPtr: CFData = CFDataCreate(kCFAllocatorDefault, self.bytes, self.count),
            let imageSource = CGImageSourceCreateWithData(dataPtr, nil)
        else { return false }

        return Data.hasValidImageDimension(source: imageSource, isAnimated: isAnimated)
    }
    
    func isValidImage(type: UTType?) -> Bool {
        return isValidImage(type: type, format: self.guessedImageFormat)
    }
    
    func isValidImage(type: UTType?, format: ImageFormat) -> Bool {
        // Don't trust the file extension; iOS (e.g. UIKit, Core Graphics) will happily
        // load a .gif with a .png file extension
        //
        // Instead, use the "magic numbers" in the file data to determine the image format
        //
        // If the image has a declared MIME type, ensure that agrees with the
        // deduced image format
        switch format {
            case .unknown: return false
            case .png: return (type == nil || type == .png)
            case .jpeg: return (type == nil || type == .jpeg)
                
            case .gif:
                guard hasValidGifSize else { return false }
                
                return (type == nil || type == .gif)
                
            case .tiff: return (type == nil || type == .tiff || type == .xTiff)
            case .bmp: return (type == nil || type == .bmp || type == .xWinBpm)
            case .webp: return (type == nil || type == .webP)
        }
    }
    
    static func isValidImage(at path: String, type: UTType? = nil, using dependencies: Dependencies) -> Bool {
        guard let data: Data = try? Data(validImageDataAt: path, type: type, using: dependencies) else {
            return false
        }
        
        return data.hasValidImageDimensions(isAnimated: type?.isAnimated == true)
    }
    
    static func hasValidImageDimension(source: CGImageSource, isAnimated: Bool) -> Bool {
        guard let dimensions: ImageDimensions = imageDimensions(source: source) else { return false }

        // We only support (A)RGB and (A)Grayscale, so worst case is 4.
        let worseCastComponentsPerPixel: CGFloat = 4
        let bytesPerPixel: CGFloat = (worseCastComponentsPerPixel * dimensions.depthBytes)
        let expectedBytePerPixel: CGFloat = 4
        let maxValidImageDimension: CGFloat = CGFloat(isAnimated ?
            MediaUtils.maxAnimatedImageDimensions :
            MediaUtils.maxStillImageDimensions
        )
        let maxBytes: CGFloat = (maxValidImageDimension * maxValidImageDimension * expectedBytePerPixel)
        let actualBytes: CGFloat = (dimensions.pixelSize.width * dimensions.pixelSize.height * bytesPerPixel)
        
        return (actualBytes <= maxBytes)
    }
    
    static func hasAlpha(forValidImageFilePath filePath: String) -> Bool {
        let fileUrl: URL = URL(fileURLWithPath: filePath)
        let options: [String: Any] = [kCGImageSourceShouldCache as String: NSNumber(booleanLiteral: false)]
        
        guard
            let imageSource = CGImageSourceCreateWithURL(fileUrl as CFURL, nil),
            let properties: [CFString: Any] = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, options as CFDictionary) as? [CFString: Any],
            let hasAlpha: Bool = properties[kCGImagePropertyHasAlpha] as? Bool
        else { return false }
        
        return hasAlpha
    }
    
    private static func imageDimensions(source: CGImageSource) -> ImageDimensions? {
        guard
            let properties: [CFString: Any] = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width: Double = properties[kCGImagePropertyPixelWidth] as? Double,
            let height: Double = properties[kCGImagePropertyPixelHeight] as? Double,
            // The number of bits in each color sample of each pixel. The value of this key is a CFNumberRef
            let depthBits: UInt = properties[kCGImagePropertyDepth] as? UInt
        else { return nil }
        
        // This should usually be 1.
        let depthBytes: CGFloat = ceil(CGFloat(depthBits) / 8.0)

        // The color model of the image such as "RGB", "CMYK", "Gray", or "Lab"
        // The value of this key is CFStringRef
        guard
            let colorModel = properties[kCGImagePropertyColorModel] as? String,
            (
                colorModel != (kCGImagePropertyColorModelRGB as String) ||
                colorModel != (kCGImagePropertyColorModelGray as String)
            )
        else { return nil }

        return ImageDimensions(pixelSize: CGSize(width: width, height: height), depthBytes: depthBytes)
    }
    
    static func mediaSize(
        for path: String,
        type: UTType?,
        mimeType: String?,
        sourceFilename: String?,
        using dependencies: Dependencies
    ) -> CGSize {
        let fileUrl: URL = URL(fileURLWithPath: path)
        let maybePixelSize: CGSize? = extractSize(
            from: path,
            type: type,
            mimeType: mimeType,
            sourceFilename: sourceFilename,
            using: dependencies
        )
        
        guard let pixelSize: CGSize = maybePixelSize else { return .zero }
        
        // WebP and videos shouldn't have orientations so no need for any logic to rotate the size
        switch (type, type?.isVideo, type?.isAnimated) {
            case (.webP, _, _), (_, true, _), (_, _, true): return pixelSize
            default: break
        }
                
        // With CGImageSource we avoid loading the whole image into memory.
        let options: [String: Any] = [kCGImageSourceShouldCache as String: NSNumber(booleanLiteral: false)]
        
        guard
            let imageSource = CGImageSourceCreateWithURL(fileUrl as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, options as CFDictionary) as? [AnyHashable: Any],
            let width: CGFloat = properties[kCGImagePropertyPixelWidth as String] as? CGFloat,
            let height: CGFloat = properties[kCGImagePropertyPixelHeight as String] as? CGFloat
        else { return .zero }
        
        guard
            let rawCgOrientation: UInt32 = properties[kCGImagePropertyOrientation] as? UInt32,
            let cgOrientation: CGImagePropertyOrientation = CGImagePropertyOrientation(rawValue: rawCgOrientation)
        else {
            return CGSize(width: width, height: height)
        }
        
        return apply(
            orientation: UIImage.Orientation(cgOrientation),
            to: CGSize(width: width, height: height)
        )
    }
                     
    private static func apply(orientation: UIImage.Orientation, to imageSize: CGSize) -> CGSize {
        switch orientation {
            case .up, .upMirrored, .down, .downMirrored: return imageSize
            case .leftMirrored, .left, .rightMirrored, .right:
                return CGSize(width: imageSize.height, height: imageSize.width)
                
            @unknown default: return imageSize
        }
    }
    
    private static func extractSize(
        from path: String,
        type: UTType?,
        mimeType: String?,
        sourceFilename: String?,
        using dependencies: Dependencies
    ) -> CGSize? {
        let fileUrl: URL = URL(fileURLWithPath: path)
        
        switch (type, type?.isVideo) {
            case (.webP, _):
                // Need to custom handle WebP images
                guard let targetData: Data = try? Data(contentsOf: fileUrl, options: [.dataReadingMapped]) else {
                    return nil
                }
                
                let imageSize: CGSize = targetData.sizeForWebpData
                
                guard imageSize.width > 0, imageSize.height > 0 else { return nil }
                
                return imageSize
                
            case (_, true):
                // Videos don't have the same metadata as images so also need custom handling
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
                
                return videoSize
                
            default:
                // Otherwise use our custom code
                guard
                    let imageSource = CGImageSourceCreateWithURL(fileUrl as CFURL, nil),
                    let dimensions: ImageDimensions = imageDimensions(source: imageSource),
                    dimensions.pixelSize.width > 0,
                    dimensions.pixelSize.height > 0,
                    dimensions.depthBytes > 0
                else { return nil }
                
                return dimensions.pixelSize
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
