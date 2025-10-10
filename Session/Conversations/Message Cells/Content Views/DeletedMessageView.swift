// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import Lucide
import SessionUIKit
import SignalUtilitiesKit
import SessionMessagingKit
import SessionUtilitiesKit

final class DeletedMessageView: UIView {
    private static let iconSize: CGFloat = 18
    private static let iconImageViewSize: CGFloat = 30
    private static let horizontalInset = Values.mediumSmallSpacing
    private static let verticalInset = Values.smallSpacing
    
    // MARK: - Lifecycle
    
    init(textColor: ThemeValue, variant: Interaction.Variant, maxWidth: CGFloat) {
        super.init(frame: CGRect.zero)
        accessibilityIdentifier = "Deleted message"
        isAccessibilityElement = true
        setUpViewHierarchy(textColor: textColor, variant: variant, maxWidth: maxWidth)
    }
    
    override init(frame: CGRect) {
        preconditionFailure("Use init(textColor:) instead.")
    }
    
    required init?(coder: NSCoder) {
        preconditionFailure("Use init(textColor:) instead.")
    }
    
    private func setUpViewHierarchy(textColor: ThemeValue, variant: Interaction.Variant, maxWidth: CGFloat) {
        let imageView = LucideIconView(icon: .trash2, size: DeletedMessageView.iconSize)
        imageView.themeTintColor = textColor
        imageView.alpha = Values.highOpacity
        imageView.contentMode = .scaleAspectFit
        imageView.set(.width, to: DeletedMessageView.iconSize)
        imageView.set(.height, to: DeletedMessageView.iconSize)
        
        let imageViewContainer: UIView = UIView()
        imageViewContainer.addSubview(imageView)
        imageView.center(.vertical, in: imageViewContainer)
        imageView.pin(.leading, to: .leading, of: imageViewContainer)
        imageView.pin(.trailing, to: .trailing, of: imageViewContainer)
        
        // Body label
        let titleLabel = UILabel()
        titleLabel.setContentHuggingPriority(.required, for: .vertical)
        titleLabel.font = .italicSystemFont(ofSize: Values.mediumFontSize)
        titleLabel.text = {
            switch variant {
                case .standardIncomingDeletedLocally, .standardOutgoingDeletedLocally:
                    return "deleteMessageDeletedLocally".localized()
                
                default: return "deleteMessageDeletedGlobally".localized()
            }
        }()
        titleLabel.themeTextColor = textColor
        titleLabel.alpha = Values.highOpacity
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.numberOfLines = 2
        titleLabel.setContentHugging(.vertical, to: .required)
        titleLabel.setCompressionResistance(.vertical, to: .required)
        
        // Stack view
        let stackView = UIStackView(arrangedSubviews: [
            imageViewContainer,
            titleLabel
        ])
        stackView.axis = .horizontal
        stackView.alignment = .fill
        stackView.spacing = Values.smallSpacing
        stackView.isLayoutMarginsRelativeArrangement = true
        stackView.layoutMargins = UIEdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 6)
        addSubview(stackView)
        
        stackView.pin(.top, to: .top, of: self, withInset: Self.verticalInset)
        stackView.pin(.leading, to: .leading, of: self, withInset: Self.horizontalInset)
        stackView.pin(.trailing, to: .trailing, of: self, withInset: -Self.horizontalInset)
        stackView.pin(.bottom, to: .bottom, of: self, withInset: -Self.verticalInset)
        stackView.setContentHugging(.vertical, to: .required)
        stackView.setCompressionResistance(.vertical, to: .required)
    }
}
