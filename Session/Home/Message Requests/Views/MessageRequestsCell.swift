// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import Lucide
import SessionUIKit
import SignalUtilitiesKit

class MessageRequestsCell: UITableViewCell {
    // MARK: - Initialization
    
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        
        setUpViewHierarchy()
        setupLayout()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        
        setUpViewHierarchy()
        setupLayout()
    }
    
    // MARK: - UI
    
    private let iconContainerView: UIView = {
        let result: UIView = UIView()
        result.translatesAutoresizingMaskIntoConstraints = false
        result.clipsToBounds = true
        result.themeBackgroundColor = .conversationButton_unreadBubbleBackground
        result.layer.cornerRadius = (ProfilePictureView.Size.list.viewSize / 2)
        
        return result
    }()
    
    private let iconLabel: UILabel = {
        let result: UILabel = UILabel()
        result.translatesAutoresizingMaskIntoConstraints = false
        result.themeAttributedText = ThemedAttributedString(
            attributedString: Lucide.attributedString(
                icon: .messageSquareWarning,
                size: 26,
                baselineOffset: -1  // Custom offset to look vertically aligned
            )
        )
        .addingAttribute(.themeForegroundColor, value: ThemeValue.conversationButton_unreadBubbleText)
        
        return result
    }()
    
    private let titleLabel: UILabel = {
        let result: UILabel = UILabel()
        result.translatesAutoresizingMaskIntoConstraints = false
        result.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        result.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        result.font = .boldSystemFont(ofSize: Values.mediumFontSize)
        result.text = "sessionMessageRequests".localized()
        result.themeTextColor = .textPrimary
        result.lineBreakMode = .byTruncatingTail
        
        return result
    }()
    
    private let unreadCountView: UIView = {
        let result: UIView = UIView()
        result.translatesAutoresizingMaskIntoConstraints = false
        result.clipsToBounds = true
        result.themeBackgroundColor = .conversationButton_unreadBubbleBackground
        result.layer.cornerRadius = (FullConversationCell.unreadCountViewSize / 2)
        
        return result
    }()
    
    private let unreadCountLabel: UILabel = {
        let result = UILabel()
        result.translatesAutoresizingMaskIntoConstraints = false
        result.font = .boldSystemFont(ofSize: Values.verySmallFontSize)
        result.themeTextColor = .conversationButton_unreadBubbleText
        result.textAlignment = .center
        
        return result
    }()
    
    private func setUpViewHierarchy() {
        themeBackgroundColor = .conversationButton_unreadBackground
        selectedBackgroundView = UIView()
        selectedBackgroundView?.themeBackgroundColor = .highlighted(.conversationButton_unreadBackground)
        
        contentView.addSubview(iconContainerView)
        contentView.addSubview(titleLabel)
        contentView.addSubview(unreadCountView)
        
        iconContainerView.addSubview(iconLabel)
        unreadCountView.addSubview(unreadCountLabel)
    }
    
    // MARK: - Layout
    
    private func setupLayout() {
        NSLayoutConstraint.activate([
            contentView.heightAnchor.constraint(equalToConstant: 68),
            
            iconContainerView.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor,
                // Need 'accentLineThickness' to line up correctly with the 'ConversationCell'
                constant: (Values.accentLineThickness + Values.mediumSpacing)
            ),
            iconContainerView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            iconContainerView.widthAnchor.constraint(equalToConstant: ProfilePictureView.Size.list.viewSize),
            iconContainerView.heightAnchor.constraint(equalToConstant: ProfilePictureView.Size.list.viewSize),
            
            iconLabel.centerXAnchor.constraint(equalTo: iconContainerView.centerXAnchor),
            iconLabel.centerYAnchor.constraint(equalTo: iconContainerView.centerYAnchor),
            
            titleLabel.leadingAnchor.constraint(equalTo: iconContainerView.trailingAnchor, constant: Values.mediumSpacing),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -Values.mediumSpacing),
            titleLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            
            unreadCountView.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: (Values.smallSpacing / 2)),
            unreadCountView.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            unreadCountView.widthAnchor.constraint(greaterThanOrEqualToConstant: FullConversationCell.unreadCountViewSize),
            unreadCountView.heightAnchor.constraint(equalToConstant: FullConversationCell.unreadCountViewSize),
            
            unreadCountLabel.topAnchor.constraint(equalTo: unreadCountView.topAnchor),
            unreadCountLabel.leadingAnchor.constraint(equalTo: unreadCountView.leadingAnchor, constant: 4),
            unreadCountLabel.trailingAnchor.constraint(equalTo: unreadCountView.trailingAnchor, constant: -4),
            unreadCountLabel.bottomAnchor.constraint(equalTo: unreadCountView.bottomAnchor)
        ])
    }
    
    // MARK: - Content
    
    func update(with count: Int) {
        unreadCountLabel.text = "\(count)"
        unreadCountView.isHidden = (count <= 0)
    }
}
