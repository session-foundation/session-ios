// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit

final class AppIconGridView: UIView {
    public static let size: SessionCell.Accessory.Size = .fillWidthWrapHeight
    
    /// Excluding the default icon
    private var icons: [AppIcon] = AppIcon.allCases.filter { $0 != .session }
    private var onChange: ((AppIcon) -> ())?
    
    // MARK: - Components
    
    lazy var contentViewViewHeightConstraint: NSLayoutConstraint = contentView.heightAnchor
        .constraint(equalToConstant: IconView.expectedSize)
    private var iconViewTopConstraints: [NSLayoutConstraint] = []
    private var iconViewLeadingConstraints: [NSLayoutConstraint] = []
    
    private let contentView: UIView = UIView()
    
    private lazy var iconViews: [IconView] = icons.map { icon in
        IconView(icon: icon) { [weak self] in self?.onChange?(icon) }
    }
    
    // MARK: - Initializtion
    
    init() {
        super.init(frame: .zero)
        
        setupUI()
    }
    
    required init?(coder: NSCoder) {
        fatalError("Use init(theme:) instead")
    }
    
    // MARK: - Layout
    
    private func setupUI() {
        addSubview(contentView)
        
        iconViews.forEach { contentView.addSubview($0) }
        
        setupLayout()
    }
    
    private func setupLayout() {
        contentView.pin(to: self)
        
        iconViews.forEach {
            iconViewTopConstraints.append($0.pin(.top, to: .top, of: contentView))
            iconViewLeadingConstraints.append($0.pin(.leading, to: .leading, of: contentView))
        }
        
//        iconViews.last?.pin(.bottom, to: .bottom, of: contentView)
    }
    
    override var intrinsicContentSize: CGSize {
        var x: CGFloat = 0
        let availableWidth = (bounds.width > 0 ? bounds.width : UIScreen.main.bounds.width)
        let expectedHeight: CGFloat = iconViews.enumerated().reduce(into: 0) { result, next in
            guard next.offset < iconViews.count - 1 else { return }
            
            x = (x + IconView.expectedSize + Values.smallSpacing)
            
            if x + IconView.expectedSize > availableWidth {
                x = 0
                result = (result + IconView.expectedSize + Values.smallSpacing)
            }
        }
        
        return CGSize(
            width: UIView.noIntrinsicMetric,
            height: (expectedHeight + IconView.expectedSize)
        )
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        
        /// Only bother laying out if we haven't already done so
        guard
            !iconViewTopConstraints.contains(where: { $0.constant > 0 }) ||
            !iconViewLeadingConstraints.contains(where: { $0.constant > 0 })
        else { return }
        
        /// We manually layout the `IconView` instances because it's easier than trying to get
        /// a good "overflow" behaviour doing it manually than using existing UI elements
        var targetX: CGFloat = 0
        var targetY: CGFloat = 0
        
        iconViews.enumerated().forEach { index, iconView in
            iconViewTopConstraints[index].constant = targetY
            iconViewLeadingConstraints[index].constant = targetX
            
            UIView.performWithoutAnimation { iconView.layoutIfNeeded() }
            
            /// Only update the target positions if there are more views
            guard index < iconViews.count - 1 else { return }
            
            /// Calculate the X position for the next icon
            targetX = (targetX + IconView.expectedSize + Values.smallSpacing)
            
            /// If there is no more room then overflow to the next line
            if targetX + IconView.expectedSize > bounds.width {
                targetX = 0
                targetY = (targetY + IconView.expectedSize + Values.smallSpacing)
            }
        }
        
        contentViewViewHeightConstraint.constant = (targetY + IconView.expectedSize)
    }
    
    // MARK: - Content
    
    fileprivate func update(with selectedIcon: AppIcon?, onChange: @escaping (AppIcon) -> ()) {
        self.onChange = onChange
        
        iconViews.enumerated().forEach { index, iconView in
            iconView.update(isSelected: (icons[index] == selectedIcon))
        }
    }
}

// MARK: - Info

extension AppIconGridView: SessionCell.Accessory.CustomView {
    struct Info: Equatable, SessionCell.Accessory.CustomViewInfo {
        typealias View = AppIconGridView
        
        let selectedIcon: AppIcon?
        let onChange: (AppIcon) -> ()
        
        static func == (lhs: Info, rhs: Info) -> Bool {
            return (lhs.selectedIcon == rhs.selectedIcon)
        }
        
        func hash(into hasher: inout Hasher) {
            selectedIcon.hash(into: &hasher)
        }
    }
    
    static func create(using dependencies: Dependencies) -> AppIconGridView {
        return AppIconGridView()
    }
    
    func update(with info: Info) {
        update(with: info.selectedIcon, onChange: info.onChange)
    }
}

// MARK: - IconView

extension AppIconGridView {
    class IconView: UIView {
        fileprivate static let imageSize: CGFloat = 85
        fileprivate static let selectionInset: CGFloat = 4
        fileprivate static var expectedSize: CGFloat = (imageSize + (selectionInset * 2))
        
        private let onSelected: () -> ()
        
        // MARK: - Components
        
        private lazy var backgroundButton: UIButton = UIButton(
            type: .custom,
            primaryAction: UIAction(handler: { [weak self] _ in
                self?.onSelected()
            })
        )
        
        private let selectionBorderView: UIView = {
            let result: UIView = UIView()
            result.translatesAutoresizingMaskIntoConstraints = false
            result.isUserInteractionEnabled = false
            result.themeBorderColor = .radioButton_selectedBorder
            result.layer.borderWidth = 2
            result.layer.cornerRadius = 21
            result.isHidden = true
            
            return result
        }()
        
        private let imageView: UIImageView = {
            let result: UIImageView = UIImageView()
            result.translatesAutoresizingMaskIntoConstraints = false
            result.isUserInteractionEnabled = false
            result.contentMode = .scaleAspectFit
            result.layer.cornerRadius = 16
            
            return result
        }()
        
        // MARK: - Initializtion
        
        init(icon: AppIcon, onSelected: @escaping () -> ()) {
            self.onSelected = onSelected
            
            super.init(frame: .zero)
            
            setupUI(icon: icon)
        }
        
        required init?(coder: NSCoder) {
            fatalError("Use init(color:) instead")
        }
        
        // MARK: - Layout
        
        private func setupUI(icon: AppIcon) {
            imageView.image = UIImage(named: icon.previewImageName)
            
            addSubview(backgroundButton)
            addSubview(selectionBorderView)
            addSubview(imageView)
            
            setupLayout()
        }
        
        private func setupLayout() {
            translatesAutoresizingMaskIntoConstraints = false
            
            backgroundButton.pin(to: self)
            
            selectionBorderView.pin(to: self)
            
            imageView.pin(to: selectionBorderView, withInset: IconView.selectionInset)
            imageView.set(.width, to: IconView.imageSize)
            imageView.set(.height, to: IconView.imageSize)
        }
        
        // MARK: - Content
        
        func update(isSelected: Bool) {
            selectionBorderView.isHidden = !isSelected
        }
    }
}
