//  Copyright (c) 2019 Open Whisper Systems. All rights reserved.

import UIKit
import MediaPlayer
import SessionUIKit
import SignalUtilitiesKit
import SessionUtilitiesKit

// This kind of view is tricky.  I've tried to organize things in the 
// simplest possible way.
//
// I've tried to avoid the following sources of confusion:
//
// * Points vs. pixels. All variables should have names that
//   reflect the units.  Pretty much everything is done in points
//   except rendering of the output image which is done in pixels.
// * Coordinate systems.  You have a) the src image coordinates
//   b) the image view coordinates c) the output image coordinates.
//   Wherever possible, I've tried to use src image coordinates.
// * Translation & scaling vs. crop region.  The crop region is
//   implicit.  We represent the crop state using the translation 
//   and scaling of the "default" crop region (the largest possible
//   crop region, at the origin (upper left) of the source image.
//   Given the translation & scaling, we can determine a) the crop
//   region b) the rectangle at which the src image should be rendered
//   given a dst view or output context that will yield the 
//   appropriate cropping.
class CropScaleImageViewController: OWSViewController, UIScrollViewDelegate {

    // MARK: Properties

    private let dataManager: ImageDataManagerType
    let source: ImageDataManager.DataSource

    let successCompletion: ((ImageDataManager.DataSource, CGRect) -> Void)

    // In width/height.
    let dstSizePixels: CGSize
    var dstAspectRatio: CGFloat {
        return dstSizePixels.width / dstSizePixels.height
    }

    // The size of the src image in points.
    var srcImageSizePoints: CGSize = CGSize.zero

    // space between the cropping circle and the outside edge of the view
    let maskMargin = CGFloat(20)
    
    // MARK: - UI
    
    private lazy var scrollView: UIScrollView = {
        let result: UIScrollView = UIScrollView()
        result.delegate = self
        result.minimumZoomScale = 1
        result.maximumZoomScale = 5
        result.showsHorizontalScrollIndicator = false
        result.showsVerticalScrollIndicator = false
//        result.clipsToBounds = false
        
        return result
    }()
    
    private lazy var imageView: SessionImageView = {
        let result: SessionImageView = SessionImageView(dataManager: dataManager)
        result.loadImage(source)
        
        return result
    }()

    // MARK: Initializers

    @available(*, unavailable, message:"use other constructor instead.")
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    init(
        source: ImageDataManager.DataSource,
        dstSizePixels: CGSize,
        dataManager: ImageDataManagerType,
        successCompletion: @escaping (ImageDataManager.DataSource, CGRect) -> Void
    ) {
        self.dataManager = dataManager
        self.source = source
        self.dstSizePixels = dstSizePixels
        self.successCompletion = successCompletion
        
        super.init(nibName: nil, bundle: nil)

        srcImageSizePoints = (source.sizeFromMetadata ?? .zero)
    }

    // MARK: View Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        createViews()
    }
    
    override func viewDidLayoutSubviews() {
       super.viewDidLayoutSubviews()
       
        if scrollView.minimumZoomScale == 1.0 && scrollView.bounds.width > 0 {
            configureScrollView()
        }
   }

    // MARK: - Create Views

    private func createViews() {
        title = "attachmentsMoveAndScale".localized()
        view.themeBackgroundColor = .backgroundPrimary

        let contentView = UIView()
        contentView.themeBackgroundColor = .backgroundPrimary
        self.view.addSubview(contentView)
        contentView.pin(to: self.view)
        
        contentView.addSubview(scrollView)
        scrollView.pin(.top, to: .top, of: contentView, withInset: (Values.massiveSpacing + Values.smallSpacing))
        scrollView.pin(.leading, to: .leading, of: contentView)
        scrollView.pin(.trailing, to: .trailing, of: contentView)
        
        imageView.frame = CGRect(origin: .zero, size: srcImageSizePoints)
        scrollView.addSubview(imageView)
        scrollView.contentSize = srcImageSizePoints
        
        let buttonRowBackground: UIView = UIView()
        buttonRowBackground.themeBackgroundColor = .backgroundPrimary
        contentView.addSubview(buttonRowBackground)
        
        let buttonRow: UIView = createButtonRow()
        contentView.addSubview(buttonRow)
        buttonRow.pin(.top, to: .bottom, of: scrollView)
        buttonRow.pin(.leading, to: .leading, of: contentView)
        buttonRow.pin(.trailing, to: .trailing, of: contentView)
        buttonRow.pin(.bottom, to: .bottom, of: contentView)
        buttonRow.set(
            .height,
            to: (
                Values.scaleFromIPhone5To7Plus(35, 45) +
                Values.mediumSpacing +
                (UIApplication.shared.keyWindow?.safeAreaInsets.bottom ?? Values.mediumSpacing)
            )
        )
        buttonRowBackground.pin(to: buttonRow)
        
        let maskingView = BezierPathView()
        contentView.addSubview(maskingView)

        maskingView.configureShapeLayer = { [weak self] layer, bounds in
            guard let self = self else { return }
            
            let path = UIBezierPath(rect: bounds)
            let circleRect = cropFrame(forBounds: bounds)
            let radius = circleRect.size.width * 0.5
            let circlePath = UIBezierPath(roundedRect: circleRect, cornerRadius: radius)

            path.append(circlePath)
            path.usesEvenOddFillRule = true

            layer.path = path.cgPath
            layer.fillRule = .evenOdd
            layer.themeFillColor = .black
            layer.opacity = 0.75
        }
        maskingView.pin(.top, to: .top, of: contentView, withInset: (Values.massiveSpacing + Values.smallSpacing))
        maskingView.pin(.leading, to: .leading, of: contentView)
        maskingView.pin(.trailing, to: .trailing, of: contentView)
        maskingView.pin(.bottom, to: .top, of: buttonRow)
    }
    
    private func configureScrollView() {
        guard srcImageSizePoints.width > 0 && srcImageSizePoints.height > 0 else { return }
        
        let scrollViewBounds = scrollView.bounds
        guard scrollViewBounds.width > 0 && scrollViewBounds.height > 0 else { return }
        
        // Get the crop circle size
        let cropCircleSize = min(scrollViewBounds.width, scrollViewBounds.height) - (maskMargin * 2)
        
        // Calculate the scale to fit the image to fill the crop circle
        let widthScale = cropCircleSize / srcImageSizePoints.width
        let heightScale = cropCircleSize / srcImageSizePoints.height
        let minScale = max(widthScale, heightScale)  // Fill, not fit
        let maxScale = minScale * 5.0
        
        scrollView.minimumZoomScale = minScale
        scrollView.maximumZoomScale = maxScale
        
        // Start at minimum scale (fills the circle)
        scrollView.zoomScale = minScale
        
        // Center the content
        centerScrollViewContents()
    }
    
    private func centerScrollViewContents() {
        let scrollViewSize = scrollView.bounds.size
        let imageViewSize = imageView.frame.size
        
        let horizontalInset = max(0, (scrollViewSize.width - imageViewSize.width) / 2)
        let verticalInset = max(0, (scrollViewSize.height - imageViewSize.height) / 2)
        
        scrollView.contentInset = UIEdgeInsets(
            top: verticalInset,
            left: horizontalInset,
            bottom: verticalInset,
            right: horizontalInset
        )
    }

    // Given the current bounds for the image view, return the frame of the
    // crop region within that view.
    private func cropFrame(forBounds bounds: CGRect) -> CGRect {
        let radius = min(bounds.size.width, bounds.size.height) * 0.5 - self.maskMargin
        // Center the circle's bounding rectangle
        let circleRect = CGRect(x: bounds.size.width * 0.5 - radius, y: bounds.size.height * 0.5 - radius, width: radius * 2, height: radius * 2)
        return circleRect
    }
    
    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        return imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerScrollViewContents()
    }

    private func createButtonRow() -> UIView {
        let result: UIStackView = UIStackView()
        result.axis = .horizontal
        result.distribution = .fillEqually
        result.alignment = .fill

        let cancelButton = createButton(title: "cancel".localized(), action: #selector(cancelPressed))
        result.addArrangedSubview(cancelButton)

        let doneButton = createButton(title: "done".localized(), action: #selector(donePressed))
        doneButton.accessibilityLabel = "Done"
        result.addArrangedSubview(doneButton)
        
        return result
    }

    private func createButton(title: String, action: Selector) -> UIButton {
        let button: UIButton = UIButton()
        button.titleLabel?.font = .systemFont(ofSize: 18)
        button.setTitle(title, for: .normal)
        button.setThemeTitleColor(.textPrimary, for: .normal)
        button.setThemeBackgroundColor(.backgroundSecondary, for: .highlighted)
        button.contentEdgeInsets = UIEdgeInsets(
            top: Values.mediumSpacing,
            leading: 0,
            bottom: (UIApplication.shared.keyWindow?.safeAreaInsets.bottom ?? Values.mediumSpacing),
            trailing: 0
        )
        button.addTarget(self, action: action, for: .touchUpInside)
        
        return button
    }

    // MARK: - Event Handlers

    @objc func cancelPressed() {
        dismiss(animated: true, completion: nil)
    }

    @objc func donePressed() {
        dismiss(animated: true, completion: { [weak self] in
            guard let self = self else { return }
            
            self.successCompletion(self.source, self.calculateCropRect())
        })
    }
    
    // MARK: - Internal Functions
    
    private func calculateCropRect() -> CGRect {
        let scrollViewBounds = scrollView.bounds
        let cropCircleFrame = cropFrame(forBounds: scrollViewBounds)
        
        // Convert crop circle frame to image coordinates
        let zoomScale = scrollView.zoomScale
        let contentOffset = scrollView.contentOffset
        let contentInset = scrollView.contentInset
        
        // Crop circle center in scroll view coordinates
        let cropCenterX = cropCircleFrame.midX
        let cropCenterY = cropCircleFrame.midY
        
        // Convert to content coordinates
        let contentX = (cropCenterX + contentOffset.x - contentInset.left) / zoomScale
        let contentY = (cropCenterY + contentOffset.y - contentInset.top) / zoomScale
        
        // Crop size in image coordinates
        let cropSize = cropCircleFrame.width / zoomScale
        
        // Convert to normalized coordinates (0-1)
        let normalizedX = (contentX - cropSize / 2) / srcImageSizePoints.width
        let normalizedY = (contentY - cropSize / 2) / srcImageSizePoints.height
        let normalizedWidth = cropSize / srcImageSizePoints.width
        let normalizedHeight = cropSize / srcImageSizePoints.height
        
        // Clamp to valid range [0, 1] and ensure width/height don't exceed bounds
        let clampedX = max(0, min(1 - normalizedWidth, normalizedX))
        let clampedY = max(0, min(1 - normalizedHeight, normalizedY))
        let clampedWidth = min(1.0, normalizedWidth, 1.0 - clampedX)
        let clampedHeight = min(1.0, normalizedHeight, 1.0 - clampedY)
        
        return CGRect(
            x: clampedX,
            y: clampedY,
            width: clampedWidth,
            height: clampedHeight
        )
    }
}
// TODO: Fix modal on Dean's calls PR
// TODO: Create the libSession PR to re-enable the profile_updated stuff, also merge in the attachment encryption stuff
