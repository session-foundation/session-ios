// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit

class SessionHeaderView: UITableViewHeaderFooterView {
    // MARK: - UI
    
    private lazy var titleLabelConstraints: [NSLayoutConstraint] = [
        titleLabel.pin(.top, to: .top, of: self, withInset: Values.mediumSpacing),
        titleLabel.pin(.bottom, to: .bottom, of: self, withInset: -Values.mediumSpacing)
    ]
    private lazy var titleLabelLeadingConstraint: NSLayoutConstraint = titleLabel.pin(.leading, to: .leading, of: self)
    private lazy var titleLabelTrailingConstraint: NSLayoutConstraint = titleLabel.pin(.trailing, to: .trailing, of: self)
    private lazy var titleSeparatorLeadingConstraint: NSLayoutConstraint = titleSeparator.pin(.leading, to: .leading, of: self)
    private lazy var titleSeparatorTrailingConstraint: NSLayoutConstraint = titleSeparator.pin(.trailing, to: .trailing, of: self)
    
    private let titleLabel: UILabel = {
        let result: UILabel = UILabel()
        result.translatesAutoresizingMaskIntoConstraints = false
        result.font = .systemFont(ofSize: Values.mediumFontSize)
        result.themeTextColor = .textSecondary
        result.isHidden = true
        
        return result
    }()
    
    private let titleSeparator: Separator = {
        let result: Separator = Separator()
        result.isHidden = true
        
        return result
    }()
    
    private let loadingIndicator: UIActivityIndicatorView = {
        let result: UIActivityIndicatorView = UIActivityIndicatorView(style: .medium)
        result.themeTintColor = .textPrimary
        result.alpha = 0.5
        result.startAnimating()
        result.hidesWhenStopped = true
        result.isHidden = true
        
        return result
    }()
    
    // MARK: - Initialization
    
    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        
        self.backgroundView = UIView()
        self.backgroundView?.themeBackgroundColor = .backgroundPrimary
        
        addSubview(titleLabel)
        addSubview(titleSeparator)
        addSubview(loadingIndicator)
        
        setupLayout()
    }
    
    required init?(coder: NSCoder) {
        fatalError("use init(reuseIdentifier:) instead")
    }
    
    private func setupLayout() {
        titleLabel.pin(.top, to: .top, of: self, withInset: Values.mediumSpacing)
        titleLabel.pin(.bottom, to: .bottom, of: self, withInset: Values.mediumSpacing)
        titleLabel.center(.vertical, in: self)
        
        titleSeparator.center(.vertical, in: self)
        loadingIndicator.center(in: self)
    }
    
    // MARK: - Content
    
    override func prepareForReuse() {
        super.prepareForReuse()
        
        titleLabel.isHidden = true
        titleSeparator.isHidden = true
        loadingIndicator.isHidden = true
        
        titleLabelLeadingConstraint.isActive = false
        titleLabelTrailingConstraint.isActive = false
        titleLabelConstraints.forEach { $0.isActive = false }
        
        titleSeparator.center(.vertical, in: self)
        titleSeparatorLeadingConstraint.isActive = false
        titleSeparatorTrailingConstraint.isActive = false
    }
    
    public func update(
        title: String?,
        style: SessionTableSectionStyle = .titleRoundedContent
    ) {
        let titleIsEmpty: Bool = (title ?? "").isEmpty
        
        switch style {
            case .titleRoundedContent, .titleEdgeToEdgeContent, .titleNoBackgroundContent:
                titleLabel.text = title
                titleLabel.isHidden = titleIsEmpty
                titleLabelLeadingConstraint.constant = style.edgePadding
                titleLabelTrailingConstraint.constant = -style.edgePadding
                titleLabelLeadingConstraint.isActive = !titleIsEmpty
                titleLabelTrailingConstraint.isActive = !titleIsEmpty
                titleLabelConstraints.forEach { $0.isActive = true }
                
            case .titleSeparator:
                titleSeparator.update(title: title)
                titleSeparator.isHidden = false
                titleSeparatorLeadingConstraint.constant = style.edgePadding
                titleSeparatorTrailingConstraint.constant = -style.edgePadding
                titleSeparatorLeadingConstraint.isActive = !titleIsEmpty
                titleSeparatorTrailingConstraint.isActive = !titleIsEmpty
                
            case .none, .padding: break
            case .loadMore: loadingIndicator.isHidden = false
        }
        
        self.layoutIfNeeded()
    }
}
