// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit

public extension UIView {
    enum CachedImageKey: Equatable, Hashable {
        case key(String)
        case themedKey(String, themeBackgroundColor: ThemeValue)
        
        fileprivate var value: String {
            switch self {
                case .key(let value): return value
                case .themedKey(let value, let color):
                    let cacheKeyColour: String = (color == .primary ? "\(ThemeManager.primaryColor)" : "\(color)" )
                    
                    return "\(value).\(cacheKeyColour)" // stringlint:ignore
            }
        }
    }
    
    static func image(
        for key: CachedImageKey,
        generator: () -> UIView
    ) -> UIImage {
        let cacheKey: NSString = key.value as NSString // stringlint:ignore
        
        if let cachedImage = SNUIKit.imageCache.object(forKey: cacheKey) {
            return cachedImage
        }
        
        let generatedView: UIView = generator()
        let renderedImage: UIImage = generatedView.toImage(isOpaque: generatedView.isOpaque, scale: UIScreen.main.scale)
        SNUIKit.imageCache.setObject(renderedImage, forKey: cacheKey)
        return renderedImage
    }

    func toImage(isOpaque: Bool, scale: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = isOpaque
        
        let renderer = UIGraphicsImageRenderer(bounds: self.bounds, format: format)
        
        return renderer.image { context in
            self.layer.render(in: context.cgContext)
        }
    }
    
    class func spacer(withWidth width: CGFloat) -> UIView {
        let view = UIView()
        view.set(.width, to: width)
        return view
    }

    class func spacer(withHeight height: CGFloat) -> UIView {
        let view = UIView()
        view.set(.height, to: height)
        return view
    }

    class func hStretchingSpacer() -> UIView {
        let view = UIView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(UILayoutPriority(0), for: .horizontal)
        
        return view
    }

    class func vStretchingSpacer() -> UIView {
        let view = UIView()
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(UILayoutPriority(0), for: .vertical)
        
        return view
    }
    
    static func hSpacer(_ width: CGFloat) -> UIView {
        let result: UIView = UIView()
        result.set(.width, to: width)
        
        return result
    }

    static func vSpacer(_ height: CGFloat) -> UIView {
        let result: UIView = UIView()
        result.set(.height, to: height)
        
        return result
    }
    
    static func vhSpacer(_ width: CGFloat, _ height: CGFloat) -> UIView {
        let result: UIView = UIView()
        result.set(.width, to: width)
        result.set(.height, to: height)
        
        return result
    }

    static func separator() -> UIView {
        let result: UIView = UIView()
        result.set(.height, to: Values.separatorThickness)
        result.themeBackgroundColor = .borderSeparator
        
        return result
    }
    
    static func line() -> UIView {
        let result: UIView = UIView()
        result.set(.height, to: 1)
        result.themeBackgroundColor = .borderSeparator
        
        return result
    }
}
