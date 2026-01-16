// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit

struct MediaPresentationContext {
    let mediaView: SessionImageView
    let presentationFrame: CGRect
    let cornerRadius: CGFloat
    let cornerMask: CACornerMask
}

// There are two kinds of AnimationControllers that interact with the media detail view. Both
// appear to transition the media view from one VC to it's corresponding location in the
// destination VC.
//
// MediaPresentationContextProvider is either a target or destination VC which can provide the
// details necessary to facilite this animation.
//
// First, the MediaZoomAnimationController is non-interactive. We use it whenever we're going to
// show the Media detail pager.
//
//  We can get there several ways:
//    From conversation settings, this can be a push or a pop from the tileView.
//    From conversationView/MessageDetails this can be a modal present or a pop from the tile view.
//
// The other animation controller, the MediaDismissAnimationController is used when we're going to
// stop showing the media pager. This can be a pop to the tile view, or a modal dismiss.
protocol MediaPresentationContextProvider {
    func mediaPresentationContext(mediaId: String, in coordinateSpace: UICoordinateSpace) -> MediaPresentationContext?
    func lowestViewToRenderAboveContent() -> UIView?
}

private struct ClippedHole {
    let frame: CGRect
    let clippedCornerRadius: CGFloat
    let maskedCorners: CACornerMask
    
    init(holeFrame: CGRect, cornerRadius: CGFloat, viewport: CGRect?) {
        guard let viewport: CGRect = viewport else {
            self.frame = holeFrame
            self.clippedCornerRadius = cornerRadius
            self.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
            return
        }
            
        self.frame = holeFrame.intersection(viewport)
        var corners: CACornerMask = []
        
        // Top-left corner
        if holeFrame.minX >= viewport.minX && holeFrame.minY >= viewport.minY {
            corners.insert(.layerMinXMinYCorner)
        }
        
        // Top-right corner
        if holeFrame.maxX <= viewport.maxX && holeFrame.minY >= viewport.minY {
            corners.insert(.layerMaxXMinYCorner)
        }
        
        // Bottom-left corner
        if holeFrame.minX >= viewport.minX && holeFrame.maxY <= viewport.maxY {
            corners.insert(.layerMinXMaxYCorner)
        }
        
        // Bottom-right corner
        if holeFrame.maxX <= viewport.maxX && holeFrame.maxY <= viewport.maxY {
            corners.insert(.layerMaxXMaxYCorner)
        }
        
        self.clippedCornerRadius = (corners.isEmpty ? 0 : cornerRadius)
        self.maskedCorners = corners
    }
    
    func createPath() -> UIBezierPath {
        if maskedCorners.isEmpty || clippedCornerRadius == 0 {
            return UIBezierPath(rect: frame)
        }
        
        let path: UIBezierPath = UIBezierPath()
        let topLeft: CGPoint = frame.origin
        let topRight: CGPoint = CGPoint(x: frame.maxX, y: frame.minY)
        let bottomRight: CGPoint = CGPoint(x: frame.maxX, y: frame.maxY)
        let bottomLeft: CGPoint = CGPoint(x: frame.minX, y: frame.maxY)
        
        // Start from top-left
        if maskedCorners.contains(.layerMinXMinYCorner) {
            path.move(to: CGPoint(x: topLeft.x + clippedCornerRadius, y: topLeft.y))
            path.addArc(
                withCenter: CGPoint(x: topLeft.x + clippedCornerRadius, y: topLeft.y + clippedCornerRadius),
                radius: clippedCornerRadius,
                startAngle: .pi * 1.5,
                endAngle: .pi,
                clockwise: false
            )
        } else {
            path.move(to: topLeft)
        }
        
        // Left edge to bottom-left
        if maskedCorners.contains(.layerMinXMaxYCorner) {
            path.addLine(to: CGPoint(x: bottomLeft.x, y: bottomLeft.y - clippedCornerRadius))
            path.addArc(
                withCenter: CGPoint(x: bottomLeft.x + clippedCornerRadius, y: bottomLeft.y - clippedCornerRadius),
                radius: clippedCornerRadius,
                startAngle: .pi,
                endAngle: .pi * 0.5,
                clockwise: false
            )
        } else {
            path.addLine(to: bottomLeft)
        }
        
        // Bottom edge to bottom-right
        if maskedCorners.contains(.layerMaxXMaxYCorner) {
            path.addLine(to: CGPoint(x: bottomRight.x - clippedCornerRadius, y: bottomRight.y))
            path.addArc(
                withCenter: CGPoint(x: bottomRight.x - clippedCornerRadius, y: bottomRight.y - clippedCornerRadius),
                radius: clippedCornerRadius,
                startAngle: .pi * 0.5,
                endAngle: 0,
                clockwise: false
            )
        } else {
            path.addLine(to: bottomRight)
        }
        
        // Right edge to top-right
        if maskedCorners.contains(.layerMaxXMinYCorner) {
            path.addLine(to: CGPoint(x: topRight.x, y: topRight.y + clippedCornerRadius))
            path.addArc(
                withCenter: CGPoint(x: topRight.x - clippedCornerRadius, y: topRight.y + clippedCornerRadius),
                radius: clippedCornerRadius,
                startAngle: 0,
                endAngle: .pi * 1.5,
                clockwise: false
            )
        } else {
            path.addLine(to: topRight)
        }
        
        path.close()
        return path
    }
}

class MediaAnimationController: NSObject {
    let dependencies: Dependencies
    let attachment: Attachment
    
    private var displayLink: CADisplayLink?
    private var maskLayer: CAShapeLayer?
    private weak var maskedView: UIView?
    private var maskViewport: CGRect?
    private(set) weak var transitionView: UIView?
    
    private var fromBelowContainer: UIView?
    private var toBelowContainer: UIView?
    private var fromAboveViews: [UIView] = []
    private var toAboveViews: [UIView] = []
    
    init(attachment: Attachment, using dependencies: Dependencies) {
        self.dependencies = dependencies
        self.attachment = attachment
        
        super.init()
    }
    
    func extractContextProvider(from viewController: UIViewController) -> MediaPresentationContextProvider? {
        switch viewController {
            case let contextProvider as MediaPresentationContextProvider:
                return contextProvider
                
            case let topBannerController as TopBannerController:
                guard
                    let firstChild: UIViewController = topBannerController.children.first,
                    let navController: UINavigationController = firstChild as? UINavigationController,
                    let contextProvider = navController.topViewController as? MediaPresentationContextProvider
                else { return nil }
                
                return contextProvider

            case let navController as UINavigationController:
                guard
                    let contextProvider = navController.topViewController as? MediaPresentationContextProvider
                else { return nil }

                return contextProvider

            default: return nil
        }
    }
    
    func extractNavigationController(from viewController: UIViewController) -> UINavigationController? {
        switch viewController {
            case let topBannerController as TopBannerController:
                guard
                    let firstChild: UIViewController = topBannerController.children.first,
                    let navController: UINavigationController = firstChild as? UINavigationController
                else { return nil }
                
                return navController

            case let navController as UINavigationController: return navController
            default: return nil
        }
    }
    
    func createAndAddMask(
        to view: UIView,
        holeFrame: CGRect,
        cornerRadius: CGFloat,
        in containerView: UIView,
        viewport: CGRect? = nil
    ) {
        let maskLayer: CAShapeLayer = CAShapeLayer()
        let holeFrameInView: CGRect = view.convert(holeFrame, from: containerView)
        let viewportInView: CGRect? = viewport.map { view.convert($0, from: containerView) }
        let clippedHole: ClippedHole = ClippedHole(
            holeFrame: holeFrameInView,
            cornerRadius: cornerRadius,
            viewport: viewportInView
        )
        
        let path: UIBezierPath = UIBezierPath(rect: view.bounds)
        let hole: UIBezierPath = clippedHole.createPath()
        path.append(hole)
        path.usesEvenOddFillRule = true
        maskLayer.path = path.cgPath
        maskLayer.fillRule = .evenOdd
        view.layer.mask = maskLayer
        
        self.maskLayer = maskLayer
        self.maskedView = view
        self.maskViewport = viewport
    }
    
    func insertTransitionView(
        _ transitionView: UIView,
        intoView view: UIView,
        contextProvider: MediaPresentationContextProvider,
        startFrame: CGRect,
        containerView: UIView
    ) {
        self.transitionView = transitionView
        
        if
            let targetView: UIView = contextProvider.lowestViewToRenderAboveContent(),
            let targetSuperview: UIView = targetView.superview
        {
            let frameInSuperview: CGRect = targetSuperview.convert(startFrame, from: containerView)
            transitionView.frame = frameInSuperview
            targetSuperview.insertSubview(transitionView, belowSubview: targetView)
        }
        else if let navBar: UIView = view.subviews.first(where: { $0 is UINavigationBar }) {
            let frameInTargetView: CGRect = view.convert(startFrame, from: containerView)
            transitionView.frame = frameInTargetView
            view.insertSubview(transitionView, belowSubview: navBar)
        } else {
            transitionView.frame = startFrame
            containerView.insertSubview(transitionView, at: 0)
        }
    }
    
    func startDisplayLink() {
        let displayLink: CADisplayLink = CADisplayLink(target: self, selector: #selector(updateMask))
        displayLink.add(to: .main, forMode: .common)
        self.displayLink = displayLink
    }
    
    func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }
    
    func removeMask() {
        maskedView?.layer.mask = nil
        maskLayer = nil
        maskedView = nil
    }
    
    func cleanUp() {
        stopDisplayLink()
        maskLayer = nil
        maskedView = nil
        transitionView = nil
    }
    
    @objc private func updateMask() {
        guard
            let maskLayer: CAShapeLayer = self.maskLayer,
            let maskedView: UIView = self.maskedView,
            let transitionView: UIView = self.transitionView,
            let containerView: UIWindow = transitionView.window
        else { return }
        
        let currentFrameInSuperview: CGRect = (transitionView.layer.presentation()?.frame ?? transitionView.frame)
        let currentCornerRadius: CGFloat = (transitionView.layer.presentation()?.cornerRadius ?? transitionView.layer.cornerRadius)
        let currentFrameInContainer: CGRect = (transitionView.superview?.convert(currentFrameInSuperview, to: containerView) ?? currentFrameInSuperview)
        let holeFrameInView: CGRect = maskedView.convert(currentFrameInContainer, from: containerView)
        let viewportInView: CGRect? = self.maskViewport.map { maskedView.convert($0, from: containerView) }
        let clippedHole: ClippedHole = ClippedHole(
            holeFrame: holeFrameInView,
            cornerRadius: currentCornerRadius,
            viewport: viewportInView
        )
        
        // Update the mask path
        let path: UIBezierPath = UIBezierPath(rect: maskedView.bounds)
        let hole: UIBezierPath = clippedHole.createPath()
        path.append(hole)
        path.usesEvenOddFillRule = true
        
        maskLayer.path = path.cgPath
    }
}
