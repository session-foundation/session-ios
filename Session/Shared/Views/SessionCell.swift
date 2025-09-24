// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import Combine
import GRDB
import DifferenceKit
import SessionUIKit
import SessionUtilitiesKit

public class SessionCell: UITableViewCell {
    public static let cornerRadius: CGFloat = 17
    
    public private(set) var interactionMode: SessionCell.TextInfo.Interaction = .none
    public var lastTouchLocation: UITouch?
    private var shouldHighlightTitle: Bool = true
    private var originalInputValue: String?
    private var titleExtraView: UIView?
    private var subtitleExtraView: UIView?
    var disposables: Set<AnyCancellable> = Set()
    
    // MARK: - UI
    
    private var backgroundLeftConstraint: NSLayoutConstraint = NSLayoutConstraint()
    private var backgroundRightConstraint: NSLayoutConstraint = NSLayoutConstraint()
    private var topSeparatorLeadingConstraint: NSLayoutConstraint = NSLayoutConstraint()
    private var topSeparatorTrailingConstraint: NSLayoutConstraint = NSLayoutConstraint()
    private var botSeparatorLeadingConstraint: NSLayoutConstraint = NSLayoutConstraint()
    private var botSeparatorTrailingConstraint: NSLayoutConstraint = NSLayoutConstraint()
    private lazy var contentStackViewTopConstraint: NSLayoutConstraint = contentStackView.pin(.top, to: .top, of: cellBackgroundView)
    private lazy var contentStackViewLeadingConstraint: NSLayoutConstraint = contentStackView.pin(.leading, to: .leading, of: cellBackgroundView)
    private lazy var contentStackViewTrailingConstraint: NSLayoutConstraint = contentStackView.pin(.trailing, to: .trailing, of: cellBackgroundView)
    private lazy var contentStackViewBottomConstraint: NSLayoutConstraint = contentStackView.pin(.bottom, to: .bottom, of: cellBackgroundView)
    private lazy var contentStackViewHorizontalCenterConstraint: NSLayoutConstraint = contentStackView.center(.horizontal, in: cellBackgroundView)
    private lazy var contentStackViewWidthConstraint: NSLayoutConstraint = contentStackView.set(.width, lessThanOrEqualTo: .width, of: cellBackgroundView)
    private lazy var leadingAccessoryFillConstraint: NSLayoutConstraint = contentStackView.set(.height, to: .height, of: leadingAccessoryView)
    private lazy var trailingAccessoryFillConstraint: NSLayoutConstraint = contentStackView.set(.height, to: .height, of: trailingAccessoryView)
    private lazy var accessoryWidthMatchConstraint: NSLayoutConstraint = leadingAccessoryView.set(.width, to: .width, of: trailingAccessoryView)
    
    private let cellBackgroundView: UIView = {
        let result: UIView = UIView()
        result.translatesAutoresizingMaskIntoConstraints = false
        result.clipsToBounds = true
        result.themeBackgroundColor = .settings_tabBackground
        
        return result
    }()
    
    private let cellSelectedBackgroundView: UIView = {
        let result: UIView = UIView()
        result.translatesAutoresizingMaskIntoConstraints = false
        result.themeBackgroundColor = .highlighted(.settings_tabBackground)
        result.alpha = 0
        
        return result
    }()
    
    private let topSeparator: UIView = {
        let result: UIView = UIView.separator()
        result.translatesAutoresizingMaskIntoConstraints = false
        result.isHidden = true
        
        return result
    }()
    
    private let contentStackView: UIStackView = {
        let result: UIStackView = UIStackView()
        result.translatesAutoresizingMaskIntoConstraints = false
        result.axis = .horizontal
        result.distribution = .fill
        result.alignment = .center
        result.spacing = Values.mediumSpacing
        
        return result
    }()
    
    public let leadingAccessoryView: AccessoryView = {
        let result: AccessoryView = AccessoryView()
        result.isHidden = true
        
        return result
    }()
    
    private let titleStackView: UIStackView = {
        let result: UIStackView = UIStackView()
        result.translatesAutoresizingMaskIntoConstraints = false
        result.axis = .vertical
        result.distribution = .equalSpacing
        result.alignment = .fill
        result.setContentHugging(to: .defaultLow)
        result.setCompressionResistance(to: .defaultLow)
        
        return result
    }()
    
    fileprivate let titleLabel: SRCopyableLabel = {
        let result: SRCopyableLabel = SRCopyableLabel()
        result.translatesAutoresizingMaskIntoConstraints = false
        result.isUserInteractionEnabled = false
        result.themeTextColor = .textPrimary
        result.numberOfLines = 0
        result.setContentHugging(to: .defaultLow)
        result.setCompressionResistance(to: .defaultLow)
        
        return result
    }()
    
    private let subtitleLabel: SRCopyableLabel = {
        let result: SRCopyableLabel = SRCopyableLabel()
        result.translatesAutoresizingMaskIntoConstraints = false
        result.isUserInteractionEnabled = false
        result.font = .systemFont(ofSize: 12)
        result.themeTextColor = .textPrimary
        result.numberOfLines = 0
        result.isHidden = true
        result.setContentHugging(to: .defaultLow)
        result.setCompressionResistance(to: .defaultLow)
        
        return result
    }()
    
    private let expandableDescriptionLabel: ExpandableLabel = {
        let result:ExpandableLabel = ExpandableLabel()
        result.translatesAutoresizingMaskIntoConstraints = false
        result.font = .systemFont(ofSize: 12)
        result.themeTextColor = .textPrimary
        result.numberOfLines = 0
        result.maxNumberOfLines = 3
        result.isHidden = true
        result.setContentHugging(to: .defaultLow)
        result.setCompressionResistance(to: .defaultLow)
        
        return result
    }()
    
    public let trailingAccessoryView: AccessoryView = {
        let result: AccessoryView = AccessoryView()
        result.isHidden = true
        
        return result
    }()
    
    private let botSeparator: UIView = {
        let result: UIView = UIView.separator()
        result.translatesAutoresizingMaskIntoConstraints = false
        result.isHidden = true
        
        return result
    }()
    
    // MARK: - Initialization
    
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        
        setupViewHierarchy()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        
        setupViewHierarchy()
    }

    private func setupViewHierarchy() {
        self.themeBackgroundColor = .clear
        self.selectedBackgroundView = UIView()
        
        contentView.addSubview(cellBackgroundView)
        cellBackgroundView.addSubview(cellSelectedBackgroundView)
        cellBackgroundView.addSubview(topSeparator)
        cellBackgroundView.addSubview(contentStackView)
        cellBackgroundView.addSubview(botSeparator)
        
        contentStackView.addArrangedSubview(leadingAccessoryView)
        contentStackView.addArrangedSubview(titleStackView)
        contentStackView.addArrangedSubview(expandableDescriptionLabel)
        contentStackView.addArrangedSubview(trailingAccessoryView)
        
        titleStackView.addArrangedSubview(titleLabel)
        titleStackView.addArrangedSubview(subtitleLabel)
        
        setupLayout()
    }
    
    private func setupLayout() {
        cellBackgroundView.pin(.top, to: .top, of: contentView)
        backgroundLeftConstraint = cellBackgroundView.pin(.leading, to: .leading, of: contentView)
        backgroundRightConstraint = cellBackgroundView.pin(.trailing, to: .trailing, of: contentView)
        cellBackgroundView.pin(.bottom, to: .bottom, of: contentView)
        
        cellSelectedBackgroundView.pin(to: cellBackgroundView)
        
        topSeparator.pin(.top, to: .top, of: cellBackgroundView)
        topSeparatorLeadingConstraint = topSeparator.pin(.leading, to: .leading, of: cellBackgroundView)
        topSeparatorTrailingConstraint = topSeparator.pin(.trailing, to: .trailing, of: cellBackgroundView)
        
        contentStackViewTopConstraint.isActive = true
        contentStackViewBottomConstraint.isActive = true
        
        botSeparatorLeadingConstraint = botSeparator.pin(.leading, to: .leading, of: cellBackgroundView)
        botSeparatorTrailingConstraint = botSeparator.pin(.trailing, to: .trailing, of: cellBackgroundView)
        botSeparator.pin(.bottom, to: .bottom, of: cellBackgroundView)
        
        // Limit accessory views horizontal expansion to 40% of the container
        trailingAccessoryView.set(.width, lessThanOrEqualTo: .width, of: contentView, multiplier: 0.40)
        
        // Explicitly call this to ensure we have initialised the constraints before we initially
        // layout (if we don't do this then some constraints get created for the first time when
        // updating the cell before the `isActive` value gets set, resulting in breaking constriants)
        prepareForReuse()
    }
    
    public override func layoutSubviews() {
        super.layoutSubviews()
        
        // Need to force the contentStackView to layout if needed as it might not have updated it's
        // sizing yet
        self.contentStackView.layoutIfNeeded()
        repositionExtraView(titleExtraView, for: titleLabel)
        repositionExtraView(subtitleExtraView, for: subtitleLabel)
        self.titleStackView.layoutIfNeeded()
    }
    
    private func repositionExtraView(_ targetView: UIView?, for label: UILabel) {
        guard
            let targetView: UIView = targetView,
            let content: String = label.text,
            let font: UIFont = label.font
        else { return }
        
        // Position the 'targetView' at the end of the last line of text
        let layoutManager: NSLayoutManager = NSLayoutManager()
        let textStorage = NSTextStorage(
            attributedString: NSAttributedString(
                string: content,
                attributes: [ .font: font ]
            )
        )
        textStorage.addLayoutManager(layoutManager)
        
        let textContainer: NSTextContainer = NSTextContainer(
            size: CGSize(
                width: label.bounds.size.width,
                height: 999
            )
        )
        textContainer.lineFragmentPadding = 0
        layoutManager.addTextContainer(textContainer)
        
        var glyphRange: NSRange = NSRange()
        layoutManager.characterRange(
            forGlyphRange: NSRange(location: content.glyphCount - 1, length: 1),
            actualGlyphRange: &glyphRange
        )
        let lastGlyphRect: CGRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        
        // Remove and re-add the 'subtitleExtraView' to clear any old constraints
        targetView.removeFromSuperview()
        contentView.addSubview(targetView)
        
        targetView.pin(
            .top,
            to: .top,
            of: label,
            withInset: (lastGlyphRect.minY + ((lastGlyphRect.height / 2) - (targetView.bounds.height / 2)))
        )
        targetView.pin(
            .leading,
            to: .leading,
            of: label,
            withInset: lastGlyphRect.maxX
        )
    }
    
    // MARK: - Content
    
    public override func prepareForReuse() {
        super.prepareForReuse()
        
        interactionMode = .none
        shouldHighlightTitle = true
        accessibilityIdentifier = nil
        accessibilityLabel = nil
        isAccessibilityElement = false
        originalInputValue = nil
        titleExtraView?.removeFromSuperview()
        titleExtraView = nil
        subtitleExtraView?.removeFromSuperview()
        subtitleExtraView = nil
        disposables = Set()
        
        contentStackView.spacing = Values.mediumSpacing
        contentStackViewLeadingConstraint.isActive = false
        contentStackViewTrailingConstraint.isActive = false
        contentStackViewHorizontalCenterConstraint.isActive = false
        contentStackViewWidthConstraint.isActive = false
        leadingAccessoryView.prepareForReuse()
        leadingAccessoryView.alpha = 1
        leadingAccessoryFillConstraint.isActive = false
        titleLabel.text = ""
        titleLabel.themeTextColor = .textPrimary
        titleLabel.alpha = 1
        subtitleLabel.isUserInteractionEnabled = false
        subtitleLabel.attributedText = nil
        subtitleLabel.themeTextColor = .textPrimary
        expandableDescriptionLabel.themeAttributedText = nil
        expandableDescriptionLabel.themeTextColor = .textPrimary
        trailingAccessoryView.prepareForReuse()
        trailingAccessoryView.alpha = 1
        trailingAccessoryFillConstraint.isActive = false
        accessoryWidthMatchConstraint.isActive = false
        
        topSeparator.isHidden = true
        subtitleLabel.isHidden = true
        expandableDescriptionLabel.isHidden = true
        botSeparator.isHidden = true
    }
    
    @MainActor public func update<ID: Hashable & Differentiable>(
        with info: Info<ID>,
        tableSize: CGSize,
        onToggleExpansion: (@MainActor () -> Void)? = nil,
        using dependencies: Dependencies
    ) {
        /// Need to do this here as `prepareForReuse` doesn't always seem to get called
        titleExtraView?.removeFromSuperview()
        subtitleExtraView?.removeFromSuperview()
        
        /// Do other configuration
        interactionMode = (info.title?.interaction ?? .none)
        shouldHighlightTitle = (info.title?.interaction != .copy)
        titleExtraView = info.title?.extraViewGenerator?()
        subtitleExtraView = info.subtitle?.extraViewGenerator?()
        accessibilityIdentifier = info.accessibility?.identifier
        accessibilityLabel = info.accessibility?.label
        isAccessibilityElement = (info.accessibility != nil)
        originalInputValue = info.title?.text
        
        // Convenience Flags
        let leadingFitToEdge: Bool = (info.leadingAccessory?.shouldFitToEdge == true)
        let trailingFitToEdge: Bool = (!leadingFitToEdge && info.trailingAccessory?.shouldFitToEdge == true)
        
        // Layout (do this before setting up the content so we can calculate the expected widths if needed)
        contentStackViewLeadingConstraint.isActive = (info.styling.alignment == .leading)
        contentStackViewTrailingConstraint.isActive = (info.styling.alignment == .leading)
        contentStackViewHorizontalCenterConstraint.constant = ((info.styling.customPadding?.leading ?? 0) + (info.styling.customPadding?.trailing ?? 0))
        contentStackViewHorizontalCenterConstraint.isActive = (info.styling.alignment == .centerHugging)
        contentStackViewWidthConstraint.constant = -(abs((info.styling.customPadding?.leading ?? 0) + (info.styling.customPadding?.trailing ?? 0)) * 2) // Double the center offset to keep within bounds
        contentStackViewWidthConstraint.isActive = (info.styling.alignment == .centerHugging)
        leadingAccessoryFillConstraint.isActive = leadingFitToEdge
        trailingAccessoryFillConstraint.isActive = trailingFitToEdge
        accessoryWidthMatchConstraint.isActive = {
            switch (info.leadingAccessory, info.trailingAccessory) {
                case is (SessionCell.AccessoryConfig.Button, SessionCell.AccessoryConfig.Button): return true
                default: return false
            }
        }()
        titleLabel.setContentHuggingPriority(
            (info.trailingAccessory != nil ? .defaultLow : .required),
            for: .horizontal
        )
        titleLabel.setContentCompressionResistancePriority(
            (info.trailingAccessory != nil ? .defaultLow : .required),
            for: .horizontal
        )
        contentStackViewTopConstraint.constant = {
            if let customPadding: CGFloat = info.styling.customPadding?.top {
                return customPadding
            }
            
            return (leadingFitToEdge || trailingFitToEdge ? 0 : Values.mediumSpacing)
        }()
        contentStackViewLeadingConstraint.constant = {
            if let customPadding: CGFloat = info.styling.customPadding?.leading {
                return customPadding
            }
            
            return (leadingFitToEdge ? 0 : Values.mediumSpacing)
        }()
        contentStackViewTrailingConstraint.constant = {
            if let customPadding: CGFloat = info.styling.customPadding?.trailing {
                return -customPadding
            }
            
            return -(trailingFitToEdge ? 0 : Values.mediumSpacing)
        }()
        contentStackViewBottomConstraint.constant = {
            if let customPadding: CGFloat = info.styling.customPadding?.bottom {
                return -customPadding
            }
            
            return -(leadingFitToEdge || trailingFitToEdge ? 0 : Values.mediumSpacing)
        }()
        
        // Styling and positioning
        let defaultEdgePadding: CGFloat
        
        switch info.styling.backgroundStyle {
            case .rounded:
                cellBackgroundView.themeBackgroundColor = .settings_tabBackground
                cellSelectedBackgroundView.isHidden = !info.isEnabled
                
                defaultEdgePadding = Values.mediumSpacing
                backgroundLeftConstraint.constant = Values.largeSpacing
                backgroundRightConstraint.constant = -Values.largeSpacing
                cellBackgroundView.layer.cornerRadius = SessionCell.cornerRadius
                
            case .edgeToEdge:
                cellBackgroundView.themeBackgroundColor = .settings_tabBackground
                cellSelectedBackgroundView.isHidden = !info.isEnabled
                
                defaultEdgePadding = 0
                backgroundLeftConstraint.constant = 0
                backgroundRightConstraint.constant = 0
                cellBackgroundView.layer.cornerRadius = 0
                
            case .noBackground:
                defaultEdgePadding = Values.mediumSpacing
                backgroundLeftConstraint.constant = Values.largeSpacing
                backgroundRightConstraint.constant = -Values.largeSpacing
                cellBackgroundView.themeBackgroundColor = nil
                cellBackgroundView.layer.cornerRadius = 0
                cellSelectedBackgroundView.isHidden = true
                
            case .noBackgroundEdgeToEdge:
                defaultEdgePadding = 0
                backgroundLeftConstraint.constant = 0
                backgroundRightConstraint.constant = 0
                cellBackgroundView.themeBackgroundColor = nil
                cellBackgroundView.layer.cornerRadius = 0
                cellSelectedBackgroundView.isHidden = true
        }
        
        let fittedEdgePadding: CGFloat = {
            func targetSize(accessory: Accessory?) -> CGFloat {
                switch accessory {
                    case let accessory as SessionCell.AccessoryConfig.Icon: return accessory.iconSize.size
                    case let accessory as SessionCell.AccessoryConfig.IconAsync: return accessory.iconSize.size
                    default: return defaultEdgePadding
                }
            }
            
            guard leadingFitToEdge else {
                guard trailingFitToEdge else { return defaultEdgePadding }
                
                return targetSize(accessory: info.trailingAccessory)
            }
            
            return targetSize(accessory: info.leadingAccessory)
        }()
        topSeparatorLeadingConstraint.constant = (leadingFitToEdge ? fittedEdgePadding : defaultEdgePadding)
        topSeparatorTrailingConstraint.constant = (trailingFitToEdge ? -fittedEdgePadding : -defaultEdgePadding)
        botSeparatorLeadingConstraint.constant = (leadingFitToEdge ? fittedEdgePadding : defaultEdgePadding)
        botSeparatorTrailingConstraint.constant = (trailingFitToEdge ? -fittedEdgePadding : -defaultEdgePadding)
        
        switch info.position {
            case .top:
                cellBackgroundView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
                topSeparator.isHidden = (
                    !info.styling.allowedSeparators.contains(.top) || (
                        info.styling.backgroundStyle != .edgeToEdge &&
                        info.styling.backgroundStyle != .noBackgroundEdgeToEdge
                    )
                )
                botSeparator.isHidden = (
                    !info.styling.allowedSeparators.contains(.bottom) || (
                        info.styling.backgroundStyle == .noBackground &&
                        info.styling.backgroundStyle != .noBackgroundEdgeToEdge
                    )
                )
                
            case .middle:
                cellBackgroundView.layer.maskedCorners = []
                topSeparator.isHidden = true
                botSeparator.isHidden = (
                    !info.styling.allowedSeparators.contains(.bottom) || (
                        info.styling.backgroundStyle == .noBackground &&
                        info.styling.backgroundStyle != .noBackgroundEdgeToEdge
                    )
                )
                
            case .bottom:
                cellBackgroundView.layer.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
                topSeparator.isHidden = true
                botSeparator.isHidden = (
                    !info.styling.allowedSeparators.contains(.bottom) || (
                        info.styling.backgroundStyle != .edgeToEdge &&
                        info.styling.backgroundStyle != .noBackgroundEdgeToEdge
                    )
                )
                
            case .individual:
                cellBackgroundView.layer.maskedCorners = [
                    .layerMinXMinYCorner, .layerMaxXMinYCorner,
                    .layerMinXMaxYCorner, .layerMaxXMaxYCorner
                ]
                topSeparator.isHidden = (
                    !info.styling.allowedSeparators.contains(.top) || (
                        info.styling.backgroundStyle != .edgeToEdge &&
                        info.styling.backgroundStyle != .noBackgroundEdgeToEdge
                    )
                )
                botSeparator.isHidden = (
                    !info.styling.allowedSeparators.contains(.bottom) || (
                        info.styling.backgroundStyle != .edgeToEdge &&
                        info.styling.backgroundStyle != .noBackgroundEdgeToEdge
                    )
                )
        }
        
        // Content
        let contentStackViewHorizontalInset: CGFloat = (
            (backgroundLeftConstraint.constant + (-backgroundRightConstraint.constant)) +
            (contentStackViewLeadingConstraint.constant + (-contentStackViewTrailingConstraint.constant))
        )
        contentStackView.spacing = (info.styling.customPadding?.interItem ?? Values.mediumSpacing)
        leadingAccessoryView.update(
            with: info.leadingAccessory,
            tintColor: info.styling.tintColor,
            isEnabled: info.isEnabled,
            maxContentWidth: (tableSize.width - contentStackViewHorizontalInset),
            using: dependencies
        )
        titleStackView.isHidden = (info.title == nil && info.subtitle == nil)
        titleLabel.isUserInteractionEnabled = (info.title?.interaction == .copy)
        titleLabel.font = info.title?.font
        titleLabel.text = info.title?.text
        titleLabel.themeTextColor = info.styling.tintColor
        titleLabel.textAlignment = (info.title?.textAlignment ?? .left)
        titleLabel.accessibilityIdentifier = info.title?.accessibility?.identifier
        titleLabel.accessibilityLabel = info.title?.accessibility?.label
        titleLabel.isHidden = (info.title == nil)
        subtitleLabel.isUserInteractionEnabled = (info.subtitle?.interaction == .copy)
        subtitleLabel.font = info.subtitle?.font
        subtitleLabel.themeTextColor = info.styling.subtitleTintColor
        subtitleLabel.themeAttributedText = info.subtitle.map { subtitle -> ThemedAttributedString? in
            ThemedAttributedString(stringWithHTMLTags: subtitle.text, font: subtitle.font)
        }
        subtitleLabel.textAlignment = (info.subtitle?.textAlignment ?? .left)
        subtitleLabel.accessibilityIdentifier = info.subtitle?.accessibility?.identifier
        subtitleLabel.accessibilityLabel = info.subtitle?.accessibility?.label
        subtitleLabel.isHidden = (info.subtitle == nil)
        expandableDescriptionLabel.font = info.description?.font ?? .systemFont(ofSize: 12)
        expandableDescriptionLabel.themeTextColor = info.styling.descriptionTintColor
        expandableDescriptionLabel.themeAttributedText = info.description.map { description -> ThemedAttributedString? in
            ThemedAttributedString(stringWithHTMLTags: description.text, font: description.font)
        }
        expandableDescriptionLabel.textAlignment = (info.description?.textAlignment ?? .left)
        expandableDescriptionLabel.accessibilityIdentifier = info.description?.accessibility?.identifier
        expandableDescriptionLabel.accessibilityLabel = info.description?.accessibility?.label
        expandableDescriptionLabel.isHidden = (info.description == nil)
        expandableDescriptionLabel.onToggleExpansion = (info.description?.interaction == .expandable ?
            onToggleExpansion : nil)
        trailingAccessoryView.update(
            with: info.trailingAccessory,
            tintColor: info.styling.tintColor,
            isEnabled: info.isEnabled,
            maxContentWidth: (tableSize.width - contentStackViewHorizontalInset),
            using: dependencies
        )
    }
    
    // MARK: - Interaction
    
    public override func setHighlighted(_ highlighted: Bool, animated: Bool) {
        super.setHighlighted(highlighted, animated: animated)
        
        // If the 'cellSelectedBackgroundView' is hidden then there is no background so we
        // should update the titleLabel to indicate the highlighted state
        if cellSelectedBackgroundView.isHidden && shouldHighlightTitle {
            // Note: We delay the "unhighlight" of the titleLabel so that the transition doesn't
            // conflict with the transition into edit mode
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(10)) { [weak self] in
                self?.titleLabel.alpha = (highlighted ? 0.8 : 1)
            }
        }

        cellSelectedBackgroundView.alpha = (highlighted ? 1 : 0)
        leadingAccessoryView.setHighlighted(highlighted, animated: animated)
        trailingAccessoryView.setHighlighted(highlighted, animated: animated)
    }
    
    public override func setSelected(_ selected: Bool, animated: Bool) {
        super.setSelected(selected, animated: animated)

        leadingAccessoryView.setSelected(selected, animated: animated)
        trailingAccessoryView.setSelected(selected, animated: animated)
    }
    
    public override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        
        lastTouchLocation = touches.first
    }
}
