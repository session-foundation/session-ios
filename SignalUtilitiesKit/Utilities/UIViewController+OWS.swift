// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit
import SessionUtilitiesKit

public extension UIViewController {
    func findFrontMostViewController(ignoringAlerts: Bool) -> UIViewController {
        var visitedViewControllers: [UIViewController] = []
        var viewController: UIViewController = self
        
        while true {
            visitedViewControllers.append(viewController)
            
            func shouldSkipController(_ controller: UIViewController) -> Bool {
                return ignoringAlerts && controller is UIAlertController
            }
            
            func tryAdvance(to next: UIViewController) -> Bool {
                guard !shouldSkipController(next) else { return false }
                guard !visitedViewControllers.contains(next) else { return false }  // Loop prevention
                
                viewController = next
                return true
            }
            
            // Check if current viewController is an alert we should ignore
            guard !shouldSkipController(viewController) else { break }
            
            // Handle TopBannerController
            if let topBanner: TopBannerController = viewController as? TopBannerController, !topBanner.children.isEmpty {
                let child: UIViewController = topBanner.children[0]
                let next: UIViewController = (child.presentedViewController ?? child)
                
                guard tryAdvance(to: next) else { break }
                continue
            }
            
            // Handle presented view controller
            if let presented: UIViewController = viewController.presentedViewController {
                guard tryAdvance(to: presented) else { break }
                continue
            }
            
            // Handle navigation controller
            if let navController = viewController as? UINavigationController,
               let topViewController = navController.topViewController {
                guard tryAdvance(to: topViewController) else { break }
                continue
            }
            
            // No more view controllers to traverse
            break
        }
        
        return viewController
    }
    
    static func createOWSBackButton(target: Any?, selector: Selector, using dependencies: Dependencies) -> UIBarButtonItem {
        let backButton: UIButton = UIButton(type: .custom)

        // Nudge closer to the left edge to match default back button item.
        let extraLeftPadding: CGFloat = (Dependencies.isRTL ? 0 : -8)

        // Give some extra hit area to the back button. This is a little smaller
        // than the default back button, but makes sense for our left aligned title
        // view in the MessagesViewController
        let extraRightPadding: CGFloat = (Dependencies.isRTL ? -0 : 10)

        // Extra hit area above/below
        let extraHeightPadding: CGFloat = 8

        // Matching the default backbutton placement is tricky.
        // We can't just adjust the imageEdgeInsets on a UIBarButtonItem directly,
        // so we adjust the imageEdgeInsets on a UIButton, then wrap that
        // in a UIBarButtonItem.
        backButton.addTarget(target, action: selector, for: .touchUpInside)
        
        let config: UIImage.Configuration = UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
        backButton.setImage(
            UIImage(systemName: "chevron.backward", withConfiguration: config)?
                .withRenderingMode(.alwaysTemplate),
            for: .normal
        )
        backButton.themeTintColor = .textPrimary
        backButton.contentHorizontalAlignment = .left
        backButton.imageEdgeInsets = UIEdgeInsets(top: 4, leading: extraLeftPadding, bottom: -4, trailing: 0)
        backButton.frame = CGRect(
            x: 0,
            y: 0,
            width: ((backButton.image(for: .normal)?.size.width ?? 0) + extraRightPadding),
            height: ((backButton.image(for: .normal)?.size.height ?? 0) + extraHeightPadding)
        )

        let backItem: UIBarButtonItem = UIBarButtonItem(customView: backButton)
        backButton.accessibilityIdentifier = "\(type(of: self)).back"
        backButton.accessibilityLabel = "\(type(of: self)).back"
        backItem.isAccessibilityElement = true
        backItem.width = backButton.frame.width

        return backItem;
    }
    
    // MARK: - Event Handling

    @objc func backButtonPressed() {
        self.navigationController?.popViewController(animated: true)
    }
}
