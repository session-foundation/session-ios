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
            result.font = .boldSystemFont(ofSize: Values.verySmallFontSize)
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
            
            messageSentDateLabel.text = "MESSAGE_INFO_SENT".localized() + ":\n" + cellViewModel.dateForUI.fromattedForMessageInfo
            stackView.addArrangedSubview(messageSentDateLabel)
            
            messageReceivedDateLabel.text = "MESSAGE_INFO_RECEIVED".localized() + ":\n" + cellViewModel.receivedDateForUI.fromattedForMessageInfo
            stackView.addArrangedSubview(messageReceivedDateLabel)
            
            let senderTitleLabel: UILabel = {
                let result: UILabel = UILabel()
                result.font = .systemFont(ofSize: Values.mediumFontSize)
                result.themeTextColor = .textPrimary
                result.text = "MESSAGE_INFO_FROM".localized() + ":"
                
                return result
            }()
            stackView.addArrangedSubview(senderTitleLabel)
            
            let displayNameStackView: UIStackView = UIStackView(arrangedSubviews: [ displayNameLabel, sessionIDLabel ])
            displayNameStackView.axis = .vertical
            displayNameLabel.text = cellViewModel.authorName
            sessionIDLabel.text = cellViewModel.authorId
            
            let profileStackView: UIStackView = UIStackView(arrangedSubviews: [ profilePictureView, displayNameStackView ])
            profileStackView.axis = .horizontal
            profilePictureView.update(
                publicKey: cellViewModel.authorId,
                profile: cellViewModel.profile,
                threadVariant: cellViewModel.threadVariant
            )
            stackView.addArrangedSubview(profileStackView)
        }
    }
}
