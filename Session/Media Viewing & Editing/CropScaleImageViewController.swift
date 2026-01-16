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
        
        return result
    }()
    
    private lazy var imageContainerView: UIView = {
        let result: UIView = UIView()
        result.themeBackgroundColor = .clear
        
        return result
    }()
    
    private lazy var imageView: SessionImageView = {
        let result: SessionImageView = SessionImageView(dataManager: dataManager)
        result.loadImage(source) { [weak self] buffer in
            guard let self, srcImageSizePoints == .zero else { return }
            
            self.srcImageSizePoints = (buffer?.firstFrame.size ?? .zero)
            self.imageView.set(.width, to: self.srcImageSizePoints.width)
            self.imageView.set(.height, to: self.srcImageSizePoints.height)
            self.configureScrollView()
        }
        
        return result
    }()
    
    private lazy var buttonStackView: UIStackView = {
        let result: UIStackView = UIStackView(arrangedSubviews: [cancelButton, doneButton])
        result.axis = .horizontal
        result.distribution = .fillEqually
        result.alignment = .fill
        
        return result
    }()
    
    private lazy var cancelButton: UIButton = {
        let result: UIButton = UIButton()
        result.titleLabel?.font = .systemFont(ofSize: 18)
        result.setTitle("cancel".localized(), for: .normal)
        result.setThemeTitleColor(.textPrimary, for: .normal)
        result.setThemeBackgroundColor(.backgroundSecondary, for: .highlighted)
        result.contentEdgeInsets = UIEdgeInsets(
            top: Values.mediumSpacing,
            leading: 0,
            bottom: (UIApplication.shared.keyWindow?.safeAreaInsets.bottom ?? Values.mediumSpacing),
            trailing: 0
        )
        result.addTarget(self, action: #selector(cancelPressed), for: .touchUpInside)
        
        return result
    }()
    
    private lazy var doneButton: UIButton = {
        let result: UIButton = UIButton()
        result.titleLabel?.font = .systemFont(ofSize: 18)
        result.setTitle("done".localized(), for: .normal)
        result.setThemeTitleColor(.textPrimary, for: .normal)
        result.setThemeBackgroundColor(.backgroundPrimary, for: .highlighted)
        result.setThemeBackgroundColor(.backgroundSecondary, for: .highlighted)
        result.contentEdgeInsets = UIEdgeInsets(
            top: Values.mediumSpacing,
            leading: 0,
            bottom: (UIApplication.shared.keyWindow?.safeAreaInsets.bottom ?? Values.mediumSpacing),
            trailing: 0
        )
        result.addTarget(self, action: #selector(donePressed), for: .touchUpInside)
        
        return result
    }()
       
    private lazy var maskingView: BezierPathView = {
        let result: BezierPathView = BezierPathView()
        result.configureShapeLayer = { [weak self] layer, bounds in
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

        view.addSubview(scrollView)
        view.addSubview(maskingView)
        view.addSubview(buttonStackView)
        scrollView.addSubview(imageContainerView)
        imageContainerView.addSubview(imageView)
        
        scrollView.pin(.top, to: .top, of: view)
        scrollView.pin(.leading, to: .leading, of: view)
        scrollView.pin(.trailing, to: .trailing, of: view)
        scrollView.pin(.bottom, to: .top, of: buttonStackView)
        
        maskingView.pin(to: scrollView)
        
        imageContainerView.pin(to: scrollView)
        imageView.pin(to: imageContainerView)
        
        buttonStackView.pin(.leading, to: .leading, of: view)
        buttonStackView.pin(.trailing, to: .trailing, of: view)
        buttonStackView.pin(.bottom, to: .bottom, of: view)
    }
    
    private func configureScrollView() {
        guard srcImageSizePoints.width > 0 && srcImageSizePoints.height > 0 else { return }
        guard scrollView.bounds.width > 0 && scrollView.bounds.height > 0 else { return }
        
        // Get the crop circle size
        let cropCircleSize: CGFloat = min(scrollView.bounds.width, scrollView.bounds.height) - (maskMargin * 2)
        
        // Calculate the scale to fit the image to fill the crop circle then start at min scale
        let widthScale: CGFloat = (cropCircleSize / srcImageSizePoints.width)
        let heightScale: CGFloat = (cropCircleSize / srcImageSizePoints.height)
        let minScale = max(widthScale, heightScale)  // Fill, not fit
        scrollView.minimumZoomScale = minScale
        scrollView.maximumZoomScale = (minScale * 5.0)
        scrollView.zoomScale = minScale
        
        // Center the content
        let cropRect: CGRect = cropFrame(forBounds: scrollView.bounds)
        let scaledImageWidth: CGFloat = (srcImageSizePoints.width * minScale)
        let scaledImageHeight: CGFloat = (srcImageSizePoints.height * minScale)
        let offsetX: CGFloat = ((cropCircleSize - scaledImageWidth) / 2)
        let offsetY: CGFloat = ((cropCircleSize - scaledImageHeight) / 2)
        
        scrollView.contentInset = UIEdgeInsets(
            top: cropRect.minY,
            left: cropRect.minX,
            bottom: (scrollView.bounds.height - cropRect.maxY),
            right: (scrollView.bounds.width - cropRect.maxX)
        )
        scrollView.contentOffset = CGPoint(
            x: -cropRect.minX - offsetX,
            y: -cropRect.minY - offsetY
        )
    }

    // Given the current bounds for the image view, return the frame of the
    // crop region within that view.
    private func cropFrame(forBounds bounds: CGRect) -> CGRect {
        let radius: CGFloat = ((min(bounds.size.width, bounds.size.height) * 0.5) - self.maskMargin)
        
        return CGRect(
            x: ((bounds.size.width * 0.5) - radius),
            y: ((bounds.size.height * 0.5) - radius),
            width: (radius * 2),
            height: (radius * 2)
        )
    }
    
    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        return imageContainerView
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
        let cropCircleFrame = cropFrame(forBounds: scrollView.bounds)
        let zoomScale = scrollView.zoomScale
        let contentOffset = scrollView.contentOffset
        let contentInset = scrollView.contentInset
        
        // Convert to content coordinates
        let contentX = (contentOffset.x + contentInset.left) / zoomScale
        let contentY = (contentOffset.y + contentInset.top) / zoomScale
        
        // Crop size in image coordinates
        let cropSize = cropCircleFrame.width / zoomScale
        
        // Convert to normalized coordinates (0-1)
        let normalizedX = contentX / srcImageSizePoints.width
        let normalizedY = contentY / srcImageSizePoints.height
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
