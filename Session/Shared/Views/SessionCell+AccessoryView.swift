// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import Lucide
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit
import SignalUtilitiesKit

extension SessionCell {
    public class AccessoryView: UIView, UISearchBarDelegate {
        // Note: We set a minimum width for the 'AccessoryView' so that the titles line up
        // nicely when we have a mix of icons and switches
        private static let minWidth: CGFloat = 50
        
        private var onTap: ((SessionButton?) -> Void)?
        private var searchTermChanged: ((String?) -> Void)?
        
        private var currentContentView: UIView?
        private var currentAccessoryIdentifier: String?
        
        private lazy var minWidthConstraint: NSLayoutConstraint = self.widthAnchor
            .constraint(greaterThanOrEqualToConstant: AccessoryView.minWidth)
        private lazy var fixedWidthConstraint: NSLayoutConstraint = self.set(.width, to: AccessoryView.minWidth)
        
        // MARK: - Content
        
        func prepareForReuse() {
            isHidden = true
            onTap = nil
            searchTermChanged = nil
            currentContentView?.removeFromSuperview()
            currentContentView = nil
            currentAccessoryIdentifier = nil
            
            minWidthConstraint.constant = AccessoryView.minWidth
            minWidthConstraint.isActive = false
            fixedWidthConstraint.constant = AccessoryView.minWidth
            fixedWidthConstraint.isActive = false
        }
        
        public func update(
            with accessory: Accessory?,
            tintColor: ThemeValue,
            isEnabled: Bool,
            maxContentWidth: CGFloat,
            using dependencies: Dependencies
        ) {
            guard let accessory: Accessory = accessory else { return }
            
            /// If the identifier hasn't changed then no need to reconstruct the content
            guard accessory.viewIdentifier != currentAccessoryIdentifier else {
                configure(
                    view: currentContentView,
                    accessory: accessory,
                    tintColor: tintColor,
                    isEnabled: isEnabled,
                    using: dependencies
                )
                return
            }
            
            /// Otherwise we do need to reconstruct and layout the content
            prepareForReuse()
            self.isHidden = false
            
            let maybeView: UIView? = createView(
                accessory: accessory,
                maxContentWidth: maxContentWidth,
                using: dependencies
            )
            
            if let newView: UIView = maybeView {
                addSubview(newView)
                layout(view: newView, accessory: accessory)
            }
            
            configure(
                view: maybeView,
                accessory: accessory,
                tintColor: tintColor,
                isEnabled: isEnabled,
                using: dependencies
            )
            
            currentContentView = maybeView
            currentAccessoryIdentifier = accessory.viewIdentifier
        }
        
        // MARK: - Interaction
        
        func touchedView(_ touch: UITouch) -> UIView {
            switch (currentContentView, currentContentView?.subviews.first, currentContentView?.subviews.last) {
                case (let label as SessionHighlightingBackgroundLabel, _, _),
                    (_, let label as SessionHighlightingBackgroundLabel, _):
                    let localPoint: CGPoint = touch.location(in: label)
                    
                    return (label.bounds.contains(localPoint) ? label : self)
                case (let profilePictureView as ProfilePictureView, _, _):
                    let localPoint: CGPoint = touch.location(in: profilePictureView)
                    
                    return profilePictureView.getTouchedView(from: localPoint)
                
                case (_, let qrCodeImageView as UIImageView , .some(let profileIcon)):
                    let localPoint: CGPoint = touch.location(in: profileIcon)
                    
                    return (profileIcon.bounds.contains(localPoint) ? profileIcon : qrCodeImageView)
                    
                default: return self
            }
        }
        
        func setHighlighted(_ highlighted: Bool, animated: Bool) {
            switch (currentContentView, currentContentView?.subviews.first) {
                case (let label as SessionHighlightingBackgroundLabel, _),
                    (_, let label as SessionHighlightingBackgroundLabel):
                    label.setHighlighted(highlighted, animated: animated)
                    
                default: break
            }
        }
        
        func setSelected(_ selected: Bool, animated: Bool) {
            switch (currentContentView, currentContentView?.subviews.first) {
                case (let label as SessionHighlightingBackgroundLabel, _),
                    (_, let label as SessionHighlightingBackgroundLabel):
                    label.setSelected(selected, animated: animated)
                    
                default: break
            }
        }
        
        @objc private func buttonTapped() {
            guard let button: SessionButton = currentContentView as? SessionButton else { return }
            
            onTap?(button)
        }
        
        // MARK: - UISearchBarDelegate
        
        public func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
            searchTermChanged?(searchText)
        }
        
        public func searchBarTextDidBeginEditing(_ searchBar: UISearchBar) {
            searchBar.setShowsCancelButton(true, animated: true)
        }
        
        public func searchBarTextDidEndEditing(_ searchBar: UISearchBar) {
            searchBar.setShowsCancelButton(false, animated: true)
        }
        
        public func searchBarCancelButtonClicked(_ searchBar: UISearchBar) {
            searchBar.endEditing(true)
        }
        
        // MARK: - View Construction
        
        private func createView(
            accessory: Accessory,
            maxContentWidth: CGFloat,
            using dependencies: Dependencies
        ) -> UIView? {
            switch accessory {
                case is SessionCell.AccessoryConfig.QRCode:
                    return createQRCodeView()
                
                case is SessionCell.AccessoryConfig.ProBadge:
                    return SessionProBadge(size: .small)
                
                case is SessionCell.AccessoryConfig.Icon:
                    return createIconView(using: dependencies)
                    
                case is SessionCell.AccessoryConfig.IconAsync:
                    return createIconView(using: dependencies)
                    
                case is SessionCell.AccessoryConfig.Toggle: return createToggleView()
                case is SessionCell.AccessoryConfig.DropDown:
                    return createDropDownView(maxContentWidth: maxContentWidth)
                    
                case is SessionCell.AccessoryConfig.Radio: return createRadioView()
                    
                case is SessionCell.AccessoryConfig.HighlightingBackgroundLabel:
                    return createHighlightingBackgroundLabelView(maxContentWidth: maxContentWidth)
                    
                case is SessionCell.AccessoryConfig.HighlightingBackgroundLabelAndRadio:
                    return createHighlightingBackgroundLabelAndRadioView(maxContentWidth: maxContentWidth)
                    
                case is SessionCell.AccessoryConfig.DisplayPicture: return createDisplayPictureView()
                case is SessionCell.AccessoryConfig.Search: return createSearchView()
                    
                case is SessionCell.AccessoryConfig.Button: return createButtonView()
                case let accessory as SessionCell.AccessoryConfig.AnyCustom:
                    return accessory.createView(
                        maxContentWidth: maxContentWidth,
                        using: dependencies
                    )
                    
                default:
                    /// If we get an unknown case then just hide again
                    self.isHidden = true
                    return nil
            }
        }
 
        private func layout(view: UIView?, accessory: Accessory) {
            switch accessory {
                case let accessory as SessionCell.AccessoryConfig.QRCode:
                    layoutQRCodeView(view)
                
                case let accessory as SessionCell.AccessoryConfig.ProBadge:
                    layoutProBadgeView(view, size: accessory.proBadgeSize)
        
                case let accessory as SessionCell.AccessoryConfig.Icon:
                    layoutIconView(
                        view,
                        iconSize: accessory.iconSize,
                        shouldFill: accessory.shouldFill,
                        pin: accessory.pinEdges
                    )
                    
                case let accessory as SessionCell.AccessoryConfig.IconAsync:
                    layoutIconView(
                        view,
                        iconSize: accessory.iconSize,
                        shouldFill: accessory.shouldFill,
                        pin: accessory.pinEdges
                    )
                    
                case is SessionCell.AccessoryConfig.Toggle: layoutToggleView(view)
                case is SessionCell.AccessoryConfig.DropDown: layoutDropDownView(view)
                case let accessory as SessionCell.AccessoryConfig.Radio:
                    layoutRadioView(view, size: accessory.size)
                    
                case is SessionCell.AccessoryConfig.HighlightingBackgroundLabel:
                    layoutHighlightingBackgroundLabelView(view)
                    
                case let accessory as SessionCell.AccessoryConfig.HighlightingBackgroundLabelAndRadio:
                    layoutHighlightingBackgroundLabelAndRadioView(view, size: accessory.size)
                    
                case let accessory as SessionCell.AccessoryConfig.DisplayPicture:
                    layoutDisplayPictureView(view, size: accessory.size)
                    
                case is SessionCell.AccessoryConfig.Search: layoutSearchView(view)
                    
                case is SessionCell.AccessoryConfig.Button: layoutButtonView(view)
                case let accessory as SessionCell.AccessoryConfig.AnyCustom:
                    layoutCustomView(view, size: accessory.size)
                    
                // If we get an unknown case then just hide again
                default: self.isHidden = true
            }
        }
        
        private func configure(
            view: UIView?,
            accessory: Accessory,
            tintColor: ThemeValue,
            isEnabled: Bool,
            using dependencies: Dependencies
        ) {
            switch accessory {
                case let accessory as SessionCell.AccessoryConfig.QRCode:
                    configureQRCodeView(view, accessory)
                
                case let accessory as SessionCell.AccessoryConfig.ProBadge:
                    configureProBadgeView(view, tintColor: tintColor)
                
                case let accessory as SessionCell.AccessoryConfig.Icon:
                    configureIconView(view, accessory, tintColor: tintColor)
                    
                case let accessory as SessionCell.AccessoryConfig.IconAsync:
                    configureIconView(view, accessory, tintColor: tintColor)
                    
                case let accessory as SessionCell.AccessoryConfig.Toggle:
                    configureToggleView(view, accessory, isEnabled: isEnabled)
                    
                case let accessory as SessionCell.AccessoryConfig.DropDown:
                    configureDropDown(view, accessory)
                    
                case let accessory as SessionCell.AccessoryConfig.Radio:
                    configureRadioView(view, accessory, isEnabled: isEnabled)
                    
                case let accessory as SessionCell.AccessoryConfig.HighlightingBackgroundLabel:
                    configureHighlightingBackgroundLabelView(view, accessory, tintColor: tintColor)
                    
                case let accessory as SessionCell.AccessoryConfig.HighlightingBackgroundLabelAndRadio:
                    configureHighlightingBackgroundLabelAndRadioView(
                        view,
                        accessory,
                        tintColor: tintColor,
                        isEnabled: isEnabled
                    )
                    
                case let accessory as SessionCell.AccessoryConfig.DisplayPicture:
                    configureDisplayPictureView(view, accessory, using: dependencies)
                    
                case let accessory as SessionCell.AccessoryConfig.Search:
                    configureSearchView(view, accessory)
                    
                case let accessory as SessionCell.AccessoryConfig.Button:
                    configureButtonView(view, accessory)
                    
                case let accessory as SessionCell.AccessoryConfig.AnyCustom:
                    configureCustomView(view, accessory)
                    
                // If we get an unknown case then just hide again
                default: self.isHidden = true
            }
        }
        
        // MARK: -- QRCode
        
        private func createQRCodeView() -> UIView {
            let result: UIView = UIView()
            result.layer.cornerRadius = 10
            
            let qrCodeImageView: UIImageView = UIImageView()
            qrCodeImageView.contentMode = .scaleAspectFit
            
            result.addSubview(qrCodeImageView)
            qrCodeImageView.pin(to: result, withInset: Values.smallSpacing)
            result.set(.width, to: 190)
            result.set(.height, to: 190)
            
            let iconImageView: UIImageView = UIImageView(
                image: UIImage(named: "ic_user_round_fill")?
                    .withRenderingMode(.alwaysTemplate)
            )
            iconImageView.contentMode = .scaleAspectFit
            iconImageView.set(.width, to: 18)
            iconImageView.set(.height, to: 18)
            iconImageView.themeTintColor = .black
            
            let iconBackgroudView: UIView = UIView()
            iconBackgroudView.themeBackgroundColor = .primary
            iconBackgroudView.set(.width, to: 33)
            iconBackgroudView.set(.height, to: 33)
            iconBackgroudView.layer.cornerRadius = 16.5
            iconBackgroudView.layer.masksToBounds = true
            
            iconBackgroudView.addSubview(iconImageView)
            iconImageView.center(in: iconBackgroudView)
            
            result.addSubview(iconBackgroudView)
            iconBackgroudView.pin(.top, to: .top, of: result, withInset: -10)
            iconBackgroudView.pin(.trailing, to: .trailing, of: result, withInset: 17)
            
            return result
        }
        
        private func layoutQRCodeView(_ view: UIView?) {
            guard let view: UIView = view else { return }
            
            view.pin(to: self)
            fixedWidthConstraint.constant = 190
            fixedWidthConstraint.isActive = true
        }
        
        private func configureQRCodeView(_ view: UIView?, _ accessory: SessionCell.AccessoryConfig.QRCode) {
            guard
                let backgroundView: UIView = view,
                let qrCodeImageView: UIImageView = view?.subviews.first as? UIImageView
            else { return }
            
            let backgroundThemeColor: ThemeValue = (accessory.themeStyle == .light ? .backgroundSecondary : .textPrimary)
            let qrCodeThemeColor: ThemeValue = (accessory.themeStyle == .light ? .textPrimary : .backgroundPrimary)
            let qrCodeImage: UIImage = QRCode
                .generate(for: accessory.string, hasBackground: accessory.hasBackground, iconName: accessory.logo)
                .withRenderingMode(.alwaysTemplate)
            
            qrCodeImageView.image = qrCodeImage
            qrCodeImageView.themeTintColor = qrCodeThemeColor
            backgroundView.themeBackgroundColor = backgroundThemeColor
        }
        
        // MARK: -- Pro Badge
        
        private func layoutProBadgeView(_ view: UIView?, size: SessionProBadge.Size) {
            guard let badgeView: SessionProBadge = view as? SessionProBadge else { return }
            badgeView.size = size
            badgeView.pin(.leading, to: .leading, of: self, withInset: Values.smallSpacing)
            badgeView.pin(.trailing, to: .trailing, of: self, withInset: -Values.smallSpacing)
            badgeView.pin(.top, to: .top, of: self)
            badgeView.pin(.bottom, to: .bottom, of: self)
        }
        
        private func configureProBadgeView(_ view: UIView?, tintColor: ThemeValue) {
            guard let badgeView: SessionProBadge = view as? SessionProBadge else { return }
            badgeView.themeBackgroundColor = tintColor
        }
        
        // MARK: -- Icon
        
        private func createIconView(using dependencies: Dependencies) -> SessionImageView {
            let result: SessionImageView = SessionImageView(
                dataManager: dependencies[singleton: .imageDataManager]
            )
            result.translatesAutoresizingMaskIntoConstraints = false
            result.clipsToBounds = true
            result.layer.minificationFilter = .trilinear
            result.layer.magnificationFilter = .trilinear
            
            return result
        }
        
        private func layoutIconView(_ view: UIView?, iconSize: IconSize, shouldFill: Bool, pin edges: [UIView.HorizontalEdge]) {
            guard let imageView: SessionImageView = view as? SessionImageView else { return }
            
            imageView.set(.width, to: iconSize.size)
            imageView.set(.height, to: iconSize.size)
            imageView.pin(.top, to: .top, of: self)
            imageView.pin(.bottom, to: .bottom, of: self)

            let shouldInvertPadding: [UIView.HorizontalEdge] = [.left, .trailing]
   
            for edge in edges {
                let inset: CGFloat = (
                    (shouldFill ? 0 : Values.smallSpacing) *
                    (shouldInvertPadding.contains(edge) ? -1 : 1)
                )
                
                imageView.pin(edge, to: edge, of: self, withInset: inset)
            }
            
            fixedWidthConstraint.isActive = (iconSize.size <= fixedWidthConstraint.constant)
            minWidthConstraint.isActive = !fixedWidthConstraint.isActive
        }
        
        private func configureIconView(_ view: UIView?, _ accessory: SessionCell.AccessoryConfig.Icon, tintColor: ThemeValue) {
            guard let imageView: SessionImageView = view as? SessionImageView else { return }
            
            imageView.accessibilityIdentifier = accessory.accessibility?.identifier
            imageView.accessibilityLabel = accessory.accessibility?.label
            imageView.themeTintColor = (accessory.customTint ?? tintColor)
            imageView.contentMode = (accessory.shouldFill ? .scaleAspectFill : .scaleAspectFit)

            switch (accessory.icon, accessory.image) {
                case (.some(let icon), _):
                    imageView.image = Lucide
                        .image(icon: icon, size: accessory.iconSize.size)?
                        .withRenderingMode(.alwaysTemplate)
                    
                case (.none, .some(let image)): imageView.image = image
                case (.none, .none): imageView.image = nil
            }
        }
        
        // MARK: -- IconAsync
        
        private func configureIconView(_ view: UIView?, _ accessory: SessionCell.AccessoryConfig.IconAsync, tintColor: ThemeValue) {
            guard let imageView: SessionImageView = view as? SessionImageView else { return }
            
            imageView.accessibilityIdentifier = accessory.accessibility?.identifier
            imageView.accessibilityLabel = accessory.accessibility?.label
            imageView.themeTintColor = (accessory.customTint ?? tintColor)
            imageView.contentMode = (accessory.shouldFill ? .scaleAspectFill : .scaleAspectFit)
            
            switch accessory.source {
                case .none: imageView.image = nil
                case .some(let source): imageView.loadImage(source)
            }
        }
    
        // MARK: -- Toggle
        
        private func createToggleView() -> UISwitch {
            let result: UISwitch = UISwitch()
            result.translatesAutoresizingMaskIntoConstraints = false
            result.isUserInteractionEnabled = false // Triggered by didSelectCell instead
            result.themeOnTintColor = .primary
            result.setContentHugging(to: .required)
            result.setCompressionResistance(to: .required)
            
            return result
        }
        
        private func layoutToggleView(_ view: UIView?) {
            guard let toggleSwitch: UISwitch = view as? UISwitch else { return }
            
            toggleSwitch.pin(to: self)
            fixedWidthConstraint.isActive = true
        }
        
        private func configureToggleView(
            _ view: UIView?,
            _ accessory: SessionCell.AccessoryConfig.Toggle,
            isEnabled: Bool
        ) {
            guard let toggleSwitch: UISwitch = view as? UISwitch else { return }
            
            toggleSwitch.accessibilityIdentifier = accessory.accessibility?.identifier
            toggleSwitch.accessibilityLabel = accessory.accessibility?.label
            toggleSwitch.isEnabled = isEnabled
            toggleSwitch.setOn(accessory.oldValue, animated: false)
            
            // Dispatch so the cell reload doesn't conflict with the setting change animation
            if accessory.oldValue != accessory.value {
                Task { @MainActor [weak toggleSwitch] in
                    try? await Task.sleep(for: .microseconds(10))
                    toggleSwitch?.setOn(accessory.value, animated: true)
                }
            }
        }
        
        // MARK: -- DropDown
        
        private func createDropDownView(maxContentWidth: CGFloat) -> UIView {
            let result: UIStackView = UIStackView()
            result.translatesAutoresizingMaskIntoConstraints = false
            result.axis = .horizontal
            result.distribution = .fill
            result.alignment = .center
            result.spacing = Values.verySmallSpacing
            
            let imageView: UIImageView = UIImageView(image: UIImage(systemName: "arrowtriangle.down.fill"))
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.themeTintColor = .textPrimary
            imageView.set(.width, to: 10)
            imageView.set(.height, to: 10)
            
            let label: UILabel = UILabel()
            label.translatesAutoresizingMaskIntoConstraints = false
            label.font = .systemFont(ofSize: Values.smallFontSize, weight: .medium)
            label.themeTextColor = .textPrimary
            label.setContentHugging(to: .required)
            label.setCompressionResistance(to: .required)
            label.preferredMaxLayoutWidth = (maxContentWidth * 0.4)    /// Limit to 40% of content width
            label.numberOfLines = 0
            
            result.addArrangedSubview(imageView)
            result.addArrangedSubview(label)
            
            return result
        }
        
        private func layoutDropDownView(_ view: UIView?) {
            guard let stackView: UIStackView = view as? UIStackView else { return }
            
            stackView.pin(.top, to: .top, of: self)
            stackView.pin(.leading, to: .leading, of: self, withInset: Values.smallSpacing)
            stackView.pin(.trailing, to: .trailing, of: self, withInset: -Values.smallSpacing)
            stackView.pin(.bottom, to: .bottom, of: self)
            minWidthConstraint.isActive = true
        }
        
        private func configureDropDown(_ view: UIView?, _ accessory: SessionCell.AccessoryConfig.DropDown) {
            guard
                let stackView: UIStackView = view as? UIStackView,
                let label: UILabel = stackView.arrangedSubviews.last as? UILabel
            else { return }
            
            label.accessibilityIdentifier = accessory.accessibility?.identifier
            label.accessibilityLabel = accessory.accessibility?.label
            label.text = accessory.dynamicString()
        }
        
        // MARK: -- Radio
        
        private func createRadioView() -> UIView {
            let result: UIView = UIView()
            result.translatesAutoresizingMaskIntoConstraints = false
            result.isUserInteractionEnabled = false
            result.isAccessibilityElement = true
            result.layer.borderWidth = 1
            
            let radioView: UIView = UIView()
            radioView.translatesAutoresizingMaskIntoConstraints = false
            radioView.isUserInteractionEnabled = false
            radioView.isHidden = true
            
            result.addSubview(radioView)
            radioView.center(in: result)
            
            return result
        }
        
        private func layoutRadioView(_ view: UIView?, size: SessionCell.AccessoryConfig.Radio.Size) {
            guard
                let radioBorderView: UIView = view,
                let radioView: UIView = radioBorderView.subviews.first
            else { return }
            
            radioBorderView.layer.cornerRadius = (size.borderSize / 2)
            radioView.layer.cornerRadius = (size.selectionSize / 2)
            radioView.set(.width, to: size.selectionSize)
            radioView.set(.height, to: size.selectionSize)
            radioBorderView.set(.width, to: size.borderSize)
            radioBorderView.set(.height, to: size.borderSize)
            radioBorderView.pin(.top, to: .top, of: self)
            radioBorderView.pin(.leading, to: .leading, of: self, withInset: Values.smallSpacing)
            radioBorderView.pin(.trailing, to: .trailing, of: self, withInset: -Values.smallSpacing)
            radioBorderView.pin(.bottom, to: .bottom, of: self)
        }
        
        private func configureRadioView(_ view: UIView?, _ accessory: SessionCell.AccessoryConfig.Radio, isEnabled: Bool) {
            guard
                let radioBorderView: UIView = view,
                let radioView: UIView = radioBorderView.subviews.first
            else { return }
            
            let wasOldSelection: Bool = (!accessory.isSelected && accessory.wasSavedSelection)
            
            radioBorderView.accessibilityIdentifier = accessory.accessibility?.identifier
            radioBorderView.accessibilityLabel = accessory.accessibility?.label
            
            if accessory.isSelected || wasOldSelection {
                radioBorderView.accessibilityTraits.insert(.selected)
                radioBorderView.accessibilityValue = "selected"
            } else {
                radioBorderView.accessibilityTraits.remove(.selected)
                radioBorderView.accessibilityValue = nil
            }
            
            radioBorderView.themeBorderColor = {
                guard isEnabled else { return .radioButton_disabledBorder }
                
                return (accessory.isSelected ?
                    .radioButton_selectedBorder :
                    .radioButton_unselectedBorder
                )
            }()
            
            radioView.alpha = (wasOldSelection ? 0.3 : 1)
            radioView.isHidden = (!accessory.isSelected && !accessory.wasSavedSelection)
            radioView.themeBackgroundColor = {
                guard isEnabled else {
                    return (accessory.isSelected || wasOldSelection ?
                        .radioButton_disabledSelectedBackground :
                        .radioButton_disabledUnselectedBackground
                    )
                }
                
                return (accessory.isSelected || wasOldSelection ?
                    .radioButton_selectedBackground :
                    .radioButton_unselectedBackground
                )
            }()
        }
        
        // MARK: -- HighlightingBackgroundLabel
        
        private func createHighlightingBackgroundLabelView(maxContentWidth: CGFloat) -> UIView {
            let result: SessionHighlightingBackgroundLabel = SessionHighlightingBackgroundLabel()
            result.preferredMaxLayoutWidth = (maxContentWidth * 0.4)    /// Limit to 40% of content width
            
            return result
        }
        
        private func layoutHighlightingBackgroundLabelView(_ view: UIView?) {
            guard let label: SessionHighlightingBackgroundLabel = view as? SessionHighlightingBackgroundLabel else {
                return
            }
            
            label.pin(.top, to: .top, of: self)
            label.pin(.leading, to: .leading, of: self, withInset: Values.smallSpacing)
            label.pin(.trailing, to: .trailing, of: self, withInset: -Values.smallSpacing)
            label.pin(.bottom, to: .bottom, of: self)
            minWidthConstraint.isActive = true
        }
        
        private func configureHighlightingBackgroundLabelView(_ view: UIView?, _ accessory: SessionCell.AccessoryConfig.HighlightingBackgroundLabel, tintColor: ThemeValue) {
            guard let label: SessionHighlightingBackgroundLabel = view as? SessionHighlightingBackgroundLabel else {
                return
            }
            
            label.isAccessibilityElement = (accessory.accessibility != nil)
            label.accessibilityIdentifier = accessory.accessibility?.identifier
            label.accessibilityLabel = accessory.accessibility?.label
            label.text = accessory.title
            label.themeTextColor = tintColor
        }
        
        // MARK: -- HighlightingBackgroundLabelAndRadio
        
        private func createHighlightingBackgroundLabelAndRadioView(maxContentWidth: CGFloat) -> UIView {
            let result: UIView = UIView()
            let label: SessionHighlightingBackgroundLabel = SessionHighlightingBackgroundLabel()
            let radio: UIView = createRadioView()
            label.preferredMaxLayoutWidth = (maxContentWidth * 0.4)    /// Limit to 40% of content width
            
            result.addSubview(label)
            result.addSubview(radio)
            
            return result
        }
        
        private func layoutHighlightingBackgroundLabelAndRadioView(_ view: UIView?, size: SessionCell.AccessoryConfig.HighlightingBackgroundLabelAndRadio.Size) {
            guard
                let view: UIView = view,
                let label: SessionHighlightingBackgroundLabel = view.subviews.first as? SessionHighlightingBackgroundLabel,
                let radioBorderView: UIView = view.subviews.last,
                let radioView: UIView = radioBorderView.subviews.first
            else { return }
            
            label.pin(to: self)
            
            label.pin(.top, to: .top, of: self)
            label.pin(.leading, to: .leading, of: self, withInset: Values.smallSpacing)
            label.pin(.trailing, to: .leading, of: radioBorderView, withInset: -Values.smallSpacing)
            label.pin(.bottom, to: .bottom, of: self)
            
            radioBorderView.layer.cornerRadius = (size.borderSize / 2)
            radioView.layer.cornerRadius = (size.selectionSize / 2)
            radioView.set(.width, to: size.selectionSize)
            radioView.set(.height, to: size.selectionSize)
            radioBorderView.set(.width, to: size.borderSize)
            radioBorderView.set(.height, to: size.borderSize)
            radioBorderView.center(.vertical, in: self)
            radioBorderView.pin(.trailing, to: .trailing, of: self, withInset: -Values.smallSpacing)
            minWidthConstraint.isActive = true
            
            view.pin(to: self)
        }
        
        private func configureHighlightingBackgroundLabelAndRadioView(
            _ view: UIView?,
            _ accessory: SessionCell.AccessoryConfig.HighlightingBackgroundLabelAndRadio,
            tintColor: ThemeValue,
            isEnabled: Bool
        ) {
            guard
                let view: UIView = view,
                let label: SessionHighlightingBackgroundLabel = view.subviews.first as? SessionHighlightingBackgroundLabel,
                let radioBorderView: UIView = view.subviews.last,
                let radioView: UIView = radioBorderView.subviews.first
            else { return }
            
            let wasOldSelection: Bool = (!accessory.isSelected && accessory.wasSavedSelection)
            
            label.isAccessibilityElement = (accessory.accessibility != nil)
            label.accessibilityIdentifier = accessory.accessibility?.identifier
            label.accessibilityLabel = accessory.accessibility?.label
            label.text = accessory.title
            label.themeTextColor = tintColor
            
            radioBorderView.isAccessibilityElement = true
            radioBorderView.accessibilityIdentifier = accessory.accessibility?.identifier
            radioBorderView.accessibilityLabel = accessory.accessibility?.label
            
            if accessory.isSelected || wasOldSelection {
                radioView.accessibilityTraits.insert(.selected)
                radioView.accessibilityValue = "selected"
            } else {
                radioView.accessibilityTraits.remove(.selected)
                radioView.accessibilityValue = nil
            }
            
            radioBorderView.themeBorderColor = {
                guard isEnabled else { return .radioButton_disabledBorder }
                
                return (accessory.isSelected ?
                    .radioButton_selectedBorder :
                    .radioButton_unselectedBorder
                )
            }()
            radioView.alpha = (wasOldSelection ? 0.3 : 1)
            radioView.isHidden = (!accessory.isSelected && !accessory.wasSavedSelection)
            radioView.themeBackgroundColor = {
                guard isEnabled else {
                    return (accessory.isSelected || wasOldSelection ?
                        .radioButton_disabledSelectedBackground :
                        .radioButton_disabledUnselectedBackground
                    )
                }
                
                return (accessory.isSelected || wasOldSelection ?
                    .radioButton_selectedBackground :
                    .radioButton_unselectedBackground
                )
            }()
        }
            
        // MARK: -- DisplayPicture
        
        private func createDisplayPictureView() -> ProfilePictureView {
            return ProfilePictureView(size: .list, dataManager: nil)
        }
        
        private func layoutDisplayPictureView(_ view: UIView?, size: ProfilePictureView.Size) {
            guard let profilePictureView: ProfilePictureView = view as? ProfilePictureView else { return }
            
            profilePictureView.pin(to: self)
            fixedWidthConstraint.constant = size.viewSize
            fixedWidthConstraint.isActive = true
        }
        
        private func configureDisplayPictureView(
            _ view: UIView?,
            _ accessory: SessionCell.AccessoryConfig.DisplayPicture,
            using dependencies: Dependencies
        ) {
            guard let profilePictureView: ProfilePictureView = view as? ProfilePictureView else { return }
            
            // Note: We MUST set the 'size' property before triggering the 'update'
            // function or the profile picture won't layout correctly
            profilePictureView.accessibilityIdentifier = accessory.accessibility?.identifier
            profilePictureView.accessibilityLabel = accessory.accessibility?.label
            profilePictureView.isAccessibilityElement = (accessory.accessibility != nil)
            profilePictureView.size = accessory.size
            profilePictureView.setDataManager(dependencies[singleton: .imageDataManager])
            profilePictureView.update(
                publicKey: accessory.id,
                threadVariant: accessory.threadVariant,
                displayPictureUrl: accessory.displayPictureUrl,
                profile: accessory.profile,
                profileIcon: accessory.profileIcon,
                additionalProfile: accessory.additionalProfile,
                additionalProfileIcon: accessory.additionalProfileIcon,
                using: dependencies
            )
        }
        
        // MARK: -- Search
        
        private func createSearchView() -> ContactsSearchBar {
            let result: ContactsSearchBar = ContactsSearchBar()
            result.themeTintColor = .textPrimary
            result.themeBackgroundColor = .clear
            result.searchTextField.themeBackgroundColor = .backgroundSecondary
            result.delegate = self
            
            return result
        }
        
        private func layoutSearchView(_ view: UIView?) {
            guard let searchBar: ContactsSearchBar = view as? ContactsSearchBar else { return }
            
            searchBar.pin(.top, to: .top, of: self)
            searchBar.pin(.leading, to: .leading, of: self, withInset: -8)  // Removing default inset
            searchBar.pin(.trailing, to: .trailing, of: self, withInset: 8) // Removing default inset
            searchBar.pin(.bottom, to: .bottom, of: self)
        }
        
        private func configureSearchView(_ view: UIView?, _ accessory: SessionCell.AccessoryConfig.Search) {
            guard let searchBar: ContactsSearchBar = view as? ContactsSearchBar else { return }
            
            self.searchTermChanged = accessory.searchTermChanged
            searchBar.accessibilityIdentifier = accessory.accessibility?.identifier
            searchBar.accessibilityLabel = accessory.accessibility?.label
            searchBar.placeholder = accessory.placeholder
        }
            
        // MARK: -- Button
        
        private func createButtonView() -> SessionButton {
            let result: SessionButton = SessionButton(style: .bordered, size: .medium)
            result.addTarget(self, action: #selector(buttonTapped), for: .touchUpInside)
            
            return result
        }
        
        private func layoutButtonView(_ view: UIView?) {
            guard let button: SessionButton = view as? SessionButton else { return }
            
            button.pin(to: self)
            minWidthConstraint.isActive = true
        }
        
        private func configureButtonView(_ view: UIView?, _ accessory: SessionCell.AccessoryConfig.Button) {
            guard let button: SessionButton = view as? SessionButton else { return }
            
            self.onTap = accessory.run
            button.accessibilityIdentifier = accessory.accessibility?.identifier
            button.accessibilityLabel = accessory.accessibility?.label
            button.setTitle(accessory.title, for: .normal)
            button.style = accessory.style
            button.isHidden = false
        }
            
        // MARK: -- Custom
        
        private func layoutCustomView(_ view: UIView?, size: SessionCell.Accessory.Size) {
            guard let view: UIView = view else { return }
            
            switch size {
                case .fixed(let width, let height):
                    view.set(.width, to: width)
                    view.set(.height, to: height)
                    fixedWidthConstraint.isActive = (width <= fixedWidthConstraint.constant)
                    minWidthConstraint.isActive = !fixedWidthConstraint.isActive
                    
                case .fillWidth(let height):
                    view.set(.width, to: .width, of: self)
                    view.set(.height, to: height)
                    minWidthConstraint.isActive = true
                    
                case .fillWidthWrapHeight:
                    view.set(.width, to: .width, of: self)
                    view.setContentHugging(.vertical, to: .required)
                    view.setCompressionResistance(.vertical, to: .required)
                    minWidthConstraint.isActive = true
            }
            
            view.pin(.top, to: .top, of: self)
            view.pin(.bottom, to: .bottom, of: self)
            view.pin(.leading, to: .leading, of: self, withInset: Values.smallSpacing)
            view.pin(.trailing, to: .trailing, of: self, withInset: -Values.smallSpacing)
            view.pin(.top, to: .top, of: self)
            view.pin(.bottom, to: .bottom, of: self)
        }
        
        private func configureCustomView(_ view: UIView?, _ accessory: SessionCell.AccessoryConfig.AnyCustom) {
            view?.accessibilityIdentifier = accessory.accessibility?.identifier
            view?.accessibilityLabel = accessory.accessibility?.label
        }
    }
}
