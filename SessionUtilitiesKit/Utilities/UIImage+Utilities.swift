// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import UIKit.UIImage

public extension UIImage {
    enum ResizeMode: Sendable, Equatable, Hashable {
        case fill  /// Aspect-fill (crops to fill size)
        case fit   /// Aspect-fit (fits within size, may have empty space)
    }
    
    func normalizedImage() -> UIImage {
        guard imageOrientation != .up else { return self }
        guard let cgImage: CGImage = self.cgImage else { return self }
        
        return UIImage(
            cgImage: cgImage.normalized(orientation: imageOrientation),
            scale: self.scale,
            orientation: .up
        )
    }
    
    /// This function can be used to resize an image to a different size, it **should not** be used within the UI for rendering smaller
    /// images as it's fairly inefficient (instead the image should be contained within another view and sized explicitly that way)
    func resized(
        toPixelSize dstSize: CGSize,
        mode: ResizeMode = .fill,
        opaque: Bool = false,
        cropRect: CGRect? = nil
    ) -> UIImage {
        guard let imgRef: CGImage = self.cgImage else { return self }
        
        let result: CGImage = imgRef.resized(
            toPixelSize: dstSize,
            mode: mode,
            opaque: opaque,
            cropRect: cropRect,
            orientation: self.imageOrientation
        )
        
        return UIImage(cgImage: result, scale: 1.0, orientation: .up)
    }
}

public extension CGImage {
    func normalized(orientation: UIImage.Orientation) -> CGImage {
        guard orientation != .up else { return self }
        
        let pixelSize: CGSize = CGSize(width: self.width, height: self.height)
        
        return self.resized(
            toPixelSize: pixelSize,
            mode: .fit,
            opaque: (self.alphaInfo == .none || self.alphaInfo == .noneSkipFirst),
            cropRect: nil,
            orientation: orientation
        )
    }
    
    func resized(
        toPixelSize dstSize: CGSize,
        mode: UIImage.ResizeMode = .fill,
        opaque: Bool = false,
        cropRect: CGRect? = nil,
        orientation: UIImage.Orientation = .up
    ) -> CGImage {
        // Determine actual dimensions accounting for orientation
        let needsRotation: Bool = [.left, .leftMirrored, .right, .rightMirrored].contains(orientation)
        let srcSize: CGSize = (needsRotation ?
            CGSize(width: self.height, height: self.width) :
            CGSize(width: self.width, height: self.height)
        )
        
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
            
            switch mode {
                case .fill:
                    // Aspect-fill: crop to fill destination
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
                    
                case .fit:
                    // Aspect-fit: use entire source, will fit within destination
                    sourceRect = CGRect(origin: .zero, size: srcSize)
            }
        }
        
        // Calculate final size
        let finalSize: CGSize
        
        switch mode {
            case .fill:
                // Never scale up
                if sourceRect.width <= dstSize.width && sourceRect.height <= dstSize.height {
                    finalSize = sourceRect.size
                } else {
                    finalSize = dstSize
                }
                
            case .fit:
                if sourceRect.width <= dstSize.width && sourceRect.height <= dstSize.height {
                    // Already fits - use original size
                    finalSize = sourceRect.size
                } else {
                    // Needs scaling down - fit within destination bounds
                    let srcAspect: CGFloat = (sourceRect.width / sourceRect.height)
                    let dstAspect: CGFloat = (dstSize.width / dstSize.height)
                    
                    if srcAspect > dstAspect {
                        // Width constrained
                        finalSize = CGSize(
                            width: dstSize.width,
                            height: (dstSize.width / srcAspect)
                        )
                    } else {
                        // Height constrained
                        finalSize = CGSize(
                            width: (dstSize.height * srcAspect),
                            height: dstSize.height
                        )
                    }
                }
        }
        
        // Check if any processing is needed
        if orientation == .up && sourceRect == CGRect(origin: .zero, size: srcSize) && finalSize == srcSize {
            // No processing needed - return original
            return self
        }
        
        // Render with orientation transform
        let bitmapInfo: UInt32
        let colorSpace = (self.colorSpace ?? CGColorSpaceCreateDeviceRGB())
        let scale: CGFloat = (mode == .fill ?
            max(finalSize.width / sourceRect.width, finalSize.height / sourceRect.height) :
            min(finalSize.width / sourceRect.width, finalSize.height / sourceRect.height)
        )

        if colorSpace.model == .monochrome {
            bitmapInfo = (opaque ?
                CGImageAlphaInfo.none.rawValue :
                CGImageAlphaInfo.alphaOnly.rawValue
            )
        } else {
            bitmapInfo = (opaque ?
                CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue :
                CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            )
        }
        
        guard let ctx: CGContext = CGContext(
            data: nil,
            width: Int(finalSize.width),
            height: Int(finalSize.height),
            bitsPerComponent: 8,
            bytesPerRow: 0, // Let the system calculate
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return self }
        
        // Transform the context to have the correct orientation, positioning and scale (order matters here)
        let drawRect: CGRect = CGRect(origin: .zero, size: CGSize(width: self.width, height: self.height))
        ctx.interpolationQuality = .high
        ctx.applyOrientationTransform(orientation: orientation, size: finalSize)
        
        // After orientation, we need to translate/scale in the NEW coordinate space
        // For rotated orientations, the coordinate axes are swapped
        let translateX: CGFloat
        let translateY: CGFloat

        switch orientation {
            case .up:
                translateX = -sourceRect.origin.x
                translateY = -(srcSize.height - sourceRect.maxY)
                
            case .upMirrored:
                translateX = -(srcSize.width - sourceRect.maxX)
                translateY = -(srcSize.height - sourceRect.maxY)
                
            case .down:
                translateX = -(srcSize.width - sourceRect.maxX)
                translateY = -sourceRect.origin.y
                
            case .downMirrored:
                translateX = -sourceRect.origin.x
                translateY = -sourceRect.origin.y
            
            case .left:
                translateX = -(srcSize.height - sourceRect.maxY)
                translateY = -(srcSize.width - sourceRect.maxX)
                
            case .leftMirrored:
                translateX = -sourceRect.origin.y
                translateY = -(srcSize.width - sourceRect.maxX)
            
            case .right:
                translateX = -sourceRect.origin.y
                translateY = -sourceRect.origin.x
                
            case .rightMirrored:
                translateX = -(srcSize.height - sourceRect.maxY)
                translateY = -sourceRect.origin.x
                
            @unknown default:
                translateX = -sourceRect.origin.x
                translateY = -sourceRect.origin.y
        }
        
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: translateX, y: translateY)
        ctx.draw(self, in: drawRect, byTiling: false)
        
        return (ctx.makeImage() ?? self)
    }
}

// MARK: - Conveneince

private extension CGContext {
    func applyOrientationTransform(orientation: UIImage.Orientation, size: CGSize) {
        switch orientation {
            case .up: break
            case .down:
                translateBy(x: size.width, y: size.height)
                rotate(by: .pi)
                
            case .left:
                translateBy(x: size.width, y: 0)
                rotate(by: .pi / 2)
                
            case .right:
                translateBy(x: 0, y: size.height)
                rotate(by: -.pi / 2)
                
            case .upMirrored:
                translateBy(x: size.width, y: 0)
                scaleBy(x: -1, y: 1)
                
            case .downMirrored:
                translateBy(x: 0, y: size.height)
                scaleBy(x: 1, y: -1)
                
            case .leftMirrored:
                translateBy(x: size.width, y: 0)
                rotate(by: .pi / 2)
                translateBy(x: size.height, y: 0)
                scaleBy(x: -1, y: 1)
                
            case .rightMirrored:
                translateBy(x: 0, y: size.height)
                rotate(by: -.pi / 2)
                translateBy(x: size.width, y: 0)
                scaleBy(x: -1, y: 1)
                
            @unknown default: break
        }
    }
}
