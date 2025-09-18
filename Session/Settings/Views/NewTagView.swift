// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit
import SessionUtilitiesKit

final class NewTagView: UIView {
    public static let size: SessionCell.Accessory.Size = .fillWidthWrapHeight
    
    // MARK: - Components
    
    private lazy var newTagLabel: UILabel = {
        let result = UILabel()
        result.font = .systemFont(ofSize: Values.verySmallFontSize)
        result.textAlignment = .natural
        result.themeAttributedText = "sessionNew".localizedFormatted(in: result)
        
        return result
    }()

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
        addSubview(newTagLabel)
        newTagLabel.pin(.leading, to: .leading, of: self, withInset: -(Values.mediumSpacing + Values.verySmallSpacing))
        newTagLabel.pin([ UIView.VerticalEdge.top, UIView.VerticalEdge.bottom, UIView.HorizontalEdge.trailing ], to: self)
    }
    
    // MARK: - Content
    
    func update() {
        newTagLabel.themeAttributedText = "sessionNew".localizedFormatted(in: newTagLabel)
    }
}

// MARK: - Info

extension NewTagView: SessionCell.Accessory.CustomView {
    struct Info: Equatable, SessionCell.Accessory.CustomViewInfo {
        typealias View = NewTagView
    }
    
    static func create(maxContentWidth: CGFloat, using dependencies: Dependencies) -> NewTagView {
        return NewTagView()
    }
    
    func update(with info: Info) {
        update()
    }
}
