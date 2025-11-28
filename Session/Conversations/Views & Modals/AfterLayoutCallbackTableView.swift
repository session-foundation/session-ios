// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit

public class AfterLayoutCallbackTableView: UITableView {
    private var callbackCondition: ((Int, [Int], CGSize) -> Bool)?
    private var afterLayoutSubviewsCallback: (() -> ())?
    private var lastAdjustedInset: UIEdgeInsets = .zero
    
    public override func layoutSubviews() {
        // Store the callback locally to prevent infinite loops
        var callback: (() -> ())?
        
        if self.checkCallbackCondition() {
            callback = self.afterLayoutSubviewsCallback
            self.afterLayoutSubviewsCallback = nil
        }
        
        super.layoutSubviews()
        callback?()
    }
    
    public override func adjustedContentInsetDidChange() {
        super.adjustedContentInsetDidChange()
        
        let insetDifference: CGFloat = adjustedContentInset.bottom - lastAdjustedInset.bottom
        
        if insetDifference > 0 {
            contentOffset.y += insetDifference
        }
        
        lastAdjustedInset = adjustedContentInset
    }
    
    // MARK: - Functions
    
    public func afterNextLayoutSubviews(
        when condition: @escaping (Int, [Int], CGSize) -> Bool,
        then callback: @escaping () -> ()
    ) {
        self.callbackCondition = condition
        self.afterLayoutSubviewsCallback = callback
    }
    
    private func checkCallbackCondition() -> Bool {
        guard self.callbackCondition != nil else { return false }
        
        let numSections: Int = self.numberOfSections
        let numRowInSections: [Int] = (0..<numSections)
            .map { self.numberOfRows(inSection: $0) }
        
        // Store the layout info locally so if they pass we can clear the states before running to
        // prevent layouts within the callbacks from triggering infinite loops
        guard self.callbackCondition?(numSections, numRowInSections, self.contentSize) == true else {
            return false
        }
        
        self.callbackCondition = nil
        return true
    }
}
