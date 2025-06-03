// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit

public extension UIImage {
    func withTint(_ color: UIColor) -> UIImage? {
        let template = self.withRenderingMode(.alwaysTemplate)
        let imageView = UIImageView(image: template)
        imageView.themeTintColorForced = .color(color)
        
        return imageView.toImage(isOpaque: imageView.isOpaque, scale: UIScreen.main.scale)
    }
}

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
