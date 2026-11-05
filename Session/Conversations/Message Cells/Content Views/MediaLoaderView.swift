// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit

final class MediaLoaderView: UIView {
    private let bar = UIView()
    private var cachedWidth: CGFloat = 0
    private var isAnimating: Bool = false
    
    /// The loop below never ends on its own, and off-screen `UIView.animate` completes immediately so it degrades to a pair
    /// of 0.25s timers per cycle, so it must only run while it can be seen
    private var shouldAnimate: Bool { window != nil && !isHidden }
    
    override var isHidden: Bool {
        didSet { startAnimatingIfNeeded() }
    }
    
    private lazy var barLeftConstraint = bar.pin(.left, to: .left, of: self)
    private lazy var barRightConstraint = bar
        .pin(.right, to: .right, of: self)
        .setting(priority: .defaultHigh)
    
    // MARK: - Lifecycle
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        
        setUpViewHierarchy()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUpViewHierarchy()
    }
    
    private func setUpViewHierarchy() {
        bar.themeBackgroundColor = .primary
        bar.set(.height, to: 8)
        addSubview(bar)
        
        barLeftConstraint.isActive = true
        bar.pin(.top, to: .top, of: self)
        barRightConstraint.isActive = true
        bar.pin(.bottom, to: .bottom, of: self).setting(priority: .defaultHigh)
    }
    
    override func didMoveToWindow() {
        super.didMoveToWindow()
        
        startAnimatingIfNeeded()
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        
        if cachedWidth != bounds.width {
            cachedWidth = bounds.width
        }
    }
    
    // MARK: - Animation
    
    private func startAnimatingIfNeeded() {
        guard shouldAnimate && !isAnimating else { return }
        
        isAnimating = true
        barLeftConstraint.constant = 0
        step1()
    }
    
    func step1() {
        guard shouldAnimate else { isAnimating = false; return }
        
        barRightConstraint.constant = -cachedWidth
        UIView.animate(withDuration: 0.5, animations: { [weak self] in
            guard let self = self else { return }
            self.barRightConstraint.constant = 0
            self.layoutIfNeeded()
        }, completion: { [weak self] _ in
            self?.step2()
        })
    }
    
    func step2() {
        guard shouldAnimate else { isAnimating = false; return }
        
        barLeftConstraint.constant = 0
        UIView.animate(withDuration: 0.5, animations: { [weak self] in
            guard let self = self else { return }
            self.barLeftConstraint.constant = cachedWidth
            self.layoutIfNeeded()
        }, completion: { [weak self] _ in
            Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { _ in
                self?.step3()
            }
        })
    }
    
    func step3() {
        guard shouldAnimate else { isAnimating = false; return }
        
        barLeftConstraint.constant = bounds.width
        UIView.animate(withDuration: 0.5, animations: { [weak self] in
            guard let self = self else { return }
            self.barLeftConstraint.constant = 0
            self.layoutIfNeeded()
        }, completion: { [weak self] _ in
            self?.step4()
        })
    }
    
    func step4() {
        guard shouldAnimate else { isAnimating = false; return }
        
        barRightConstraint.constant = 0
        UIView.animate(withDuration: 0.5, animations: { [weak self] in
            guard let self = self else { return }
            self.barRightConstraint.constant = -cachedWidth
            self.layoutIfNeeded()
        }, completion: { [weak self] _ in
            Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { _ in
                self?.step1()
            }
        })
    }
}
