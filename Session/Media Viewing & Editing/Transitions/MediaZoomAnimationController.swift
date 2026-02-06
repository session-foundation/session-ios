// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit

class MediaZoomAnimationController: MediaAnimationController {
    private let shouldBounce: Bool

    init(attachment: Attachment, shouldBounce: Bool = true, using dependencies: Dependencies) {
        self.shouldBounce = shouldBounce
        
        super.init(attachment: attachment, using: dependencies)
    }
}

extension MediaZoomAnimationController: UIViewControllerAnimatedTransitioning {
    func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval {
        return 0.3
    }
    
    func animateTransition(using transitionContext: UIViewControllerContextTransitioning) {
        let containerView = transitionContext.containerView
        
        /// Can't recover if we don't have an origin or destination so don't bother trying
        guard
            let fromVC: UIViewController = transitionContext.viewController(forKey: .from),
            let toVC: UIViewController = transitionContext.viewController(forKey: .to),
            let fromContextProvider: MediaPresentationContextProvider = extractContextProvider(from: fromVC),
            let toContextProvider: MediaPresentationContextProvider = extractContextProvider(from: toVC)
        else { return fallbackTransition(context: transitionContext) }
        
        /// `view(forKey: .to)` will be nil when using this transition for a modal dismiss, in which case we want to use the
        /// `toVC.view` but need to ensure we add it back to it's original parent afterwards so we don't break the view hierarchy
        ///
        /// **Note:** We *MUST* call 'layoutIfNeeded' prior to `toContextProvider.mediaPresentationContext` as
        /// the `toContextProvider.mediaPresentationContext` is dependant on it having the correct positioning (and
        /// the navBar sizing isn't correct until after layout)
        let toView: UIView = (transitionContext.view(forKey: .to) ?? toVC.view)
        let fromView: UIView = (transitionContext.view(forKey: .from) ?? fromVC.view)
        let duration: CGFloat = transitionDuration(using: transitionContext)
        let oldToViewSuperview: UIView? = toView.superview
        toView.layoutIfNeeded()
        
        // If we can't retrieve the contextual info we need to perform the proper zoom animation then
        // just fade the destination in (otherwise the user would get stuck on a blank screen)
        guard
            let fromMediaContext: MediaPresentationContext = fromContextProvider.mediaPresentationContext(mediaId: attachment.id, in: containerView),
            let toMediaContext: MediaPresentationContext = toContextProvider.mediaPresentationContext(mediaId: attachment.id, in: containerView)
        else { return fallbackTransition(context: transitionContext) }
        
        toView.frame = containerView.bounds
        toView.alpha = 0
        containerView.addSubview(toView)
        
        let transitionView: SessionImageView = SessionImageView(
            dataManager: dependencies[singleton: .imageDataManager]
        )
        transitionView.copyContentAndAnimationPoint(from: fromMediaContext.mediaView)
        transitionView.frame = fromMediaContext.presentationFrame
        transitionView.contentMode = MediaView.contentMode
        transitionView.layer.masksToBounds = true
        transitionView.layer.cornerRadius = fromMediaContext.cornerRadius
        transitionView.layer.maskedCorners = fromMediaContext.cornerMask
        
        insertTransitionView(
            transitionView,
            intoView: fromView,
            contextProvider: fromContextProvider,
            startFrame: fromMediaContext.presentationFrame,
            containerView: containerView
        )
        
        fromMediaContext.mediaView.alpha = 0
        toMediaContext.mediaView.alpha = 0
        
        // Add a mask  so we can transition nicely between the views and slide the content between
        // any header/footer views
        let viewport: CGRect = {
            let navBarView: UIView? = fromView.subviews.first(where: { $0 is UINavigationBar })
            var topY: CGFloat = (navBarView?.frame.maxY ?? 0)
            var bottomY: CGFloat = fromView.bounds.height
            
            guard
                let lowestAboveView: UIView = fromContextProvider.lowestViewToRenderAboveContent(),
                let lowestAboveIndex: Array<UIView>.Index = fromView.subviews.firstIndex(of: lowestAboveView)
            else {
                return CGRect(x: 0, y: topY, width: fromView.bounds.width, height: bottomY)
            }
            
            for aboveView in fromView.subviews.suffix(from: lowestAboveIndex) {
                if aboveView.frame.minY < topY && aboveView.frame.maxY > topY {
                    topY = aboveView.frame.maxY
                }
                else if aboveView.frame.minY > bottomY {
                    bottomY = min(bottomY, aboveView.frame.minY)
                }
            }
            
            return CGRect(
                x: 0,
                y: topY,
                width: containerView.bounds.width,
                height: bottomY - topY
            )
        }()
        createAndAddMask(
            to: toView,
            holeFrame: fromMediaContext.presentationFrame,
            cornerRadius: fromMediaContext.cornerRadius,
            in: containerView,
            viewport: viewport
        )
        
        // Start display link to update mask during animation
        startDisplayLink()
        
        let destinationFrame: CGRect
        if let transitionSuperview: UIView = transitionView.superview {
            destinationFrame = transitionSuperview.convert(toMediaContext.presentationFrame, from: containerView)
        } else {
            destinationFrame = toMediaContext.presentationFrame
        }
        
        UIView.animate(
            withDuration: duration,
            delay: 0,
            options: .curveEaseInOut,
            animations: {
                toView.alpha = 1
                transitionView.frame = destinationFrame
                transitionView.layer.cornerRadius = toMediaContext.cornerRadius
            },
            completion: { [weak self] _ in
                self?.stopDisplayLink()
                self?.removeMask()
                
                transitionView.removeFromSuperview()
                
                toMediaContext.mediaView.alpha = 1
                fromMediaContext.mediaView.alpha = 1
                
                // Need to ensure we add the 'toView' back to it's old superview if it had one
                oldToViewSuperview?.addSubview(toView)
                
                transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
                
                self?.cleanUp()
            }
        )
    }
    
    private func fallbackTransition(context: UIViewControllerContextTransitioning) {
        cleanUp()
        
        let duration: CGFloat = transitionDuration(using: context)
        let containerView = context.containerView
        let toView: UIView = (context.view(forKey: .to) ?? context.viewController(forKey: .to)?.view ?? UIView())
        let oldToViewSuperview: UIView? = toView.superview
        toView.frame = containerView.bounds
        toView.alpha = 0
        containerView.addSubview(toView)
        
        UIView.animate(
            withDuration: duration,
            delay: 0,
            options: .curveEaseInOut,
            animations: {
                toView.alpha = 1
            },
            completion: { _ in
                // Need to ensure we add the 'toView' back to it's old superview if it had one
                oldToViewSuperview?.addSubview(toView)
                
                context.completeTransition(!context.transitionWasCancelled)
            }
        )
    }
}
