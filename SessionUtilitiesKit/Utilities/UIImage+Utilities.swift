// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import UIKit.UIImage

public extension UIImage {
    func normalizedImage() -> UIImage {
        guard imageOrientation != .up else { return self }
        
        // The actual resize: draw the image on a new context, applying a transform matrix
        let bounds: CGRect = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = self.scale
        format.opaque = false
        
        // Note: We use the UIImage.draw function here instead of using the CGContext because UIImage
        // automatically deals with orientations so we don't have to
        return UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
            self.draw(in: bounds)
        }
    }
    
    /// This function can be used to resize an image to a different size, it **should not** be used within the UI for rendering smaller
    /// images as it's fairly inefficient (instead the image should be contained within another view and sized explicitly that way)
    func resized(
        toFillPixelSize dstSize: CGSize,
        opaque: Bool = false,
        cropRect: CGRect? = nil
    ) -> UIImage {
        guard let imgRef: CGImage = self.cgImage else { return self }
        
        let result: CGImage = imgRef.resized(
            toFillPixelSize: dstSize,
            opaque: opaque,
            cropRect: cropRect,
            orientation: self.imageOrientation
        )
        
        return UIImage(cgImage: result, scale: 1.0, orientation: .up)
    }
    
    /// This function can be used to resize an image to a different size, it **should not** be used within the UI for rendering smaller
    /// images as it's fairly inefficient (instead the image should be contained within another view and sized explicitly that way)
    func resized(maxDimensionPoints: CGFloat) -> UIImage? {
        guard let imgRef: CGImage = self.cgImage else { return nil }
        
        let originalSize: CGSize = self.size
        let maxOriginalDimensionPoints: CGFloat = max(originalSize.width, originalSize.height)
        
        guard originalSize.width > 0 && originalSize.height > 0 else { return nil }
        
        // Don't bother scaling an image that is already smaller than the max dimension.
        guard maxOriginalDimensionPoints > maxDimensionPoints else { return self }
        
        let thumbnailSize: CGSize = {
            guard originalSize.width <= originalSize.height else {
                return CGSize(
                    width: maxDimensionPoints,
                    height: round(maxDimensionPoints * originalSize.height / originalSize.width)
                )
            }
            
            return CGSize(
                width: round(maxDimensionPoints * originalSize.width / originalSize.height),
                height: maxDimensionPoints
            )
        }()
        
        guard thumbnailSize.width > 0 && thumbnailSize.height > 0 else { return nil }
        
        // the below values are regardless of orientation : for UIImages from Camera, width>height (landscape)
        //
        // Note: Not equivalent to self.size (which is dependant on the imageOrientation)!
        let srcSize: CGSize = CGSize(width: imgRef.width, height: imgRef.height)
        var dstSize: CGSize = thumbnailSize
        
        // Don't resize if we already meet the required destination size
        guard dstSize != srcSize else { return self }
        
        let scaleRatio: CGFloat = (dstSize.width / srcSize.width)
        let orient: UIImage.Orientation = self.imageOrientation
        var transform: CGAffineTransform = .identity
        
        switch orient {
            case .up: break                      // EXIF = 1
            case .upMirrored:                    // EXIF = 2
                transform = CGAffineTransform(translationX: srcSize.width, y: 0)
                    .scaledBy(x: -1, y: 1)
                
            case .down:                          // EXIF = 3
                transform = CGAffineTransform(translationX: srcSize.width, y: srcSize.height)
                    .rotated(by: CGFloat.pi)

            case .downMirrored:                  // EXIF = 4
                transform = CGAffineTransform(translationX: 0, y: srcSize.height)
                    .scaledBy(x: 1, y: -1)
                
            case .leftMirrored:                  // EXIF = 5
                dstSize = CGSize(width: dstSize.height, height: dstSize.width)
                transform = CGAffineTransform(translationX: srcSize.height, y: srcSize.width)
                    .scaledBy(x: -1, y: 1)
                    .rotated(by: (3 * (CGFloat.pi / 2)))
                
            case .left:                          // EXIF = 6
                dstSize = CGSize(width: dstSize.height, height: dstSize.width)
                transform = CGAffineTransform(translationX: 0, y: srcSize.width)
                    .scaledBy(x: -1, y: 1)
                    .rotated(by: (3 * (CGFloat.pi / 2)))
                
            case .rightMirrored:                 // EXIF = 7
                dstSize = CGSize(width: dstSize.height, height: dstSize.width)
                transform = CGAffineTransform(scaleX: -1, y: 1)
                    .rotated(by: (CGFloat.pi / 2))
                
            case .right:                         // EXIF = 8
                dstSize = CGSize(width: dstSize.height, height: dstSize.width)
                transform = CGAffineTransform(translationX: srcSize.height, y: 0)
                    .rotated(by: (CGFloat.pi / 2))
            
            @unknown default: return nil
        }

        // The actual resize: draw the image on a new context, applying a transform matrix
        let bounds: CGRect = CGRect(x: 0, y: 0, width: dstSize.width, height: dstSize.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = self.scale
        format.opaque = false
        
        let renderer: UIGraphicsImageRenderer = UIGraphicsImageRenderer(bounds: bounds, format: format)

        return renderer.image { rendererContext in
            rendererContext.cgContext.interpolationQuality = .high
            
            switch orient {
                case .right, .left:
                    rendererContext.cgContext.scaleBy(x: -scaleRatio, y: scaleRatio)
                    rendererContext.cgContext.translateBy(x: -srcSize.height, y: 0)
                    
                default:
                    rendererContext.cgContext.scaleBy(x: scaleRatio, y: -scaleRatio)
                    rendererContext.cgContext.translateBy(x: 0, y: -srcSize.height)
            }
            
            rendererContext.cgContext.concatenate(transform)
            
            // we use srcSize (and not dstSize) as the size to specify is in user space (and we use the CTM to apply a
            // scaleRatio)
            rendererContext.cgContext.draw(
                imgRef,
                in: CGRect(x: 0, y: 0, width: srcSize.width, height: srcSize.height),
                byTiling: false
            )
        }
    }
}

public extension CGImage {
    func resized(
        toFillPixelSize dstSize: CGSize,
        opaque: Bool = false,
        cropRect: CGRect? = nil,
        orientation: UIImage.Orientation = .up
    ) -> CGImage {
        // Determine actual dimensions accounting for orientation
        let srcSize: CGSize
        let needsRotation: Bool
        
        switch orientation {
            case .left, .leftMirrored, .right, .rightMirrored:
                // 90° or 270° rotation - swap width/height
                srcSize = CGSize(width: self.height, height: self.width)
                needsRotation = true
                
            default:
                srcSize = CGSize(width: self.width, height: self.height)
                needsRotation = (orientation != .up)
        }
        
        // Calculate what portion we're rendering (in oriented coordinate space)
        let sourceRect: CGRect
        
        if let crop: CGRect = cropRect, crop != CGRect(x: 0, y: 0, width: 1, height: 1) {
            // User-specified crop in normalized coordinates
            sourceRect = CGRect(
                x: (crop.origin.x * srcSize.width),
                y: (crop.origin.y * srcSize.height),
                width: (crop.size.width * srcSize.width),
                height: (crop.size.height * srcSize.height)
            )
        } else {
            // Default: aspect-fill crop (center)
            let srcAspect: CGFloat = (srcSize.width / srcSize.height)
            let dstAspect: CGFloat = (dstSize.width / dstSize.height)
            
            if srcAspect > dstAspect {
                // Source is wider - crop sides
                let targetWidth: CGFloat = (srcSize.height * dstAspect)
                sourceRect = CGRect(
                    x: ((srcSize.width - targetWidth) / 2),
                    y: 0,
                    width: targetWidth,
                    height: srcSize.height
                )
            } else {
                // Source is taller - crop top/bottom
                let targetHeight: CGFloat = (srcSize.width / dstAspect)
                sourceRect = CGRect(
                    x: 0,
                    y: ((srcSize.height - targetHeight) / 2),
                    width: srcSize.width,
                    height: targetHeight
                )
            }
        }
        
        // Calculate final size - never scale up
        let finalSize: CGSize
        
        if sourceRect.width <= dstSize.width && sourceRect.height <= dstSize.height {
            finalSize = sourceRect.size
        } else {
            finalSize = dstSize
        }
        
        // Check if any processing is needed
        if !needsRotation && sourceRect == CGRect(origin: .zero, size: srcSize) && finalSize == srcSize {
            // No processing needed - return original
            return self
        }
        
        // Render with orientation transform
        let bounds: CGRect = CGRect(x: 0, y: 0, width: finalSize.width, height: finalSize.height)
        let colorSpace = self.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = (opaque ?
            CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue :
            CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )
        
        guard let ctx: CGContext = CGContext(
            data: nil,
            width: Int(finalSize.width),
            height: Int(finalSize.height),
            bitsPerComponent: 8,
            bytesPerRow: Int(finalSize.width) * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return self }

        ctx.interpolationQuality = .high
        
        if needsRotation {
            ctx.translateBy(x: finalSize.width / 2, y: finalSize.height / 2)
            
            switch orientation {
                case .down, .downMirrored: ctx.rotate(by: .pi)
                case .left, .leftMirrored: ctx.rotate(by: .pi / 2)
                case .right, .rightMirrored: ctx.rotate(by: -.pi / 2)
                default: break
            }
            
            // Handle mirroring
            let mirroredSet: Set<UIImage.Orientation> = [.left, .leftMirrored, .right, .rightMirrored]
            
            if mirroredSet.contains(orientation) {
                ctx.scaleBy(x: -1, y: 1)
            }
            
            ctx.translateBy(x: -finalSize.width / 2, y: -finalSize.height / 2)
        }

        // Determine if we actually need to crop
        let imageToDraw: CGImage = {
            guard sourceRect != CGRect(origin: .zero, size: srcSize) else {
                return self
            }
            
            // Convert crop rect to pixel coordinates and crop
            let pixelCropRect: CGRect = convertToPixelCoordinates(
                sourceRect: sourceRect,
                imgSize: CGSize(width: self.width, height: self.height),
                orientation: orientation
            )
            
            return (self.cropping(to: pixelCropRect) ?? self)
        }()
        
        ctx.draw(imageToDraw, in: bounds, byTiling: false)
        return (ctx.makeImage() ?? self)
    }
    
    private func convertToPixelCoordinates(
        sourceRect: CGRect,
        imgSize: CGSize,
        orientation: UIImage.Orientation
    ) -> CGRect {
        switch orientation {
            case .up, .upMirrored: return sourceRect
            case .down, .downMirrored:
                return CGRect(
                    x: imgSize.width - sourceRect.maxX,
                    y: imgSize.height - sourceRect.maxY,
                    width: sourceRect.width,
                    height: sourceRect.height
                )
                
            case .left, .leftMirrored:
                return CGRect(
                    x: sourceRect.minY,
                    y: imgSize.width - sourceRect.maxX,
                    width: sourceRect.height,
                    height: sourceRect.width
                )
                
            case .right, .rightMirrored:
                return CGRect(
                    x: imgSize.height - sourceRect.maxY,
                    y: sourceRect.minX,
                    width: sourceRect.height,
                    height: sourceRect.width
                )
                
            @unknown default: return sourceRect
        }
    }
}
