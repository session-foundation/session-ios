// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit

final class InfoBanner: UIView {
    public struct Info: Equatable, Hashable {
        let message: String
        let backgroundColor: ThemeValue
        let messageFont: UIFont
        let messageTintColor: ThemeValue
        let messageLabelAccessibilityLabel: String?
        let height: CGFloat
        
        func with(
            message: String? = nil,
            backgroundColor: ThemeValue? = nil,
            messageFont: UIFont? = nil,
            messageTintColor: ThemeValue? = nil,
            messageLabelAccessibilityLabel: String? = nil,
            height: CGFloat? = nil
        ) -> Info {
            return Info(
                message: message ?? self.message,
                backgroundColor: backgroundColor ?? self.backgroundColor,
                messageFont: messageFont ?? self.messageFont,
                messageTintColor: messageTintColor ?? self.messageTintColor,
                messageLabelAccessibilityLabel: messageLabelAccessibilityLabel ?? self.messageLabelAccessibilityLabel,
                height: height ?? self.height
            )
        }
    }
    
    private lazy var label: UILabel = {
        let result: UILabel = UILabel()
        result.textAlignment = .center
        result.lineBreakMode = .byWordWrapping
        result.numberOfLines = 0
        result.isAccessibilityElement = true
        
        return result
    }()
    
    public var info: Info?
    
    // MARK: - Initialization
    
    init(info: Info) {
        super.init(frame: CGRect.zero)
        addSubview(label)
        label.pin(to: self)
        self.set(.height, to: info.height)
        self.update(info)
    }
    
    override init(frame: CGRect) {
        preconditionFailure("Use init(message:) instead.")
    }
    
    required init?(coder: NSCoder) {
        preconditionFailure("Use init(coder:) instead.")
    }
    
    // MARK: Update
    
    private func update(_ info: InfoBanner.Info) {
        self.info = info
        
        themeBackgroundColor = info.backgroundColor
        
        label.font = info.messageFont
        label.text = info.message
        label.themeTextColor = info.messageTintColor
        label.accessibilityLabel = info.messageLabelAccessibilityLabel
    }
    
    public func update(
        message: String? = nil,
        backgroundColor: ThemeValue? = nil,
        messageFont: UIFont? = nil,
        messageTintColor: ThemeValue? = nil,
        messageLabelAccessibilityLabel: String? = nil,
        height: CGFloat? = nil
    ) {
        if let updatedInfo = self.info?.with(
            message: message,
            backgroundColor: backgroundColor,
            messageFont: messageFont,
            messageTintColor: messageTintColor,
            messageLabelAccessibilityLabel: messageLabelAccessibilityLabel,
            height: height
        ) {
            self.update(updatedInfo)
        }
    }
}
