// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import UIKit

public extension UIAlertAction {
    convenience init(title: String?, accessibilityIdentifier: String, style: UIAlertAction.Style, handler: ((UIAlertAction) -> Void)?) {
        self.init(title: title, style: style, handler: handler)
        
        self.accessibilityIdentifier = accessibilityIdentifier
    }
}
