// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import UIKit

public class ShineButton: UIButton {
    private let shineLayer = CAGradientLayer()
    private var shineView: UIView?
    private var isAnimating = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupShine()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupShine()
    }

    private func setupShine() {
        // Setup a subview above content for the shine
        if shineView == nil {
            let view = UIView(frame: bounds)
            view.isUserInteractionEnabled = false
            addSubview(view)
            bringSubviewToFront(view)
            shineView = view
        }
        shineLayer.colors = [
            UIColor.white.withAlphaComponent(0).cgColor,
            UIColor.white.withAlphaComponent(0.5).cgColor,
            UIColor.white.withAlphaComponent(0).cgColor
        ]
        shineLayer.locations = [0, 0.5, 1]
        shineLayer.startPoint = CGPoint(x: 0, y: 0.5)
        shineLayer.endPoint = CGPoint(x: 1, y: 0.5)
        shineLayer.opacity = 1.0
        shineView?.layer.sublayers?.forEach { $0.removeFromSuperlayer() }
        shineView?.layer.addSublayer(shineLayer)
        isAnimating = false
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        shineView?.frame = bounds
        // Set initial shine layer size, so it fully covers the move
        shineLayer.frame = CGRect(x: -bounds.width, y: 0, width: bounds.width, height: bounds.height)
        // Start the animation if not already started
        if !isAnimating {
            isAnimating = true
            animateShine(first: true)
        }
    }

    private func animateShine(first: Bool) {
        // Always reset to the left before animating
        shineLayer.frame = CGRect(x: -bounds.width, y: 0, width: bounds.width, height: bounds.height)

        let anim = CABasicAnimation(keyPath: "position.x") // stringlint:ignore
        anim.fromValue = -bounds.width
        anim.toValue = bounds.width
        anim.duration = 0.6
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        anim.fillMode = .forwards
        anim.isRemovedOnCompletion = true

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self = self, self.isAnimating else { return }
            // After the shine passes, wait 2.4s, then repeat
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
                self.animateShine(first: false)
            }
        }
        shineLayer.add(anim, forKey: "shine") // stringlint:ignore
        CATransaction.commit()
    }

    func stopShineAnimation() {
        isAnimating = false
        shineLayer.removeAllAnimations()
    }
}
