// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit

final class MediaLoaderView: UIView {
    private let bar = UIView()
    private var cachedWidth: CGFloat = 0
    
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
        step1()
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        
        if cachedWidth != bounds.width {
            cachedWidth = bounds.width
        }
    }
    
    // MARK: - Animation
    
    func step1() {
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
