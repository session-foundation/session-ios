// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit

class MediaZoomAnimationController: NSObject {
    private let dependencies: Dependencies
    private let attachment: Attachment
    private let shouldBounce: Bool

    init(attachment: Attachment, shouldBounce: Bool = true, using dependencies: Dependencies) {
        self.dependencies = dependencies
        self.attachment = attachment
        self.shouldBounce = shouldBounce
    }
}

extension MediaZoomAnimationController: UIViewControllerAnimatedTransitioning {
    func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval {
        return 0.3
    }

    func animateTransition(using transitionContext: UIViewControllerContextTransitioning) {
        let containerView = transitionContext.containerView
        let fromContextProvider: MediaPresentationContextProvider
        let toContextProvider: MediaPresentationContextProvider

        /// Can't recover if we don't have an origin or destination so don't bother trying
        guard
            let fromVC: UIViewController = transitionContext.viewController(forKey: .from),
            let toVC: UIViewController = transitionContext.viewController(forKey: .to)
        else { return transitionContext.completeTransition(false) }

        /// `view(forKey: .to)` will be nil when using this transition for a modal dismiss, in which case we want to use the
        /// `toVC.view` but need to ensure we add it back to it's original parent afterwards so we don't break the view hierarchy
        ///
        /// **Note:** We *MUST* call 'layoutIfNeeded' prior to `toContextProvider.mediaPresentationContext` as
        /// the `toContextProvider.mediaPresentationContext` is dependant on it having the correct positioning (and
        /// the navBar sizing isn't correct until after layout)
        let toView: UIView = (transitionContext.view(forKey: .to) ?? toVC.view)
        let duration: CGFloat = transitionDuration(using: transitionContext)
        let oldToViewSuperview: UIView? = toView.superview
        toView.layoutIfNeeded()
        
        switch fromVC {
            case let contextProvider as MediaPresentationContextProvider:
                fromContextProvider = contextProvider
                
            case let topBannerController as TopBannerController:
                guard
                    let firstChild: UIViewController = topBannerController.children.first,
                    let navController: UINavigationController = firstChild as? UINavigationController,
                    let contextProvider = navController.topViewController as? MediaPresentationContextProvider
                else { return fallbackTransition(toView: toView, context: transitionContext) }
                
                fromContextProvider = contextProvider

            case let navController as UINavigationController:
                guard
                    let contextProvider = navController.topViewController as? MediaPresentationContextProvider
                else { return fallbackTransition(toView: toView, context: transitionContext) }

                fromContextProvider = contextProvider

            default: return fallbackTransition(toView: toView, context: transitionContext)
        }

        switch toVC {
            case let contextProvider as MediaPresentationContextProvider:
                toContextProvider = contextProvider
                
            case let topBannerController as TopBannerController:
                guard
                    let firstChild: UIViewController = topBannerController.children.first,
                    let navController: UINavigationController = firstChild as? UINavigationController,
                    let contextProvider = navController.topViewController as? MediaPresentationContextProvider
                else { return fallbackTransition(toView: toView, context: transitionContext) }
                
                toContextProvider = contextProvider

            case let navController as UINavigationController:
                guard
                    let contextProvider = navController.topViewController as? MediaPresentationContextProvider
                else { return fallbackTransition(toView: toView, context: transitionContext) }

                toContextProvider = contextProvider

            default: return fallbackTransition(toView: toView, context: transitionContext)
        }
        
        // If we can't retrieve the contextual info we need to perform the proper zoom animation then
        // just fade the destination in (otherwise the user would get stuck on a blank screen)
        guard
            let fromMediaContext: MediaPresentationContext = fromContextProvider.mediaPresentationContext(mediaId: attachment.id, in: containerView),
            let toMediaContext: MediaPresentationContext = toContextProvider.mediaPresentationContext(mediaId: attachment.id, in: containerView),
            let presentationSource: ImageDataManager.DataSource = ImageDataManager.DataSource.from(
                attachment: attachment,
                using: dependencies
            )
        else { return fallbackTransition(toView: toView, context: transitionContext) }

        fromMediaContext.mediaView.alpha = 0
        toMediaContext.mediaView.alpha = 0

        toView.frame = containerView.bounds
        toView.alpha = 0
        containerView.addSubview(toView)
        
        let transitionView: SessionImageView = SessionImageView(
            dataManager: dependencies[singleton: .imageDataManager]
        )
        transitionView.loadImage(presentationSource)
        transitionView.frame = fromMediaContext.presentationFrame
        transitionView.contentMode = MediaView.contentMode
        transitionView.layer.masksToBounds = true
        transitionView.layer.cornerRadius = fromMediaContext.cornerRadius
        transitionView.layer.maskedCorners = fromMediaContext.cornerMask
        containerView.addSubview(transitionView)
        
        // Set the currently loaded image to prevent any odd delay and try to match the animation
        // state to the source
        transitionView.image = fromMediaContext.mediaView.image
        
        if fromMediaContext.mediaView.isAnimating {
            transitionView.startAnimationLoop()
            transitionView.setAnimationPoint(
                index: fromMediaContext.mediaView.currentFrameIndex,
                time: fromMediaContext.mediaView.accumulatedTime
            )
        }
        
        // Note: We need to do this after adding the 'transitionView' and insert it at the back
        // otherwise the screen can flicker since we have 'afterScreenUpdates: true' (if we use
        // 'afterScreenUpdates: false' then the 'fromMediaContext.mediaView' won't be hidden
        // during the transition)
        let fromSnapshotView: UIView = (fromVC.view.snapshotView(afterScreenUpdates: true) ?? UIView())
        containerView.insertSubview(fromSnapshotView, at: 0)

        // Add any UI elements which should appear above the media view
        let fromTransitionalOverlayView: UIView? = {
            guard let (overlayView, overlayViewFrame) = fromContextProvider.snapshotOverlayView(in: containerView) else {
                return nil
            }

            overlayView.frame = overlayViewFrame
            containerView.addSubview(overlayView)

            return overlayView
        }()
        let toTransitionalOverlayView: UIView? = {
            guard let (overlayView, overlayViewFrame) = toContextProvider.snapshotOverlayView(in: containerView) else {
                return nil
            }

            overlayView.alpha = 0
            overlayView.frame = overlayViewFrame
            containerView.addSubview(overlayView)

            return overlayView
        }()
        
        UIView.animate(
            withDuration: duration,
            delay: 0,
            options: .curveEaseInOut,
            animations: {
                // Only fade out the 'fromTransitionalOverlayView' if it's bigger than the destination
                // one (makes it look cleaner as you don't get the crossfade effect)
                if (fromTransitionalOverlayView?.frame.size.height ?? 0) > (toTransitionalOverlayView?.frame.size.height ?? 0) {
                    fromTransitionalOverlayView?.alpha = 0
                }

                toView.alpha = 1
                toTransitionalOverlayView?.alpha = 1
                transitionView.frame = toMediaContext.presentationFrame
                transitionView.layer.cornerRadius = toMediaContext.cornerRadius
            },
            completion: { _ in
                transitionView.removeFromSuperview()
                fromSnapshotView.removeFromSuperview()
                fromTransitionalOverlayView?.removeFromSuperview()
                toTransitionalOverlayView?.removeFromSuperview()

                toMediaContext.mediaView.alpha = 1
                fromMediaContext.mediaView.alpha = 1

                // Need to ensure we add the 'toView' back to it's old superview if it had one
                oldToViewSuperview?.addSubview(toView)

                transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
            }
        )
    }
    
    private func fallbackTransition(toView: UIView, context: UIViewControllerContextTransitioning) {
        let duration: CGFloat = transitionDuration(using: context)
        let containerView = context.containerView
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
