// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit
import SessionUtilitiesKit

extension MediaInfoVC {
    final class MediaPreviewView: UIView {
        private static let cornerRadius: CGFloat = 8
        
        private let attachment: Attachment
        
        // MARK: - UI
        
        private lazy var fullScreenButton: UIButton = {
            let result: UIButton = UIButton(type: .custom)
            
            return result
        }()
        
        // MARK: - Lifecycle
        
        init(attachment: Attachment) {
            self.attachment = attachment
            
            super.init(frame: CGRect.zero)
            self.accessibilityLabel = "Media info"
            setUpViewHierarchy()
        }

        override init(frame: CGRect) {
            preconditionFailure("Use init(attachment:) instead.")
        }

        required init?(coder: NSCoder) {
            preconditionFailure("Use init(attachment:) instead.")
        }

        private func setUpViewHierarchy() {
            
        }
        
    }
}
