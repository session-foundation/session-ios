import UIKit

extension UIEdgeInsets {
    public init(uniform value: CGFloat) {
        self.init(top: value, left: value, bottom: value, right: value)
    }
    
    @MainActor public init(top: CGFloat, leading: CGFloat, bottom: CGFloat, trailing: CGFloat) {
        self.init(
            top: top,
            left: (SNUIKit.isRTL ? trailing : leading),
            bottom: bottom,
            right: (SNUIKit.isRTL ? leading : trailing)
        )
    }
}
