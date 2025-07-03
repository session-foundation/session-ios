// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit

public class GradientView: UIView {
    var oldBounds: CGRect = .zero
    
    public override func layoutSubviews() {
        super.layoutSubviews()
        
        guard oldBounds != bounds else { return }
        
        self.oldBounds = bounds
        
        self.layer.sublayers?
            .compactMap { $0 as? CAGradientLayer }
            .forEach { $0.frame = bounds }
    }
}

public class CyclicGradientImageView: UIImageView {
    private var colorStops: [UIColor] = [
        Theme.PrimaryColor.green.color,
        Theme.PrimaryColor.blue.color,
        Theme.PrimaryColor.purple.color,
        Theme.PrimaryColor.pink.color,
        Theme.PrimaryColor.red.color,
        Theme.PrimaryColor.orange.color,
        Theme.PrimaryColor.yellow.color
    ]

    private let gradientLayer = CAGradientLayer()
    private var timer: Timer?

    public override init(frame: CGRect) {
        super.init(frame: frame)
        setupGradient()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupGradient()
    }
    
    public override init(image: UIImage?) {
        super.init(image: image)
        setupGradient()
    }
    
    deinit {
        timer?.invalidate()
    }
    
    // Override image property to update mask when the image is set
    public override var image: UIImage? {
        didSet {
            updateMask()
        }
    }

    private func setupGradient() {
        gradientLayer.startPoint = CGPoint(x: 0, y: 0)
        gradientLayer.endPoint = CGPoint(x: 0, y: 1)
        updateGradientColors()
        layer.addSublayer(gradientLayer)
        gradientLayer.frame = bounds
        updateMask()
        
        // Animation Timer
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.cycleGradientColors()
        }
    }
    
    public override func layoutSubviews() {
        super.layoutSubviews()
        gradientLayer.frame = bounds
        updateMask()
    }
    
    private func updateGradientColors() {
        gradientLayer.colors = colorStops.map { $0.cgColor }
    }
    
    private func cycleGradientColors() {
        // Cyclically rotate color stops
        if let last = colorStops.popLast() {
            colorStops.insert(last, at: 0)
        }
        updateGradientColors()
    }

    private func updateMask() {
        guard let image = image else {
            gradientLayer.mask = nil
            return
        }
        let maskLayer = CALayer()
        maskLayer.contents = image.cgImage
        maskLayer.frame = bounds
        maskLayer.contentsGravity = .resizeAspect
        gradientLayer.mask = maskLayer
    }
}
