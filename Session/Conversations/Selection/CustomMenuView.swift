// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUtilitiesKit
import SessionUIKit

class CustomMenuView: UIView {
    private lazy var stackView: UIStackView = {
        let result = UIStackView()
        result.axis = .vertical
        result.spacing = 0
        result.distribution = .fillEqually
        result.translatesAutoresizingMaskIntoConstraints = false
        return result
    }()
    
    init() {
        super.init(frame: .zero)
        setupView()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupView() {
        self.themeBackgroundColor = .contextMenu_background
        self.layer.cornerRadius = 8
        self.clipsToBounds = true

        addSubview(stackView)
        
        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: self.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: self.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: self.trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: self.bottomAnchor)
        ])
    }
    
    func createMenuButtons(_ actions: [ContextMenuVC.Action], using dependencies: Dependencies, dismiss: @escaping () -> Void) {
        actions.forEach { action in
            let item = ContextMenuVC.ActionView(
                for: action,
                using: dependencies,
                dismiss: dismiss
            )
            stackView.addArrangedSubview(item)
        }
        
        let buttonHeight: CGFloat = Values.largeButtonHeight
        let menuWidth: CGFloat = Values.menuContainerWidth
        let totalHeight = buttonHeight * CGFloat(actions.count)
        self.frame = CGRect(origin: .zero, size: CGSize(width: menuWidth, height: totalHeight))
    }
}
