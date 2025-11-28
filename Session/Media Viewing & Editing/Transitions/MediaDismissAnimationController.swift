// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit

class MediaDismissAnimationController: MediaAnimationController {
    public let interactionController: MediaInteractiveDismiss?

    var fromView: UIView?
    var fromMediaFrame: CGRect?
    var pendingCompletion: (() -> ())?

    init(attachment: Attachment, interactionController: MediaInteractiveDismiss? = nil, using dependencies: Dependencies) {
        self.interactionController = interactionController
        
        super.init(attachment: attachment, using: dependencies)
    }
}

extension MediaDismissAnimationController: UIViewControllerAnimatedTransitioning {
    func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval {
        return 0.3
    }

    func animateTransition(using transitionContext: UIViewControllerContextTransitioning) {
        let containerView = transitionContext.containerView

        guard
            let fromVC: UIViewController = transitionContext.viewController(forKey: .from),
            let toVC: UIViewController = transitionContext.viewController(forKey: .to),
            let fromContextProvider: MediaPresentationContextProvider = extractContextProvider(from: fromVC),
            let toContextProvider: MediaPresentationContextProvider = extractContextProvider(from: toVC)
        else { return fallbackTransition(context: transitionContext) }

        toVC.view.layoutIfNeeded()

        guard
            let fromMediaContext: MediaPresentationContext = fromContextProvider.mediaPresentationContext(
                mediaId: attachment.id,
                in: containerView
            )
        else { return fallbackTransition(context: transitionContext) }
        
        // fromView will be nil if doing a presentation, in which case we don't want to add the view -
        // it will automatically be added to the view hierarchy, in front of the VC we're presenting from
        if let fromView: UIView = transitionContext.view(forKey: .from) {
            self.fromView = fromView
            containerView.addSubview(fromView)
            
            let navBarView: UIView? = fromView.subviews.first(where: { $0 is UINavigationBar })
            createAndAddMask(
                to: fromView,
                holeFrame: fromMediaContext.presentationFrame,
                cornerRadius: fromMediaContext.cornerRadius,
                in: containerView,
                viewport: CGRect(
                    x: 0,
                    y: (navBarView?.frame.maxY ?? 0),
                    width: fromView.bounds.width,
                    height: (fromView.bounds.height - (navBarView?.frame.maxY ?? 0))
                )
            )
        }

        // toView will be nil if doing a modal dismiss, in which case we don't want to add the view -
        // it's already in the view hierarchy, behind the VC we're dismissing.
        if let toView: UIView = transitionContext.view(forKey: .to) {
            containerView.insertSubview(toView, at: 0)
        }

        let toMediaContext: MediaPresentationContext? = toContextProvider.mediaPresentationContext(mediaId: attachment.id, in: containerView)
        let duration: CGFloat = transitionDuration(using: transitionContext)

        fromMediaContext.mediaView.alpha = 0
        toMediaContext?.mediaView.alpha = 0

        let transitionView: SessionImageView = SessionImageView(
            dataManager: dependencies[singleton: .imageDataManager]
        )
        transitionView.copyContentAndAnimationPoint(from: fromMediaContext.mediaView)
        transitionView.frame = fromMediaContext.presentationFrame
        transitionView.contentMode = MediaView.contentMode
        transitionView.layer.masksToBounds = true
        transitionView.layer.cornerRadius = fromMediaContext.cornerRadius
        transitionView.layer.maskedCorners = (toMediaContext?.cornerMask ?? fromMediaContext.cornerMask)
        insertTransitionView(
            transitionView,
            intoView: toVC.view,
            contextProvider: toContextProvider,
            startFrame: fromMediaContext.presentationFrame,
            containerView: containerView
        )
        
        self.fromMediaFrame = transitionView.frame
        
        // Start display link to update mask during animation
        startDisplayLink()

        self.pendingCompletion = {
            let destinationFromAlpha: CGFloat
            let destinationFrame: CGRect
            let destinationFrameInContainer: CGRect
            let destinationCornerRadius: CGFloat

            if transitionContext.transitionWasCancelled {
                destinationFromAlpha = 1
                destinationFrameInContainer = fromMediaContext.presentationFrame
                destinationCornerRadius = fromMediaContext.cornerRadius
                
                if let transitionSuperview: UIView = transitionView.superview {
                    destinationFrame = transitionSuperview.convert(destinationFrameInContainer, from: containerView)
                } else {
                    destinationFrame = destinationFrameInContainer
                }
            }
            else if let toMediaContext: MediaPresentationContext = toMediaContext {
                destinationFromAlpha = 0
                destinationFrameInContainer = toMediaContext.presentationFrame
                destinationCornerRadius = toMediaContext.cornerRadius
                
                if let transitionSuperview: UIView = transitionView.superview {
                    destinationFrame = transitionSuperview.convert(toMediaContext.presentationFrame, from: containerView)
                } else {
                    destinationFrame = destinationFrameInContainer
                }
            }
            else {
                // `toMediaContext` can be nil if the target item is scrolled off of the
                // contextProvider's screen, so we synthesize a context to dismiss the item
                // off screen
                destinationFromAlpha = 0
                destinationFrameInContainer = fromMediaContext.presentationFrame.offsetBy(dx: 0, dy: containerView.bounds.height * 2)
                destinationFrame = transitionView.frame.offsetBy(dx: 0, dy: (containerView.bounds.height * 2))
                destinationCornerRadius = fromMediaContext.cornerRadius
            }

            UIView.animate(
                withDuration: duration,
                delay: 0,
                options: [.beginFromCurrentState, .curveEaseInOut],
                animations: { [weak self] in
                    self?.fromView?.alpha = destinationFromAlpha
                    transitionView.frame = destinationFrame
                    transitionView.layer.cornerRadius = destinationCornerRadius
                },
                completion: { [weak self] _ in
                    self?.stopDisplayLink()
                    self?.removeMask()
                    
                    self?.fromView?.alpha = 1
                    fromMediaContext.mediaView.alpha = 1
                    toMediaContext?.mediaView.alpha = 1
                    transitionView.removeFromSuperview()

                    if transitionContext.transitionWasCancelled {
                        // The "to" view will be nil if we're doing a modal dismiss, in which case
                        // we wouldn't want to remove the toView.
                        transitionContext.view(forKey: .to)?.removeFromSuperview()
                        
                        // Note: We shouldn't need to do this but for some reason it's not
                        // automatically getting re-enabled so we manually enable it
                        transitionContext.view(forKey: .from)?.isUserInteractionEnabled = true
                    }
                    else {
                        transitionContext.view(forKey: .from)?.removeFromSuperview()
                        
                        // Note: We shouldn't need to do this but for some reason it's not
                        // automatically getting re-enabled so we manually enable it
                        transitionContext.view(forKey: .to)?.isUserInteractionEnabled = true
                    }

                    transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
                    
                    self?.cleanUp()
                }
            )
        }

        // The interactive transition will call the 'pendingCompletion' when it completes so don't call it here
        guard !transitionContext.isInteractive else { return }

        self.pendingCompletion?()
        self.pendingCompletion = nil
    }
    
    private func fallbackTransition(context: UIViewControllerContextTransitioning) {
        cleanUp()
        
        let containerView: UIView = context.containerView
        
        /// iOS won't automatically handle failure cases so if we can't get the "from" context then we want to just complete
        /// the change instantly so the user doesn't permanently get stuck on the screen
        if context.transitionWasCancelled {
            context.view(forKey: .from)?.isUserInteractionEnabled = true
        }
        else {
            if let toView: UIView = context.view(forKey: .to) {
                containerView.insertSubview(toView, at: 0)
            }
            
            context.view(forKey: .from)?.removeFromSuperview()
            
            // Note: We shouldn't need to do this but for some reason it's not
            // automatically getting re-enabled so we manually enable it
            context.view(forKey: .to)?.isUserInteractionEnabled = true
        }

        context.completeTransition(!context.transitionWasCancelled)
    }
}

extension MediaDismissAnimationController: InteractiveDismissDelegate {
    func interactiveDismissUpdate(_ interactiveDismiss: UIPercentDrivenInteractiveTransition, didChangeTouchOffset offset: CGPoint) {
        guard let transitionView: UIView = transitionView else { return } // Transition hasn't started yet
        guard let fromMediaFrame: CGRect = fromMediaFrame else { return }

        fromView?.alpha = (1.0 - interactiveDismiss.percentComplete)
        transitionView.center = fromMediaFrame.offsetBy(dx: offset.x, dy: offset.y).center
    }

    func interactiveDismissDidFinish(_ interactiveDismiss: UIPercentDrivenInteractiveTransition) {
        self.pendingCompletion?()
        self.pendingCompletion = nil
    }
}
