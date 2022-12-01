// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit

final class InfoBanner: UIView {
    public struct Info: Equatable, Hashable {
        let message: String
        let backgroundColor: ThemeValue
        let messageFont: UIFont
        let messageTintColor: ThemeValue
        let height: CGFloat
        
        // MARK: - Confirmance
        
        public static func == (lhs: InfoBanner.Info, rhs: InfoBanner.Info) -> Bool {
            return (
                lhs.message == rhs.message &&
                lhs.backgroundColor == rhs.backgroundColor &&
                lhs.messageFont == rhs.messageFont &&
                lhs.messageTintColor == rhs.messageTintColor &&
                lhs.height == rhs.height
            )
        }
        
        public func hash(into hasher: inout Hasher) {
            message.hash(into: &hasher)
            backgroundColor.hash(into: &hasher)
            messageFont.hash(into: &hasher)
            messageTintColor.hash(into: &hasher)
            height.hash(into: &hasher)
        }
    }
    
    init(info: Info) {
        super.init(frame: CGRect.zero)
        
        setUpViewHierarchy(info)
    }
    
    override init(frame: CGRect) {
        preconditionFailure("Use init(message:) instead.")
    }
    
    required init?(coder: NSCoder) {
        preconditionFailure("Use init(coder:) instead.")
    }
    
    private func setUpViewHierarchy(_ info: InfoBanner.Info) {
        themeBackgroundColor = info.backgroundColor
        
        let label: UILabel = UILabel()
        label.font = info.messageFont
        label.text = info.message
        label.themeTextColor = info.messageTintColor
        label.textAlignment = .center
        label.lineBreakMode = .byWordWrapping
        label.numberOfLines = 0
        addSubview(label)
        
        label.center(in: self)
        self.set(.height, to: info.height)
    }
}
