// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit
import SessionUtilitiesKit

class DraggableView: UIView {
    let dependencies: Dependencies
    
    init(using dependencies: Dependencies) {
        self.dependencies = dependencies
        
        super.init(frame: .zero)
        
        let panGestureRecognizer = UIPanGestureRecognizer(target: self, action: #selector(handlePanForDragging))
        addGestureRecognizer(panGestureRecognizer)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    @objc private func handlePanForDragging(_ gesture: UIPanGestureRecognizer) {
        guard let superview: UIView = self.superview else { return }
        
        let location = gesture.location(in: superview)
        if let draggedView = gesture.view {
            draggedView.center = location
            
            if gesture.state == .ended {
                if draggedView.frame.midX >= (superview.layer.frame.width / 2) {
                    UIView.animate(withDuration: 0.5, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 1, options: .curveEaseIn, animations: {
                        draggedView.center.x = (superview.layer.frame.width - (draggedView.bounds.width / 2) - Values.smallSpacing)
                    }, completion: nil)
                }
                else
                {
                    UIView.animate(withDuration: 0.5, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 1, options: .curveEaseIn, animations: {
                        draggedView.center.x = ((draggedView.bounds.width / 2) + Values.smallSpacing)
                    }, completion: nil)
                }
                
                let topMargin = ((dependencies[singleton: .appContext].mainWindow?.safeAreaInsets.top ?? 0) + Values.veryLargeSpacing)
                if draggedView.frame.minY <= topMargin {
                    UIView.animate(withDuration: 0.5, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 1, options: .curveEaseIn, animations: {
                        draggedView.center.y = (topMargin + (draggedView.bounds.height / 2))
                    }, completion: nil)
                }
                
                let bottomMargin = (dependencies[singleton: .appContext].mainWindow?.safeAreaInsets.bottom ?? 0)
                if draggedView.frame.maxY >= superview.layer.frame.height {
                    UIView.animate(withDuration: 0.5, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 1, options: .curveEaseIn, animations: {
                        draggedView.center.y = (superview.layer.frame.height - (draggedView.bounds.height / 2) - bottomMargin)
                    }, completion: nil)
                }
            }
        }
    }
}
