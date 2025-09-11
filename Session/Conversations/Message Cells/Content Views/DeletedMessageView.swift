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
        let trashIcon = Lucide.image(icon: .trash2, size: DeletedMessageView.iconSize)?
            .withRenderingMode(.alwaysTemplate)
        
        let imageView = UIImageView(image: trashIcon)
        imageView.themeTintColor = textColor
        imageView.alpha = Values.highOpacity
        imageView.contentMode = .scaleAspectFit
        imageView.set(.width, to: DeletedMessageView.iconSize)
        imageView.set(.height, to: DeletedMessageView.iconSize)
        
        // Body label
        let titleLabel = UILabel()
        titleLabel.setContentHuggingPriority(.required, for: .vertical)
        titleLabel.preferredMaxLayoutWidth = maxWidth - 6   // `6` for the `stackView.layoutMargins`
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
        
        // Stack view
        let stackView = UIStackView(arrangedSubviews: [
            imageView,
            titleLabel
        ])
        stackView.axis = .horizontal
        stackView.alignment = .center
        stackView.spacing = Values.smallSpacing
        stackView.isLayoutMarginsRelativeArrangement = true
        stackView.layoutMargins = UIEdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 6)
        addSubview(stackView)
        
        let calculatedSize: CGSize = stackView.systemLayoutSizeFitting(CGSize(width: maxWidth, height: 999))
        
        stackView.pin(.top, to: .top, of: self, withInset: Self.verticalInset)
        stackView.pin(.leading, to: .leading, of: self, withInset: Self.horizontalInset)
        stackView.pin(.trailing, to: .trailing, of: self, withInset: -Self.horizontalInset)
        stackView.pin(.bottom, to: .bottom, of: self, withInset: -Self.verticalInset)
        
        stackView.set(.height, to: calculatedSize.height)
    }
}
