// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import UniformTypeIdentifiers
import Lucide

public final class QuoteView: UIView {
    static let thumbnailSize: CGFloat = 48
    static let iconSize: CGFloat = 24
    static let labelStackViewSpacing: CGFloat = 2
    static let labelStackViewVMargin: CGFloat = 4
    static let cancelButtonSize: CGFloat = 33
    
    enum Mode {
        case regular
        case draft
    }
    enum Direction { case incoming, outgoing }
    
    // MARK: - Variables
    
    private let viewModel: QuoteViewModel
    private let dataManager: ImageDataManagerType
    private var onCancel: (() -> Void)?

    // MARK: - Lifecycle
    
    public init(
        viewModel: QuoteViewModel,
        dataManager: ImageDataManagerType,
        onCancel: (() -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.dataManager = dataManager
        self.onCancel = onCancel
        
        super.init(frame: CGRect.zero)
        
        setUpViewHierarchy(viewModel: viewModel)
    }

    override init(frame: CGRect) {
        preconditionFailure("Use init(for:maxMessageWidth:) instead.")
    }

    required init?(coder: NSCoder) {
        preconditionFailure("Use init(for:maxMessageWidth:) instead.")
    }

    private func setUpViewHierarchy(viewModel: QuoteViewModel) {
        // There's quite a bit of calculation going on here. It's a bit complex so don't make changes
        // if you don't need to. If you do then test:
        // • Quoted text in both private chats and group chats
        // • Quoted images and videos in both private chats and group chats
        // • Quoted voice messages and documents in both private chats and group chats
        // • All of the above in both dark mode and light mode
        let thumbnailSize = QuoteView.thumbnailSize
        let iconSize = QuoteView.iconSize
        let labelStackViewSpacing = QuoteView.labelStackViewSpacing
        let labelStackViewVMargin = QuoteView.labelStackViewVMargin
        let smallSpacing = Values.smallSpacing
        let cancelButtonSize = QuoteView.cancelButtonSize
        
        // Main stack view
        let mainStackView = UIStackView(arrangedSubviews: [])
        mainStackView.axis = .horizontal
        mainStackView.spacing = smallSpacing
        mainStackView.alignment = .center
        mainStackView.setCompressionResistance(.vertical, to: .required)
        
        // Content view
        let contentView = UIView()
        addSubview(contentView)
        contentView.pin(to: self)
        
        if viewModel.hasAttachment {
            let imageContainerView: UIView = UIView()
            imageContainerView.themeBackgroundColor = .messageBubble_overlay
            imageContainerView.layer.cornerRadius = 4
            imageContainerView.layer.masksToBounds = true
            imageContainerView.set(.width, to: thumbnailSize)
            imageContainerView.set(.height, to: thumbnailSize)
            mainStackView.addArrangedSubview(imageContainerView)
            
            let imageView: SessionImageView = SessionImageView(
                image: viewModel.fallbackImage,
                dataManager: dataManager
            )
            imageView.themeTintColor = viewModel.targetThemeColor
            imageView.contentMode = .scaleAspectFit
            imageView.set(.width, to: iconSize)
            imageView.set(.height, to: iconSize)
            imageContainerView.addSubview(imageView)
            imageView.center(in: imageContainerView)
            
            // Generate the thumbnail if needed
            if let source: ImageDataManager.DataSource = viewModel.quotedAttachmentInfo?.thumbnailSource {
                imageView.loadImage(source) { [weak imageView] buffer in
                    guard buffer != nil else { return }
                    
                    imageView?.contentMode = .scaleAspectFill
                }
            }
        }
        else {
            // Line view
            let lineView = UIView()
            lineView.themeBackgroundColor = viewModel.lineColor
            mainStackView.addArrangedSubview(lineView)
            
            lineView.pin(.top, to: .top, of: mainStackView)
            lineView.pin(.bottom, to: .bottom, of: mainStackView)
            lineView.set(.width, to: Values.accentLineThickness)
        }
        
        // Body label
        let bodyLabel = TappableLabel()
        bodyLabel.lineBreakMode = .byTruncatingTail
        bodyLabel.numberOfLines = 2
        bodyLabel.themeAttributedText = viewModel.attributedText
        
        /// Label stack view
        let authorLabel = SessionLabelWithProBadge(
            proBadgeSize: .mini,
            proBadgeThemeBackgroundColor: viewModel.proBadgeThemeColor
        )
        authorLabel.font = .boldSystemFont(ofSize: Values.smallFontSize)
        authorLabel.text = viewModel.author
        authorLabel.themeTextColor = viewModel.targetThemeColor
        authorLabel.lineBreakMode = .byTruncatingTail
        authorLabel.numberOfLines = 1
        authorLabel.isHidden = (viewModel.author == nil)
        authorLabel.isProBadgeHidden = !viewModel.showProBadge
        authorLabel.setCompressionResistance(.vertical, to: .required)
        
        let labelStackView = UIStackView(arrangedSubviews: [ authorLabel, bodyLabel ])
        labelStackView.axis = .vertical
        labelStackView.spacing = labelStackViewSpacing
        labelStackView.distribution = .equalCentering
        labelStackView.isLayoutMarginsRelativeArrangement = true
        labelStackView.layoutMargins = UIEdgeInsets(top: labelStackViewVMargin, left: 0, bottom: labelStackViewVMargin, right: 0)
        labelStackView.setCompressionResistance(.vertical, to: .required)
        mainStackView.addArrangedSubview(labelStackView)
        
        // Constraints
        contentView.addSubview(mainStackView)
        mainStackView.pin(to: contentView)
        
        if viewModel.mode == .draft {
            // Cancel button
            let cancelButton = UIButton(type: .custom)
            cancelButton.setImage(Lucide.image(icon: .x, size: 24)?.withRenderingMode(.alwaysTemplate), for: .normal)
            cancelButton.themeTintColor = .textPrimary
            cancelButton.set(.width, to: cancelButtonSize)
            cancelButton.set(.height, to: cancelButtonSize)
            cancelButton.addTarget(self, action: #selector(cancel), for: UIControl.Event.touchUpInside)
            
            mainStackView.addArrangedSubview(cancelButton)
            cancelButton.center(.vertical, in: self)
            mainStackView.isLayoutMarginsRelativeArrangement = true
            mainStackView.layoutMargins = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 1)
        }
    }

    // MARK: - Interaction
    
    @objc private func cancel() {
        onCancel?()
    }
    
    // MARK: - Functions
    
    public func update(viewModel: QuoteViewModel) {
        subviews.forEach { $0.removeFromSuperview() }
        
        setUpViewHierarchy(viewModel: viewModel)
    }
}
