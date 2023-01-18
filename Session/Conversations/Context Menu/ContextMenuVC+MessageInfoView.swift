// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit
import SessionUtilitiesKit

extension ContextMenuVC {
    final class MessageInfoView: UIView {
        private static let cornerRadius: CGFloat = 8
        
        private let cellViewModel: MessageViewModel
        private let dismissAction: () -> Void
        
        // MARK: - UI
        
        private lazy var dismissButton: UIButton = {
            let result: UIButton = UIButton(type: .custom)
            result.setImage(
                UIImage(named: "small_chevron_left")?
                    .withRenderingMode(.alwaysTemplate),
                for: .normal
            )
            result.addTarget(self, action: #selector(dismiss), for: UIControl.Event.touchUpInside)
            result.themeTintColor = .white
            result.set(.width, to: 20)
            result.set(.height, to: 20)
            
            return result
        }()
        
        private lazy var messageSentDateLabel: UILabel = {
            let result: UILabel = UILabel()
            result.font = .systemFont(ofSize: Values.smallFontSize)
            result.themeTextColor = .textPrimary
            result.numberOfLines = 0
            
            return result
        }()
        
        private lazy var messageReceivedDateLabel: UILabel = {
            let result: UILabel = UILabel()
            result.font = .systemFont(ofSize: Values.smallFontSize)
            result.themeTextColor = .textPrimary
            result.numberOfLines = 0
            
            return result
        }()
        
        private lazy var profilePictureView: ProfilePictureView = {
            let result: ProfilePictureView = ProfilePictureView()
            result.set(.height, to: Values.smallProfilePictureSize)
            result.size = Values.smallProfilePictureSize
            
            return result
        }()
        
        private lazy var displayNameLabel: UILabel = {
            let result: UILabel = UILabel()
            result.font = .boldSystemFont(ofSize: Values.smallFontSize)
            result.themeTextColor = .textPrimary
            
            return result
        }()
        
        private lazy var sessionIDLabel: UILabel = {
            let result: UILabel = UILabel()
            result.font = .systemFont(ofSize: Values.verySmallFontSize)
            result.themeTextColor = .textPrimary
            result.numberOfLines = 0
            result.lineBreakMode = .byCharWrapping
            
            return result
        }()
        
        // MARK: - Lifecycle
        
        init(cellViewModel: MessageViewModel, dismissAction: @escaping () -> Void) {
            self.cellViewModel = cellViewModel
            self.dismissAction = dismissAction
            
            super.init(frame: CGRect.zero)
            self.accessibilityLabel = "Message info"
            setUpViewHierarchy()
        }

        override init(frame: CGRect) {
            preconditionFailure("Use init(cellViewModel:dismiss:) instead.")
        }

        required init?(coder: NSCoder) {
            preconditionFailure("Use init(cellViewModel:dismiss:) instead.")
        }

        private func setUpViewHierarchy() {
            addSubview(dismissButton)
            dismissButton.pin(.top, to: .top, of: self, withInset: Values.smallSpacing)
            dismissButton.pin(.leading, to: .leading, of: self)
            
            let backgroundView: UIView = UIView()
            backgroundView.clipsToBounds = true
            backgroundView.themeBackgroundColor = .contextMenu_background
            backgroundView.layer.cornerRadius = Self.cornerRadius
            addSubview(backgroundView)
            backgroundView.pin([ UIView.HorizontalEdge.trailing, UIView.VerticalEdge.top, UIView.VerticalEdge.bottom ], to: self)
            backgroundView.pin(.leading, to: .trailing, of: dismissButton)
            
            let stackView: UIStackView = UIStackView()
            stackView.axis = .vertical
            stackView.spacing = Values.smallSpacing
            backgroundView.addSubview(stackView)
            stackView.pin(to: backgroundView, withInset: Values.mediumSpacing)
            
            messageSentDateLabel.text = "MESSAGE_INFO_SENT".localized() + ":\n" + cellViewModel.dateForUI.fromattedForMessageInfo
            stackView.addArrangedSubview(messageSentDateLabel)
            
            messageReceivedDateLabel.text = "MESSAGE_INFO_RECEIVED".localized() + ":\n" + cellViewModel.receivedDateForUI.fromattedForMessageInfo
            stackView.addArrangedSubview(messageReceivedDateLabel)
            
            let senderTitleLabel: UILabel = {
                let result: UILabel = UILabel()
                result.font = .systemFont(ofSize: Values.smallFontSize)
                result.themeTextColor = .textPrimary
                result.text = "MESSAGE_INFO_FROM".localized() + ":"
                
                return result
            }()

            displayNameLabel.text = cellViewModel.authorName
            sessionIDLabel.text = cellViewModel.authorId
            profilePictureView.update(
                publicKey: cellViewModel.authorId,
                profile: cellViewModel.profile,
                threadVariant: cellViewModel.threadVariant
            )
            
            let profileContainerView: UIView = UIView()
            profileContainerView.addSubview(senderTitleLabel)
            senderTitleLabel.pin([ UIView.HorizontalEdge.leading, UIView.HorizontalEdge.trailing, UIView.VerticalEdge.top ], to: profileContainerView)
            profileContainerView.addSubview(profilePictureView)
            profilePictureView.pin(.leading, to: .leading, of: profileContainerView)
            profilePictureView.pin(.top, to: .bottom, of: senderTitleLabel, withInset: Values.mediumSpacing)
            profilePictureView.pin(.bottom, to: .bottom, of: profileContainerView, withInset: -Values.verySmallSpacing)
            
            let infoContainerStackView: UIStackView = UIStackView(arrangedSubviews: [ displayNameLabel, sessionIDLabel ])
            infoContainerStackView.axis = .vertical
            profileContainerView.addSubview(infoContainerStackView)
            infoContainerStackView.pin(.leading, to: .trailing, of: profilePictureView, withInset: Values.mediumSpacing)
            infoContainerStackView.pin(.trailing, to: .trailing, of: profileContainerView)
            infoContainerStackView.pin(.bottom, to: .bottom, of: profileContainerView)
            infoContainerStackView.set(.width, to: 240)
            
            stackView.addArrangedSubview(profileContainerView)
            
        }
        
        // MARK: - Interaction
        
        @objc private func dismiss() {
            dismissAction()
        }
    }
}
