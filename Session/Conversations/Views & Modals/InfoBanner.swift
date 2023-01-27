// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit

final class InfoBanner: UIView {
    init(message: String, backgroundColor: ThemeValue, messageLabelAccessibilityLabel: String? = nil) {
        super.init(frame: CGRect.zero)
        
        setUpViewHierarchy(message: message, backgroundColor: backgroundColor, messageLabelAccessibilityLabel: messageLabelAccessibilityLabel)
    }
    
    override init(frame: CGRect) {
        preconditionFailure("Use init(message:) instead.")
    }
    
    required init?(coder: NSCoder) {
        preconditionFailure("Use init(coder:) instead.")
    }
    
    private func setUpViewHierarchy(message: String, backgroundColor: ThemeValue, messageLabelAccessibilityLabel: String?) {
        themeBackgroundColor = backgroundColor
        
        let label: UILabel = UILabel()
        label.accessibilityLabel = messageLabelAccessibilityLabel
        label.font = .boldSystemFont(ofSize: Values.smallFontSize)
        label.text = message
        label.themeTextColor = .textPrimary
        label.textAlignment = .center
        label.lineBreakMode = .byWordWrapping
        label.numberOfLines = 0
        addSubview(label)
        
        label.pin(to: self, withInset: Values.mediumSpacing)
    }
}
