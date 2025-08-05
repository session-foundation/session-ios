// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit

public extension UIImage.Orientation {
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

public extension UIImage {
    func withLinearGradient(
        colors: [UIColor] = [
            Theme.PrimaryColor.green.color,
            Theme.PrimaryColor.blue.color,
            Theme.PrimaryColor.purple.color,
            Theme.PrimaryColor.pink.color,
            Theme.PrimaryColor.red.color,
            Theme.PrimaryColor.orange.color,
            Theme.PrimaryColor.yellow.color
        ],
        startPoint: CGPoint = CGPoint(x: 0, y: 0),
        endPoint: CGPoint = CGPoint(x: 0, y: 1)
    ) -> UIImage? {
        UIGraphicsBeginImageContextWithOptions(size, false, scale)
        guard let context = UIGraphicsGetCurrentContext() else { return nil }

        // Draw the image as the base
        draw(at: .zero)
        
        // Set up the gradient
        let cgColors = colors.map { $0.cgColor } as CFArray
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: cgColors,
            locations: nil
        ) else {
            UIGraphicsEndImageContext()
            return nil
        }
        
        // Calculate points in pixels
        let sPoint = CGPoint(x: startPoint.x * size.width, y: startPoint.y * size.height)
        let ePoint = CGPoint(x: endPoint.x * size.width, y: endPoint.y * size.height)
        
        // Set blend mode so gradient overlays (not replaces) image
        context.saveGState()
        context.setBlendMode(.sourceAtop)
        context.drawLinearGradient(gradient, start: sPoint, end: ePoint, options: [])
        context.restoreGState()
        
        let imageWithGradient = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return imageWithGradient
    }
}
