// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit
import SessionUtilitiesKit

extension UIView {
    func toImage(cacheKey: String, using dependencies: Dependencies) -> UIImage {
        let themePrimaryColor: Theme.PrimaryColor = dependencies
            .mutate(cache: .libSession) { $0.get(.themePrimaryColor) }
            .defaulting(to: .defaultPrimaryColor)
        let themeBackgroundColor = self.themeBackgroundColor.defaulting(to: .primary)
        let cacheKeyColour: String = (
            themeBackgroundColor == .primary ? "\(themePrimaryColor)" : "\(themeBackgroundColor)"
        )
        let cacheKey: NSString = "\(cacheKey).\(cacheKeyColour)" as NSString // stringlint:ignore
        
        if let cachedImage = General.UICache.object(forKey: cacheKey) {
            return cachedImage
        }
        
        let renderedImage = self.toImage(isOpaque: self.isOpaque, scale: UIScreen.main.scale)
        General.UICache.setObject(renderedImage, forKey: cacheKey)
        return renderedImage
    }
}
