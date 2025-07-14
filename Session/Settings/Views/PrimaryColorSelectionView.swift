// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit
import SessionUtilitiesKit

final class PrimaryColorSelectionView: UIView {
    public static let size: SessionCell.Accessory.Size = .fillWidthWrapHeight
    
    private var onChange: ((Theme.PrimaryColor) -> ())?
    
    // MARK: - Components
    
    private let scrollView: UIScrollView = {
        let result: UIScrollView = UIScrollView()
        result.translatesAutoresizingMaskIntoConstraints = false
        result.showsVerticalScrollIndicator = false
        result.showsHorizontalScrollIndicator = false

        if Dependencies.isRTL {
            result.transform = CGAffineTransform.identity.scaledBy(x: -1, y: 1)
        }

        return result
    }()

    private let stackView: UIStackView = {
        let result: UIStackView = UIStackView()
        result.translatesAutoresizingMaskIntoConstraints = false
        result.axis = .horizontal
        result.distribution = .equalCentering
        result.alignment = .fill
        result.spacing = Values.verySmallSpacing

        return result
    }()

    private lazy var primaryColorViews: [ColourView] = Theme.PrimaryColor.allCases
        .map { color in ColourView(color: color) { [weak self] in self?.onChange?(color) } }
    
    // MARK: - Initializtion
    
    init() {
        super.init(frame: .zero)
        
        setupUI()
    }
    
    required init?(coder: NSCoder) {
        fatalError("Use init(color:) instead")
    }
    
    // MARK: - Layout
    
    private func setupUI() {
        addSubview(scrollView)
        scrollView.addSubview(stackView)
        primaryColorViews.forEach { stackView.addArrangedSubview($0) }
        
        setupLayout()
        
        // Register an observer so when the theme changes the selected theme and primary colour
        // are both updated to match
        ThemeManager.onThemeChange(observer: self) { [weak self] _, primaryColor in
            self?.primaryColorViews.forEach { view in
                view.update(isSelected: (primaryColor == view.color))
            }
        }
    }
    
    private func setupLayout() {
        scrollView.pin(.top, to: .top, of: self)
        scrollView.pin(.leading, to: .leading, of: self)
        scrollView.pin(.trailing, lessThanOrEqualTo: .trailing, of: self)
            .setting(priority: .required)
        scrollView.pin(.bottom, to: .bottom, of: self)
        scrollView.set(.width, to: .width, of: stackView)
            .setting(priority: .defaultLow)
        
        stackView.pin(to: scrollView)
        stackView.set(.height, to: .height, of: scrollView)
    }
    
    // MARK: - Content
    
    func update(
        with primaryColor: Theme.PrimaryColor,
        onChange: @escaping (Theme.PrimaryColor) -> ()
    ) {
        self.onChange = onChange
        
        primaryColorViews.forEach { view in
            view.update(isSelected: view.color == primaryColor)
        }
    }
}

// MARK: - Info

extension PrimaryColorSelectionView: SessionCell.Accessory.CustomView {
    struct Info: Equatable, SessionCell.Accessory.CustomViewInfo {
        typealias View = PrimaryColorSelectionView
        
        let primaryColor: Theme.PrimaryColor
        let onChange: @MainActor (Theme.PrimaryColor) -> ()
        
        static func == (lhs: Info, rhs: Info) -> Bool {
            return (lhs.primaryColor == rhs.primaryColor)
        }
        
        func hash(into hasher: inout Hasher) {
            primaryColor.hash(into: &hasher)
        }
    }
    
    static func create(maxContentWidth: CGFloat, using dependencies: Dependencies) -> PrimaryColorSelectionView {
        return PrimaryColorSelectionView()
    }
    
    func update(with info: Info) {
        update(with: info.primaryColor, onChange: info.onChange)
    }
}

// MARK: - ColourView

extension PrimaryColorSelectionView {
    class ColourView: UIView {
        private static let selectionBorderSize: CGFloat = 34
        private static let selectionSize: CGFloat = 26
        
        fileprivate let color: Theme.PrimaryColor
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
            result.layer.borderWidth = 1
            result.layer.cornerRadius = (ColourView.selectionBorderSize / 2)
            result.isHidden = true
            
            return result
        }()
        
        private let selectionView: UIView = {
            let result: UIView = UIView()
            result.translatesAutoresizingMaskIntoConstraints = false
            result.isUserInteractionEnabled = false
            result.layer.cornerRadius = (ColourView.selectionSize / 2)
            
            return result
        }()
        
        // MARK: - Initializtion
        
        init(color: Theme.PrimaryColor, onSelected: @escaping () -> ()) {
            self.color = color
            self.onSelected = onSelected
            
            super.init(frame: .zero)
            
            setupUI(color: color)
        }
        
        required init?(coder: NSCoder) {
            fatalError("Use init(color:) instead")
        }
        
        // MARK: - Layout
        
        private func setupUI(color: Theme.PrimaryColor) {
            // Set the appropriate colours
            selectionView.themeBackgroundColor = .explicitPrimary(color)
            
            // Add the UI
            addSubview(backgroundButton)
            addSubview(selectionBorderView)
            addSubview(selectionView)
            
            setupLayout()
        }
        
        private func setupLayout() {
            backgroundButton.pin(to: self)
            
            selectionBorderView.pin(to: self)
            selectionBorderView.set(.width, to: ColourView.selectionBorderSize)
            selectionBorderView.set(.height, to: ColourView.selectionBorderSize)
            
            selectionView.center(in: selectionBorderView)
            selectionView.set(.width, to: ColourView.selectionSize)
            selectionView.set(.height, to: ColourView.selectionSize)
        }
        
        // MARK: - Content
        
        func update(isSelected: Bool) {
            selectionBorderView.isHidden = !isSelected
        }
    }
}
