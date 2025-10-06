// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import UIKit

public class HighlightMentionView: UIView {
    let backgroundPadding: CGFloat
    
    lazy var label: UILabel = {
        let result = UILabel()
        result.numberOfLines = 1
        return result
    }()
    
    public init(
        mentionText: String,
        font: UIFont,
        themeTextColor: ThemeValue,
        themeBackgroundColor: ThemeValue,
        backgroundCornerRadius: CGFloat,
        backgroundPadding: CGFloat
    ) {
        self.backgroundPadding = backgroundPadding
        super.init(frame: .zero)
        
        self.isOpaque = false
        self.label.text = mentionText
        self.label.themeTextColor = themeTextColor
        self.label.font = font
        
        self.addSubview(self.label)
        self.themeBackgroundColor = themeBackgroundColor
        self.label.pin(to: self, withInset: backgroundPadding)
        self.layer.cornerRadius = backgroundCornerRadius
        
        let maxSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: label.font.lineHeight)
        let size = self.label.sizeThatFits(maxSize)
        self.label.frame = CGRect(
            origin: CGPoint(
                x: self.backgroundPadding,
                y: self.backgroundPadding
            ),
            size: size
        )
        self.frame.size = CGSize(
            width: size.width + 2 * self.backgroundPadding,
            height: size.height + 2 * self.backgroundPadding
        )
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
