//  Copyright (c) 2019 Open Whisper Systems. All rights reserved.

import UIKit
import SessionUIKit
import SessionUtilitiesKit

public protocol ImageEditorCropViewControllerDelegate: AnyObject {
    func cropDidComplete(transform: ImageEditorTransform)
    func cropDidCancel()
}

// MARK: -

// A view for editing text item in image editor.
class ImageEditorCropViewController: OWSViewController {
    private weak var delegate: ImageEditorCropViewControllerDelegate?

    private let model: ImageEditorModel

    private let srcImage: UIImage

    private let previewImage: UIImage

    private var transform: ImageEditorTransform

    public let clipView = OWSLayerView()

    public let croppedContentView = OWSLayerView()
    public let uncroppedContentView = UIView()

    private var croppedImageLayer = CALayer()
    private var uncroppedImageLayer = CALayer()

    private enum CropRegion {
        // The sides of the crop region.
        case left, right, top, bottom
        // The corners of the crop region.
        case topLeft, topRight, bottomLeft, bottomRight
    }

    private class CropCornerView: OWSLayerView {
        let cropRegion: CropRegion

        init(cropRegion: CropRegion) {
            self.cropRegion = cropRegion
            super.init()
        }

        @available(*, unavailable, message: "use other init() instead.")
        required public init?(coder aDecoder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
    }

    private let cropView = UIView()
    private let cropCornerViews: [CropCornerView] = [
        CropCornerView(cropRegion: .topLeft),
        CropCornerView(cropRegion: .topRight),
        CropCornerView(cropRegion: .bottomLeft),
        CropCornerView(cropRegion: .bottomRight)
    ]

    init(delegate: ImageEditorCropViewControllerDelegate,
         model: ImageEditorModel,
         srcImage: UIImage,
         previewImage: UIImage) {
        self.delegate = delegate
        self.model = model
        self.srcImage = srcImage
        self.previewImage = previewImage
        transform = model.currentTransform()

        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable, message: "use other init() instead.")
    required public init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - View Lifecycle

    private var isCropLocked = false
    private var cropLockButton: OWSButton?

    override func loadView() {
        self.view = UIView()

        self.view.themeBackgroundColor = .newConversation_background
        self.view.layoutMargins = .zero

        // MARK: - Buttons

        let rotate90Button = OWSButton(
            imageName: "image_editor_rotate",
            tintColor: .textPrimary
        ) { [weak self] in
            self?.rotate90ButtonPressed()
        }
        let flipButton = OWSButton(
            imageName: "image_editor_flip",
            tintColor: .textPrimary
        ) { [weak self] in
            self?.flipButtonPressed()
        }
        let cropLockButton = OWSButton(
            imageName: "image_editor_crop_unlock",
            tintColor: .textPrimary
        ) { [weak self] in
            self?.cropLockButtonPressed()
        }
        self.cropLockButton = cropLockButton

        // MARK: - Canvas & Wrapper

        let wrapperView = UIView()
        wrapperView.layoutMargins = .zero
        wrapperView.themeBackgroundColor = .clear
        wrapperView.isOpaque = false

        // TODO: We could mask the clipped region with a semi-transparent overlay like WA.
        clipView.clipsToBounds = true
        clipView.themeBackgroundColor = .clear
        clipView.isOpaque = false
        clipView.layoutCallback = { [weak self] (_) in
            guard let strongSelf = self else {
                return
            }
            strongSelf.updateCropViewLayout()
        }
        wrapperView.addSubview(clipView)

        croppedImageLayer.contents = previewImage.cgImage
        croppedImageLayer.contentsScale = previewImage.scale
        croppedContentView.themeBackgroundColor = .clear
        croppedContentView.isOpaque = false
        croppedContentView.layer.addSublayer(croppedImageLayer)
        croppedContentView.layoutCallback = { [weak self] (_) in
            guard let strongSelf = self else {
                return
            }
            strongSelf.updateContent()
        }
        clipView.addSubview(croppedContentView)
        croppedContentView.pin(to: clipView)

        uncroppedImageLayer.contents = previewImage.cgImage
        uncroppedImageLayer.contentsScale = previewImage.scale
        // The "uncropped" view/layer are used to display the
        // content that has been cropped out.  Its content
        // should be semi-transparent to distinguish it from
        // the content within the crop bounds.
        uncroppedImageLayer.opacity = 0.5
        uncroppedContentView.themeBackgroundColor = .clear
        uncroppedContentView.isOpaque = false
        uncroppedContentView.layer.addSublayer(uncroppedImageLayer)
        wrapperView.addSubview(uncroppedContentView)
        uncroppedContentView.pin(to: croppedContentView)

        // MARK: - Footer

        let footer = UIStackView(
            arrangedSubviews: [
                rotate90Button,
                flipButton,
                UIView.hStretchingSpacer(),
                cropLockButton
            ]
        )
        footer.axis = .horizontal
        footer.spacing = 16
        footer.themeBackgroundColor = .clear
        footer.isOpaque = false

        let imageMargin: CGFloat = 20
        let stackView = UIStackView(arrangedSubviews: [
            wrapperView,
            footer
            ])
        stackView.axis = .vertical
        stackView.alignment = .fill
        stackView.spacing = imageMargin
        stackView.layoutMargins = UIEdgeInsets(top: 8, left: imageMargin, bottom: 8, right: imageMargin)
        stackView.isLayoutMarginsRelativeArrangement = true
        self.view.addSubview(stackView)
        stackView.pin(to: self.view)

        // MARK: - Crop View

        // Add crop view last so that it appears in front of the content.

        cropView.setContentHugging(to: .defaultLow)
        cropView.setCompressionResistance(to: .defaultLow)
        view.addSubview(cropView)
        for cropCornerView in cropCornerViews {
            cropView.addSubview(cropCornerView)

            switch cropCornerView.cropRegion {
            case .topLeft, .bottomLeft:
                cropCornerView.pin(.left, to: .left, of: cropView)
            case .topRight, .bottomRight:
                cropCornerView.pin(.right, to: .right, of: cropView)
            default:
                Log.error("[ImageEditorCropViewController] Invalid crop region: \(String(describing: cropRegion))")
            }
            switch cropCornerView.cropRegion {
            case .topLeft, .topRight:
                cropCornerView.pin(.top, to: .top, of: cropView)
            case .bottomLeft, .bottomRight:
                cropCornerView.pin(.bottom, to: .bottom, of: cropView)
            default:
                Log.error("[ImageEditorCropViewController] Invalid crop region: \(String(describing: cropRegion))")
            }
        }

        setCropViewAppearance()

        updateClipViewLayout()

        configureGestures()

        updateNavigationBar()
    }

    public func updateNavigationBar() {
        let resetButton = navigationBarButton(imageName: "image_editor_undo",
                                             selector: #selector(didTapReset(sender:)))
        let doneButton = navigationBarButton(imageName: "image_editor_checkmark_full",
                                             selector: #selector(didTapDone(sender:)))
        var navigationBarItems = [UIView]()
        if transform.isNonDefault {
            navigationBarItems = [resetButton, doneButton]
        } else {
            navigationBarItems = [doneButton]
        }
        updateNavigationBar(navigationBarItems: navigationBarItems)
    }

    private func updateCropLockButton() {
        switch (cropLockButton, isCropLocked) {
            case (.none, _): Log.error("[ImageEditorCropViewController] Missing cropLockButton")
            case (.some(let button), true): button.setImage(imageName: "image_editor_crop_lock")
            case (.some(let button), false): button.setImage(imageName: "image_editor_crop_unlock")
        }
    }

    @objc
    override public var canBecomeFirstResponder: Bool {
        return true
    }

    private static let desiredCornerSize: CGFloat = 24
    private static let minCropSize: CGFloat = desiredCornerSize * 2
    private var cornerSize = CGSize.zero

    private var clipViewConstraints = [NSLayoutConstraint]()

    private func updateClipViewLayout() {
        NSLayoutConstraint.deactivate(clipViewConstraints)
        clipViewConstraints = ImageEditorCanvasView.updateContentLayout(transform: transform,
                                                                        contentView: clipView)

        clipView.superview?.setNeedsLayout()
        clipView.superview?.layoutIfNeeded()
        updateCropViewLayout()
    }

    private var cropViewConstraints = [NSLayoutConstraint]()

    private func setCropViewAppearance() {

        // TODO: Tune the size.
        let cornerSize = CGSize(
            width: min(clipView.bounds.width * 0.5, ImageEditorCropViewController.desiredCornerSize),
            height: min(clipView.bounds.height * 0.5, ImageEditorCropViewController.desiredCornerSize)
        )
        self.cornerSize = cornerSize
        for cropCornerView in cropCornerViews {
            let cornerThickness: CGFloat = 2

            let shapeLayer = CAShapeLayer()
            cropCornerView.layer.addSublayer(shapeLayer)
            shapeLayer.themeFillColor = .white
            shapeLayer.themeStrokeColor = nil
            cropCornerView.layoutCallback = { (view) in
                let shapeFrame = view.bounds.insetBy(dx: -cornerThickness, dy: -cornerThickness)
                shapeLayer.frame = shapeFrame

                let bezierPath = UIBezierPath()

                switch cropCornerView.cropRegion {
                case .topLeft:
                    bezierPath.addRegion(withPoints: [
                        CGPoint.zero,
                        CGPoint(x: shapeFrame.width - cornerThickness, y: 0),
                        CGPoint(x: shapeFrame.width - cornerThickness, y: cornerThickness),
                        CGPoint(x: cornerThickness, y: cornerThickness),
                        CGPoint(x: cornerThickness, y: shapeFrame.height - cornerThickness),
                        CGPoint(x: 0, y: shapeFrame.height - cornerThickness)
                        ])
                case .topRight:
                    bezierPath.addRegion(withPoints: [
                        CGPoint(x: shapeFrame.width, y: 0),
                        CGPoint(x: shapeFrame.width, y: shapeFrame.height - cornerThickness),
                        CGPoint(x: shapeFrame.width - cornerThickness, y: shapeFrame.height - cornerThickness),
                        CGPoint(x: shapeFrame.width - cornerThickness, y: cornerThickness),
                        CGPoint(x: cornerThickness, y: cornerThickness),
                        CGPoint(x: cornerThickness, y: 0)
                        ])
                case .bottomLeft:
                    bezierPath.addRegion(withPoints: [
                        CGPoint(x: 0, y: shapeFrame.height),
                        CGPoint(x: 0, y: cornerThickness),
                        CGPoint(x: cornerThickness, y: cornerThickness),
                        CGPoint(x: cornerThickness, y: shapeFrame.height - cornerThickness),
                        CGPoint(x: shapeFrame.width - cornerThickness, y: shapeFrame.height - cornerThickness),
                        CGPoint(x: shapeFrame.width - cornerThickness, y: shapeFrame.height)
                        ])
                case .bottomRight:
                    bezierPath.addRegion(withPoints: [
                        CGPoint(x: shapeFrame.width, y: shapeFrame.height),
                        CGPoint(x: cornerThickness, y: shapeFrame.height),
                        CGPoint(x: cornerThickness, y: shapeFrame.height - cornerThickness),
                        CGPoint(x: shapeFrame.width - cornerThickness, y: shapeFrame.height - cornerThickness),
                        CGPoint(x: shapeFrame.width - cornerThickness, y: cornerThickness),
                        CGPoint(x: shapeFrame.width, y: cornerThickness)
                        ])
                default:
                    Log.error("[ImageEditorCropViewController] Invalid crop region: \(cropCornerView.cropRegion)")
                }

                shapeLayer.path = bezierPath.cgPath
            }
        }
        cropView.themeBorderColor = .white
        cropView.layer.borderWidth = 1
    }

    private func updateCropViewLayout() {
        NSLayoutConstraint.deactivate(cropViewConstraints)
        cropViewConstraints.removeAll()

        // TODO: Tune the size.
        let cornerSize = CGSize(
            width: min(clipView.bounds.width * 0.5, ImageEditorCropViewController.desiredCornerSize),
            height: min(clipView.bounds.height * 0.5, ImageEditorCropViewController.desiredCornerSize)
        )
        self.cornerSize = cornerSize
        for cropCornerView in cropCornerViews {
            cropViewConstraints.append(cropCornerView.set(.width, to: cornerSize.width))
            cropViewConstraints.append(cropCornerView.set(.height, to: cornerSize.height))
        }

        if !isCropGestureActive {
            cropView.frame = view.convert(clipView.bounds, from: clipView)
        }
    }

    internal func updateContent() {
        Log.assertOnMainThread()

        let viewSize = croppedContentView.bounds.size
        guard viewSize.width > 0,
                viewSize.height > 0 else {
                return
        }

        updateTransform(transform)
    }

    private func updateTransform(_ transform: ImageEditorTransform) {
        self.transform = transform

        // Don't animate changes.
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        applyTransform()
        updateClipViewLayout()
        updateImageLayer()
        updateNavigationBar()

        CATransaction.commit()
    }

    private func applyTransform() {
        let viewSize = croppedContentView.bounds.size
        croppedContentView.layer.setAffineTransform(transform.affineTransform(viewSize: viewSize))
        uncroppedContentView.layer.setAffineTransform(transform.affineTransform(viewSize: viewSize))
    }

    private func updateImageLayer() {
        let viewSize = croppedContentView.bounds.size
        ImageEditorCanvasView.updateImageLayer(imageLayer: croppedImageLayer, viewSize: viewSize, imageSize: model.srcImageSizePixels, transform: transform)
        ImageEditorCanvasView.updateImageLayer(imageLayer: uncroppedImageLayer, viewSize: viewSize, imageSize: model.srcImageSizePixels, transform: transform)
    }

    private func configureGestures() {
        self.view.isUserInteractionEnabled = true

        let pinchGestureRecognizer = ImageEditorPinchGestureRecognizer(target: self, action: #selector(handlePinchGesture(_:)))
        pinchGestureRecognizer.referenceView = self.clipView
        // Use this VC as a delegate to ensure that pinches only
        // receive touches that start inside of the cropped image bounds.
        pinchGestureRecognizer.delegate = self
        view.addGestureRecognizer(pinchGestureRecognizer)

        let panGestureRecognizer = ImageEditorPanGestureRecognizer(target: self, action: #selector(handlePanGesture(_:)))
        panGestureRecognizer.maximumNumberOfTouches = 1
        panGestureRecognizer.referenceView = self.clipView
        // _DO NOT_ use this VC as a delegate to filter touches;
        // pan gestures can start outside the cropped image bounds.
        // Otherwise the edges of the crop rect are difficult to
        // "grab".
        view.addGestureRecognizer(panGestureRecognizer)

        // De-conflict the gestures; the pan gesture has priority.
        panGestureRecognizer.shouldBeRequiredToFail(by: pinchGestureRecognizer)
    }

    // MARK: - Gestures

    private class func unitTranslation(oldLocationView: CGPoint,
                                       newLocationView: CGPoint,
                                       viewBounds: CGRect,
                                       oldTransform: ImageEditorTransform) -> CGPoint {

        // The beauty of using an SRT (scale-rotate-translation) tranform ordering
        // is that the translation is applied last, so it's trivial to convert
        // translations from view coordinates to transform translation.
        // Our (view bounds == canvas bounds) so no need to convert.
        let translation = newLocationView.subtracting(oldLocationView)
        let translationUnit = translation.toUnitCoordinates(viewSize: viewBounds.size, shouldClamp: false)
        let newUnitTranslation = oldTransform.unitTranslation.adding(translationUnit)
        return newUnitTranslation
    }

    // MARK: - Pinch Gesture

    @objc
    public func handlePinchGesture(_ gestureRecognizer: ImageEditorPinchGestureRecognizer) {
        Log.assertOnMainThread()

        // We could undo an in-progress pinch if the gesture is cancelled, but it seems gratuitous.

        switch gestureRecognizer.state {
        case .began:
            gestureStartTransform = transform
        case .changed, .ended:
            guard let gestureStartTransform = gestureStartTransform else {
                Log.error("[ImageEditorCropViewController] Missing pinchTransform.")
                return
            }

            let newUnitTranslation = ImageEditorCropViewController.unitTranslation(
                oldLocationView: gestureRecognizer.pinchStateStart.centroid,
                newLocationView: gestureRecognizer.pinchStateLast.centroid,
                viewBounds: clipView.bounds,
                oldTransform: gestureStartTransform
            )

            let newRotationRadians = gestureStartTransform.rotationRadians + gestureRecognizer.pinchStateLast.angleRadians - gestureRecognizer.pinchStateStart.angleRadians

            // NOTE: We use max(1, ...) to avoid divide-by-zero.
            //
            // TODO: The clamp limits are wrong.
            let newScaling =
                (gestureStartTransform.scaling * gestureRecognizer.pinchStateLast.distance / max(1.0, gestureRecognizer.pinchStateStart.distance))
                .clamp(ImageEditorTextItem.kMinScaling, ImageEditorTextItem.kMaxScaling)

            updateTransform(
                ImageEditorTransform(
                    outputSizePixels: gestureStartTransform.outputSizePixels,
                    unitTranslation: newUnitTranslation,
                    rotationRadians: newRotationRadians,
                    scaling: newScaling,
                    isFlipped: gestureStartTransform.isFlipped
                ).normalize(srcImageSizePixels: model.srcImageSizePixels)
            )
        default:
            break
        }
    }

    // MARK: - Pan Gesture

    private var gestureStartTransform: ImageEditorTransform?
    private var panCropRegion: CropRegion?
    private var isCropGestureActive: Bool {
        return panCropRegion != nil
    }

    @objc
    public func handlePanGesture(_ gestureRecognizer: ImageEditorPanGestureRecognizer) {
        Log.assertOnMainThread()
        
        // We could undo an in-progress pinch if the gesture is cancelled, but it seems gratuitous.

        // Handle the GR if necessary.
        switch gestureRecognizer.state {
        case .began:
            Log.verbose("[ImageEditorCropViewController] began: \(transform.unitTranslation)")
            gestureStartTransform = transform
            // Pans that start near the crop rectangle should be treated as crop gestures.
            panCropRegion = cropRegion(forGestureRecognizer: gestureRecognizer)
        case .changed, .ended:
            if let panCropRegion = panCropRegion {
                // Crop pan gesture
                handleCropPanGesture(gestureRecognizer, panCropRegion: panCropRegion)
            } else {
                handleNormalPanGesture(gestureRecognizer)
            }
        default:
            break
        }

        // Reset the GR if necessary.
        switch gestureRecognizer.state {
        case .ended, .failed, .cancelled, .possible:
            if panCropRegion != nil {
                panCropRegion = nil

                // Don't animate changes.
                CATransaction.begin()
                CATransaction.setDisableActions(true)

                updateCropViewLayout()

                CATransaction.commit()
            }
        default:
            break
        }
    }

    private func handleCropPanGesture(_ gestureRecognizer: ImageEditorPanGestureRecognizer, panCropRegion: CropRegion) {
        Log.assertOnMainThread()

        guard let locationStart = gestureRecognizer.locationFirst else {
            Log.error("[ImageEditorCropViewController] Missing locationStart.")
            return
        }
        let locationNow = gestureRecognizer.location(in: self.clipView)

        // Crop pan gesture
        let locationDelta = locationNow.subtracting(locationStart)

        let cropRectangleStart = clipView.bounds
        var cropRectangleNow = cropRectangleStart

        // Derive the new crop rectangle.

        // We limit the crop rectangle's minimum size for two reasons.
        //
        // * To ensure that the crop rectangles "corner handles"
        //   can always be safely drawn.
        // * To avoid awkward interactions when the crop rectangle
        //   is very small.  Users can always crop multiple times.
        let maxDeltaX = cropRectangleNow.size.width - cornerSize.width * 2
        let maxDeltaY = cropRectangleNow.size.height - cornerSize.height * 2

        switch panCropRegion {
        case .left, .topLeft, .bottomLeft:
            let delta = min(maxDeltaX, max(0, locationDelta.x))
            cropRectangleNow.origin.x += delta
            cropRectangleNow.size.width -= delta
        case .right, .topRight, .bottomRight:
            let delta = min(maxDeltaX, max(0, -locationDelta.x))
            cropRectangleNow.size.width -= delta
        default:
            break
        }

        switch panCropRegion {
        case .top, .topLeft, .topRight:
            let delta = min(maxDeltaY, max(0, locationDelta.y))
            cropRectangleNow.origin.y += delta
            cropRectangleNow.size.height -= delta
        case .bottom, .bottomLeft, .bottomRight:
            let delta = min(maxDeltaY, max(0, -locationDelta.y))
            cropRectangleNow.size.height -= delta
        default:
            break
        }

        // If crop is locked, update the crop rectangle
        // to retain the original aspect ratio.
        if (isCropLocked) {
            let scaleX = cropRectangleNow.width / cropRectangleStart.width
            let scaleY = cropRectangleNow.height / cropRectangleStart.height
            var cropRectangleLocked = cropRectangleStart
            // Find a new crop rectangle size with the correct aspect
            // ratio which is always larger than the "naive" crop rectangle.
            // We always expand and never shrink the crop rectangle to
            // fix its aspect ratio, to ensure the "max deltas" enforced
            // above still are honored.
            if scaleX > scaleY {
                cropRectangleLocked.size.width = cropRectangleNow.width
                cropRectangleLocked.size.height = cropRectangleNow.width * cropRectangleStart.height / cropRectangleStart.width
            } else {
                cropRectangleLocked.size.height = cropRectangleNow.height
                cropRectangleLocked.size.width = cropRectangleNow.height * cropRectangleStart.width / cropRectangleStart.height
            }

            // Pin the crop rectangle to the sides that aren't being manipulated.
            switch panCropRegion {
            case .left, .topLeft, .bottomLeft:
                cropRectangleLocked.origin.x = cropRectangleStart.maxX - cropRectangleLocked.width
            default:
                // Bias towards aligning left.
                cropRectangleLocked.origin.x = cropRectangleStart.minX
            }
            switch panCropRegion {
            case .top, .topLeft, .topRight:
                cropRectangleLocked.origin.y = cropRectangleStart.maxY - cropRectangleLocked.height
            default:
            // Bias towards aligning top.
                cropRectangleLocked.origin.y = cropRectangleStart.minY
            }

            cropRectangleNow = cropRectangleLocked
        }

        cropView.frame = view.convert(cropRectangleNow, from: clipView)

        switch gestureRecognizer.state {
        case .ended:
            crop(toRect: cropRectangleNow)
        default:
            break
        }
    }

    private func crop(toRect cropRect: CGRect) {
        let viewBounds = clipView.bounds

        // TODO: The output size should be rounded, although this can
        //       cause crop to be slightly not WYSIWYG.
        let croppedOutputSizePixels = CGSize(
            width: transform.outputSizePixels.width * cropRect.width / clipView.bounds.width,
            height: transform.outputSizePixels.height * cropRect.height / clipView.bounds.height
        ).rounded()

        // We need to update the transform's unitTranslation and scaling properties
        // to reflect the crop.
        //
        // Cropping involves changing the output size AND aspect ratio.  The output aspect ratio
        // has complicated effects on the rendering behavior of the image background, since the
        // default rendering size of the image is an "aspect fill" of the output bounds.
        // Therefore, the simplest and more reliable way to update the scaling is to measure
        // the difference between the "before crop"/"after crop" image frames and adjust the
        // scaling accordingly.
        let naiveTransform = ImageEditorTransform(outputSizePixels: croppedOutputSizePixels,
                                                  unitTranslation: transform.unitTranslation,
                                                  rotationRadians: transform.rotationRadians,
                                                  scaling: transform.scaling,
                                                  isFlipped: transform.isFlipped)
        let naiveImageFrameOld = ImageEditorCanvasView.imageFrame(forViewSize: transform.outputSizePixels, imageSize: model.srcImageSizePixels, transform: naiveTransform)
        let naiveImageFrameNew = ImageEditorCanvasView.imageFrame(forViewSize: croppedOutputSizePixels, imageSize: model.srcImageSizePixels, transform: naiveTransform)
        let scalingDeltaX = naiveImageFrameNew.width / naiveImageFrameOld.width
        let scalingDeltaY = naiveImageFrameNew.height / naiveImageFrameOld.height
        // scalingDeltaX and scalingDeltaY should only differ by rounding error.
        let scalingDelta = (scalingDeltaX + scalingDeltaY) * 0.5
        let scaling = transform.scaling / scalingDelta

        // We also need to update the transform's translation, to ensure that the correct
        // content (background image and items) ends up in the crop region.
        //
        // To do this, we use the center of the image content.  Due to
        // scaling and rotation of the image content, it's far simpler to
        // use the center.
        let oldAffineTransform = transform.affineTransform(viewSize: viewBounds.size)
        // We determine the pre-crop render frame for the image.
        let oldImageFrameCanvas = ImageEditorCanvasView.imageFrame(forViewSize: viewBounds.size, imageSize: model.srcImageSizePixels, transform: transform)
        // We project it into pre-crop view coordinates (the coordinate
        // system of the crop rectangle).  Note that a CALayer's tranform
        // is applied using its "anchor point", the center of the layer.
        // so we translate before and after the projection to be consistent.
        let oldImageCenterView = oldImageFrameCanvas.center
            .subtracting(viewBounds.center)
            .applying(oldAffineTransform)
            .adding(viewBounds.center)
        // We transform the "image content center" into the unit coordinates
        // of the crop rectangle.
        let newImageCenterUnit = oldImageCenterView.toUnitCoordinates(viewBounds: cropRect, shouldClamp: false)
        // The transform's "unit translation" represents a deviation from
        // the center of the output canvas, so we need to subtract the
        // unit midpoint.
        let unitTranslation = newImageCenterUnit.subtracting(CGPoint(x: 0.5, y: 0.5))

        // Clear the panCropRegion now so that the crop bounds are updated
        // immediately.
        panCropRegion = nil

        updateTransform(
            ImageEditorTransform(
                outputSizePixels: croppedOutputSizePixels,
                unitTranslation: unitTranslation,
                rotationRadians: transform.rotationRadians,
                scaling: scaling,
                isFlipped: transform.isFlipped
            ).normalize(srcImageSizePixels: model.srcImageSizePixels)
        )
    }

    private func handleNormalPanGesture(_ gestureRecognizer: ImageEditorPanGestureRecognizer) {
        Log.assertOnMainThread()

        guard let gestureStartTransform = gestureStartTransform else {
            Log.error("[ImageEditorCropViewController] Missing pinchTransform.")
            return
        }
        guard let oldLocationView = gestureRecognizer.locationFirst else {
            Log.error("[ImageEditorCropViewController] Missing locationStart.")
            return
        }

        let newLocationView = gestureRecognizer.location(in: self.clipView)
        let newUnitTranslation = ImageEditorCropViewController.unitTranslation(oldLocationView: oldLocationView,
                                                                               newLocationView: newLocationView,
                                                                               viewBounds: clipView.bounds,
                                                                               oldTransform: gestureStartTransform)

        updateTransform(ImageEditorTransform(outputSizePixels: gestureStartTransform.outputSizePixels,
                                         unitTranslation: newUnitTranslation,
                                         rotationRadians: gestureStartTransform.rotationRadians,
                                         scaling: gestureStartTransform.scaling,
                                         isFlipped: gestureStartTransform.isFlipped).normalize(srcImageSizePixels: model.srcImageSizePixels))
    }

    private func cropRegion(forGestureRecognizer gestureRecognizer: ImageEditorPanGestureRecognizer) -> CropRegion? {
        guard let location = gestureRecognizer.locationFirst else {
            Log.error("[ImageEditorCropViewController] Missing locationStart.")
            return nil
        }

        let tolerance: CGFloat = ImageEditorCropViewController.desiredCornerSize * 2.0
        let left = tolerance
        let top = tolerance
        let right = clipView.bounds.width - tolerance
        let bottom = clipView.bounds.height - tolerance

        // We could ignore touches far outside the crop rectangle.
        if location.x < left {
            if location.y < top {
                return .topLeft
            } else if location.y > bottom {
                return .bottomLeft
            } else {
                return .left
            }
        } else if location.x > right {
            if location.y < top {
                return .topRight
            } else if location.y > bottom {
                return .bottomRight
            } else {
                return .right
            }
        } else {
            if location.y < top {
                return .top
            } else if location.y > bottom {
                return .bottom
            } else {
                return nil
            }
        }
    }

    // MARK: - Events

    @objc func didTapDone(sender: UIButton) {
        completeAndDismiss()
    }

    private func completeAndDismiss() {
        self.delegate?.cropDidComplete(transform: transform)

        self.dismiss(animated: false) {
            // Do nothing.
        }
    }

    @objc public func rotate90ButtonPressed() {
        rotateButtonPressed(angleRadians: -CGFloat.pi * 0.5, rotateCanvas: true)
    }

    private func rotateButtonPressed(angleRadians: CGFloat, rotateCanvas: Bool) {
        let outputSizePixels = (rotateCanvas
            // Invert width and height.
            ? CGSize(width: transform.outputSizePixels.height,
            height: transform.outputSizePixels.width)
        : transform.outputSizePixels)
        let unitTranslation = transform.unitTranslation
        let rotationRadians = transform.rotationRadians + angleRadians
        let scaling = transform.scaling
        updateTransform(ImageEditorTransform(outputSizePixels: outputSizePixels,
                                         unitTranslation: unitTranslation,
                                         rotationRadians: rotationRadians,
                                         scaling: scaling,
                                         isFlipped: transform.isFlipped).normalize(srcImageSizePixels: model.srcImageSizePixels))
    }

    @objc public func flipButtonPressed() {
        updateTransform(ImageEditorTransform(outputSizePixels: transform.outputSizePixels,
                                             unitTranslation: transform.unitTranslation,
                                             rotationRadians: transform.rotationRadians,
                                             scaling: transform.scaling,
                                             isFlipped: !transform.isFlipped).normalize(srcImageSizePixels: model.srcImageSizePixels))
    }

    @objc func didTapReset(sender: UIButton) {
        updateTransform(ImageEditorTransform.defaultTransform(srcImageSizePixels: model.srcImageSizePixels))
    }

    @objc public func cropLockButtonPressed() {
        isCropLocked = !isCropLocked
        updateCropLockButton()
    }
}

// MARK: -

extension ImageEditorCropViewController: UIGestureRecognizerDelegate {

    @objc public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // Until the GR recognizes, it should only see touches that start within the content.
        guard gestureRecognizer.state == .possible else {
            return true
        }
        let location = touch.location(in: clipView)
        return clipView.bounds.contains(location)
    }
}
