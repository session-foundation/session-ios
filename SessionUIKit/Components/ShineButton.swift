// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import UIKit

public class ShineButton: UIButton {
    private let shineLayer = CAGradientLayer()
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupShineLayer()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupShineLayer()
    }
    
    private func setupShineLayer() {
        // Gradient: transparent - white - transparent (a "glare bar")
        shineLayer.colors = [
            UIColor.white.withAlphaComponent(0).cgColor,
            UIColor.white.withAlphaComponent(0.5).cgColor,
            UIColor.white.withAlphaComponent(0).cgColor
        ]
        shineLayer.locations = [0, 0.5, 1]
        shineLayer.startPoint = CGPoint(x: 0, y: 0.5)
        shineLayer.endPoint = CGPoint(x: 1, y: 0.5)
        shineLayer.frame = bounds
        shineLayer.opacity = 0.0 // Hidden initially
        
        // Add the shineLayer above the button's content
        layer.addSublayer(shineLayer)
        // Optional: make sure it doesn't block interactions
        shineLayer.isOpaque = false
        
        startShineAnimation()
    }
    
    public override func layoutSubviews() {
        super.layoutSubviews()
        shineLayer.frame = bounds
    }
    
    // MARK: - Animation
    func startShineAnimation() {
        runShine()
    }
    
    private func runShine() {
        // Start position: off the left
        shineLayer.frame = CGRect(
            x: -bounds.width,
            y: 0,
            width: bounds.width,
            height: bounds.height
        )
        
        // Animate to: off the right
        let animation = CABasicAnimation(keyPath: "position.x") // stringlint:ignore
        animation.fromValue = -bounds.width / 2
        animation.toValue = bounds.width * 1.5
        animation.duration = 0.6
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = true
        
        // Completion: schedule next shine
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
                self?.runShine()
                self?.shineLayer.opacity = 1.0
            }
        }
        shineLayer.add(animation, forKey: "shine") // stringlint:ignore
        CATransaction.commit()
    }
    
    func stopShineAnimation() {
        shineLayer.opacity = 0.0
        shineLayer.removeAllAnimations()
    }
}
