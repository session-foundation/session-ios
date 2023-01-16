// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit
import SessionUtilitiesKit

extension ContextMenuVC {
    final class MessageInfoView: UIView {
        private static let cornerRadius: CGFloat = 8
        
        private let cellViewModel: MessageViewModel
        
        // MARK: - UI
        
        private lazy var messageSentDateLabel: UILabel = {
            let result: UILabel = UILabel()
            result.font = .systemFont(ofSize: Values.mediumFontSize)
            result.themeTextColor = .textPrimary
            
            return result
        }()
        
        private lazy var messageReceivedDateLabel: UILabel = {
            let result: UILabel = UILabel()
            result.font = .systemFont(ofSize: Values.mediumFontSize)
            result.themeTextColor = .textPrimary
            
            return result
        }()
        
        private lazy var profilePictureView: ProfilePictureView = {
            let result: ProfilePictureView = ProfilePictureView()
            result.set(.height, to: Values.verySmallProfilePictureSize)
            result.size = Values.verySmallProfilePictureSize
            
            return result
        }()
        
        private lazy var displayNameLabel: UILabel = {
            let result: UILabel = UILabel()
            result.font = .systemFont(ofSize: Values.verySmallFontSize)
            result.themeTextColor = .textPrimary
            
            return result
        }()
        
        private lazy var sessionIDLabel: UILabel = {
            let result: UILabel = UILabel()
            result.font = .systemFont(ofSize: Values.verySmallFontSize)
            result.themeTextColor = .textPrimary
            
            return result
        }()
        
        // MARK: - Lifecycle
        
        init(cellViewModel: MessageViewModel) {
            self.cellViewModel = cellViewModel
            
            super.init(frame: CGRect.zero)
            self.accessibilityLabel = "Message info"
            setUpViewHierarchy()
        }

        override init(frame: CGRect) {
            preconditionFailure("Use init(cellViewModel:) instead.")
        }

        required init?(coder: NSCoder) {
            preconditionFailure("Use init(cellViewModel:) instead.")
        }

        private func setUpViewHierarchy() {
            let backgroundView: UIView = UIView()
            backgroundView.clipsToBounds = true
            backgroundView.themeBackgroundColor = .contextMenu_background
            backgroundView.layer.cornerRadius = Self.cornerRadius
            addSubview(backgroundView)
            backgroundView.pin(to: self)
            
            let stackView: UIStackView = UIStackView()
            stackView.axis = .vertical
            backgroundView.addSubview(stackView)
            stackView.pin(to: backgroundView)
            
            
        }
    }
}
