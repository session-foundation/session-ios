// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUtilitiesKit

class ManualDropdownPresenter: NSObject {
    private lazy var menuView: CustomMenuView = {
        let result = CustomMenuView()
        result.layer.shadowOffset = CGSize.zero
        result.layer.shadowOpacity = 0.4
        result.layer.shadowRadius = 4
        return result
    }()
    
    private lazy var overlayView: UIView = {
        let result = UIView()
        result.backgroundColor = .black.withAlphaComponent(0.01)
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(hide))
        result.addGestureRecognizer(tapGesture)
        return result
    }()
    
    private weak var presentingViewController: UIViewController?
    
    @MainActor
    func show(actions: [ContextMenuVC.Action], anchorView: UIView?, using dependencies: Dependencies, completion: @escaping () -> Void) {
        guard
            let topViewController = dependencies[singleton: .appContext].frontMostViewController,
            let barButtonView = anchorView
        else {
            return
        }
        
        menuView.createMenuButtons(
            actions,
            using: dependencies
        ) { [weak self] in
            self?.menuView.removeFromSuperview()
            self?.overlayView.removeFromSuperview()
            
            completion()
        }
        
        self.presentingViewController = topViewController
        
        guard let targetView = topViewController.view else {
            return
        }
        
        overlayView.frame = targetView.bounds
        targetView.addSubview(overlayView)

        targetView.addSubview(menuView)

        let buttonFrame = barButtonView.convert(barButtonView.bounds, to: targetView)
        
        let menuX = buttonFrame.maxX - menuView.frame.width
        let menuY = buttonFrame.maxY + 5
        
        menuView.frame.origin = CGPoint(x: menuX, y: menuY)
        menuView.alpha = 0
        menuView.transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
        
        UIView.animate(withDuration: 0.2) {
            self.menuView.alpha = 1
            self.menuView.transform = .identity
        }
    }
    
    @objc func hide() {
        UIView.animate(withDuration: 0.2, animations: {
            self.menuView.alpha = 0
            self.menuView.transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
        }) { _ in
            self.menuView.removeFromSuperview()
            self.overlayView.removeFromSuperview()
            
            self.presentingViewController = nil
        }
    }
}
