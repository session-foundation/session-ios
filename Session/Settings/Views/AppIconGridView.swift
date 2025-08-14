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
    private let maxContentWidth: CGFloat
    
    // MARK: - Components
    
    lazy var contentViewViewHeightConstraint: NSLayoutConstraint = contentView.heightAnchor
        .constraint(equalToConstant: IconView.expectedMinSize)
    private var iconViewTopConstraints: [NSLayoutConstraint] = []
    private var iconViewLeadingConstraints: [NSLayoutConstraint] = []
    private var iconViewWidthConstraints: [NSLayoutConstraint] = []
    
    private let contentView: UIView = UIView()
    
    private lazy var iconViews: [IconView] = icons.map { icon in
        let view = IconView(icon: icon) { [weak self] in self?.onChange?(icon) }
        view.accessibilityIdentifier = icon.accessibilityIdentifier
        view.isAccessibilityElement = true
        
        return view
    }
    
    // MARK: - Initializtion
    
    init(maxContentWidth: CGFloat) {
        self.maxContentWidth = maxContentWidth
        
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
            iconViewWidthConstraints.append($0.set(.width, to: IconView.minImageSize))
        }
    }
    
    /// We want the icons to fill the available space in either a 6x1 grid or a 3x2 grid depending on the available width so
    /// we need to calculate the `targetSize` and `targetSpacing` for the `IconView`
    private func calculatedSizes(for availableWidth: CGFloat) -> (size: CGFloat, spacing: CGFloat) {
        let acceptedIconsPerColumn: [CGFloat] = [CGFloat(iconViews.count), 3]
        let minSpacing: CGFloat = Values.smallSpacing
        
        for iconsPerColumn in acceptedIconsPerColumn {
            let minTotalSpacing: CGFloat = ((iconsPerColumn - 1) * minSpacing)
            let availableWidthLessSpacing: CGFloat = (availableWidth - minTotalSpacing)
            let size: CGFloat = floor(availableWidthLessSpacing / iconsPerColumn)
            let spacing: CGFloat = ((availableWidth - (size * iconsPerColumn)) / (iconsPerColumn - 1))
            
            /// If all of the icons would fit and be larger than the expected min size then that's the size we want to use
            if size >= IconView.expectedMinSize {
                return (size, spacing)
            }
        }
        
        /// Fallback to the min sizes to prevent a future change resulting in a `0` value
        return (IconView.expectedMinSize, minSpacing)
    }
    
    private func calculateIconViewFrames() -> [CGRect] {
        let (targetSize, targetSpacing): (CGFloat, CGFloat) = calculatedSizes(for: maxContentWidth)
        var nextX: CGFloat = 0
        var nextY: CGFloat = 0
        
        /// We calculate the size based on the position for the next `IconView` so we will end up with an extra `Values.smallSpacing`
        /// on both dimensions which needs to be removed
        return iconViews.enumerated().reduce(into: []) { result, next in
            /// First add the calculated position/size for this element
            result.append(
                CGRect(
                    x: nextX,
                    y: nextY,
                    width: targetSize,
                    height: targetSize
                )
            )
            
            /// We are at the last element so no need to calculate additional frames
            guard next.offset < iconViews.count - 1 else { return }
            
            /// Calculate the position the next `IconView` should have
            nextX += (targetSize + targetSpacing)
            
            /// If the end of the next icon would go past the `maxContentWidth` then wrap to the next line
            if nextX + targetSize > maxContentWidth {
                nextX = 0
                nextY += (targetSize + targetSpacing)
            }
        }
    }
    
    override var intrinsicContentSize: CGSize {
        return calculateIconViewFrames().reduce(.zero) { result, next -> CGSize in
            CGSize(width: max(result.width, next.maxX), height: max(result.height, next.maxY))
        }
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        
        /// Only bother laying out if we haven't already done so
        guard
            !iconViewTopConstraints.contains(where: { $0.constant > 0 }) ||
            !iconViewLeadingConstraints.contains(where: { $0.constant > 0 })
        else { return }
        
        /// We manually layout the `IconView` instances because it's easier than trying to get a good "overflow" behaviour doing it
        /// manually than using existing UI elements
        let frames: [CGRect] = calculateIconViewFrames()
        
        /// Sanity check to avoid an index out of bounds
        guard
            iconViews.count == frames.count &&
            iconViews.count == iconViewTopConstraints.count &&
            iconViews.count == iconViewLeadingConstraints.count &&
            iconViews.count == iconViewWidthConstraints.count
        else { return }
        
        iconViews.enumerated().forEach { index, iconView in
            iconViewTopConstraints[index].constant = frames[index].minY
            iconViewLeadingConstraints[index].constant = frames[index].minX
            iconViewWidthConstraints[index].constant = frames[index].width
            
            UIView.performWithoutAnimation { iconView.layoutIfNeeded() }
        }
        
        contentViewViewHeightConstraint.constant = frames
            .reduce(0) { result, next -> CGFloat in max(result, next.maxY) }
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
    
    static func create(maxContentWidth: CGFloat, using dependencies: Dependencies) -> AppIconGridView {
        return AppIconGridView(maxContentWidth: maxContentWidth)
    }
    
    func update(with info: Info) {
        update(with: info.selectedIcon, onChange: info.onChange)
    }
}

// MARK: - IconView

extension AppIconGridView {
    class IconView: UIView {
        fileprivate static let minImageSize: CGFloat = 85
        fileprivate static let selectionInset: CGFloat = 4
        fileprivate static var expectedMinSize: CGFloat = (minImageSize + (selectionInset * 2))
        
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
            result.clipsToBounds = true
            
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
            imageView.set(.height, to: .width, of: imageView)
        }
        
        // MARK: - Content
        
        func update(isSelected: Bool) {
            selectionBorderView.isHidden = !isSelected
        }
    }
}
