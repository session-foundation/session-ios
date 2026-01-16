// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit

class SessionHeaderView: UITableViewHeaderFooterView {
    // MARK: - UI
    
    private var titleLabelLeadingConstraint: NSLayoutConstraint?
    private var titleLabelTrailingConstraint: NSLayoutConstraint?
    private var titleSeparatorLeadingConstraint: NSLayoutConstraint?
    private var titleSeparatorTrailingConstraint: NSLayoutConstraint?
    
    private let titleLabel: UILabel = {
        let result: UILabel = UILabel()
        result.translatesAutoresizingMaskIntoConstraints = false
        result.font = Fonts.Body.baseRegular
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
        result.themeColor = .textPrimary
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
        
        contentView.addSubview(titleLabel)
        contentView.addSubview(titleSeparator)
        contentView.addSubview(loadingIndicator)
        
        setupLayout()
    }
    
    required init?(coder: NSCoder) {
        fatalError("use init(reuseIdentifier:) instead")
    }
    
    private func setupLayout() {
        titleLabel.pin(.top, to: .top, of: contentView, withInset: Values.mediumSpacing)
        titleLabelLeadingConstraint = titleLabel.pin(.leading, to: .leading, of: contentView)
        titleLabelTrailingConstraint = titleLabel
            .pin(.trailing, to: .trailing, of: contentView)
            .setting(priority: .defaultHigh)
        titleLabel
            .pin(.bottom, to: .bottom, of: contentView, withInset: -Values.mediumSpacing)
            .setting(priority: .defaultHigh)
        
        titleSeparator.center(.vertical, in: contentView)
        titleSeparatorLeadingConstraint = titleSeparator.pin(.leading, to: .leading, of: contentView)
        titleSeparatorTrailingConstraint = titleSeparator
            .pin(.trailing, to: .trailing, of: contentView)
            .setting(priority: .defaultHigh)
        
        loadingIndicator.center(in: contentView)
    }
    
    // MARK: - Content
    
    override func prepareForReuse() {
        super.prepareForReuse()
        
        titleLabel.isHidden = true
        titleSeparator.isHidden = true
        loadingIndicator.isHidden = true
    }
    
    public func update(
        title: String?,
        style: SessionTableSectionStyle = .titleRoundedContent
    ) {
        let titleIsEmpty: Bool = (title ?? "").isEmpty
        titleLabelLeadingConstraint?.constant = style.edgePadding
        titleLabelTrailingConstraint?.constant = -style.edgePadding
        titleSeparatorLeadingConstraint?.constant = style.edgePadding
        titleSeparatorTrailingConstraint?.constant = -style.edgePadding
        
        switch style {
            case .titleRoundedContent, .titleEdgeToEdgeContent, .titleNoBackgroundContent:
                titleLabel.text = title
                titleLabel.isHidden = titleIsEmpty
                
            case .titleSeparator:
                titleSeparator.update(title: title)
                titleSeparator.isHidden = false
                
            case .none, .padding: break
            case .loadMore: loadingIndicator.isHidden = false
        }
        
        self.layoutIfNeeded()
    }
}
