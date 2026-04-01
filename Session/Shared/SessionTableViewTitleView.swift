// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit

final class SessionTableViewTitleView: UIView {
    private static let maxWidth: CGFloat = UIScreen.main.bounds.width - 44 * 2 - 16 * 2
    private var oldSize: CGSize = .zero
    
    override var intrinsicContentSize: CGSize {
        let maxWidth: CGFloat = Self.maxWidth
        let titleHeight: CGFloat = titleLabel.sizeThatFits(
            CGSize(width: maxWidth, height: .greatestFiniteMagnitude)
        ).height
        let subtitleHeight: CGFloat = subtitleLabel.isHidden ? 0 : subtitleLabel.sizeThatFits(
            CGSize(width: maxWidth, height: .greatestFiniteMagnitude)
        ).height
        let spacing: CGFloat = (subtitleLabel.isHidden ? 0 : stackView.spacing)
        
        return CGSize(
            width: UIView.noIntrinsicMetric,
            height: titleHeight + subtitleHeight + spacing
        )
    }

    // MARK: - UI Components
    
    private lazy var titleLabel: UILabel = {
        let result: UILabel = UILabel()
        result.setContentCompressionResistancePriority(.required, for: .vertical)
        result.font = .boldSystemFont(ofSize: Values.mediumFontSize)
        result.themeTextColor = .textPrimary
        result.lineBreakMode = .byTruncatingTail
        
        return result
    }()

    private lazy var subtitleLabel: UILabel = {
        let result: UILabel = UILabel()
        result.font = .systemFont(ofSize: Values.miniFontSize)
        result.themeTextColor = .textPrimary
        result.lineBreakMode = .byWordWrapping
        result.numberOfLines = 0
        result.textAlignment = .center
        result.set(.width, lessThanOrEqualTo: Self.maxWidth)
        
        return result
    }()
    
    private lazy var stackView: UIStackView = {
        let result = UIStackView(arrangedSubviews: [ titleLabel, subtitleLabel ])
        result.axis = .vertical
        result.alignment = .center
        result.spacing = 2
        
        return result
    }()
    
    // MARK: - Initialization
    
    init() {
        super.init(frame: .zero)
        
        clipsToBounds = false
        addSubview(stackView)
        
        stackView.pin(.top, to: .top, of: self)
        stackView.pin(.leading, to: .leading, of: self)
        stackView.pin(.trailing, to: .trailing, of: self)
        stackView.pin(.bottom, to: .bottom, of: self)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    required init?(coder: NSCoder) {
        preconditionFailure("Use init() instead.")
    }

    // MARK: - Content
    
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let constrainedWidth: CGFloat = min(size.width, Self.maxWidth)
        let constrainedSize = CGSize(width: constrainedWidth, height: .greatestFiniteMagnitude)
        let titleHeight: CGFloat = titleLabel.sizeThatFits(constrainedSize).height
        let subtitleHeight: CGFloat = (subtitleLabel.isHidden ?
            0 :
            subtitleLabel.sizeThatFits(constrainedSize).height
        )
        let spacing: CGFloat = (subtitleLabel.isHidden ? 0 : stackView.spacing)
        
        return CGSize(width: size.width, height: titleHeight + subtitleHeight + spacing)
    }
    
    public func update(title: String, subtitle: String?) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.update(title: title, subtitle: subtitle)
            }
            return
        }
        
        self.titleLabel.text = title
        self.titleLabel.font = .boldSystemFont(
            ofSize: (subtitle?.isEmpty == false ?
                Values.largeFontSize :
                Values.veryLargeFontSize
            )
        )
        
        self.subtitleLabel.text = (subtitle ?? "")
        self.subtitleLabel.isHidden = (self.subtitleLabel.text?.isEmpty != false)
        
        invalidateIntrinsicContentSize()
    }
}
