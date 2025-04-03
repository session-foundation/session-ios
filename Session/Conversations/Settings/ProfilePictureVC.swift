// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit

/// Shown when the user taps a profile picture in the conversation settings.
final class ProfilePictureVC: BaseVC {
    private let image: UIImage?
    private let animatedImageData: Data?
    private let snTitle: String
    
    private var imageSize: CGFloat { (UIScreen.main.bounds.width - (2 * Values.largeSpacing)) }
    
    // MARK: - UI
    
    private lazy var fallbackView: UIView = {
        let result: UIView = UIView()
        result.clipsToBounds = true
        result.themeBackgroundColor = .backgroundSecondary
        result.layer.cornerRadius = (imageSize / 2)
        result.isHidden = (
            image != nil ||
            animatedImageData != nil
        )
        result.set(.width, to: imageSize)
        result.set(.height, to: imageSize)
        
        return result
    }()
    
    private lazy var imageView: UIImageView = {
        let result: UIImageView = UIImageView(image: image)
        result.clipsToBounds = true
        result.contentMode = .scaleAspectFill
        result.layer.cornerRadius = (imageSize / 2)
        result.isHidden = (image == nil)
        result.set(.width, to: imageSize)
        result.set(.height, to: imageSize)
        
        return result
    }()
    
    private lazy var animatedImageView: AnimatedImageView = {
        let result: AnimatedImageView = AnimatedImageView()
        result.loadAnimatedImage(from: animatedImageData)
        result.clipsToBounds = true
        result.contentMode = .scaleAspectFill
        result.layer.cornerRadius = (imageSize / 2)
        result.isHidden = (animatedImageData == nil)
        result.set(.width, to: imageSize)
        result.set(.height, to: imageSize)
        
        return result
    }()
    
    // MARK: - Initialization
    
    init(image: UIImage?, animatedImageData: Data?, title: String) {
        self.image = image
        self.animatedImageData = animatedImageData
        self.snTitle = title
        
        super.init(nibName: nil, bundle: nil)
    }
    
    override init(nibName: String?, bundle: Bundle?) {
        preconditionFailure("Use init(image:) instead.")
    }
    
    required init?(coder: NSCoder) {
        preconditionFailure("Use init(coder:) instead.")
    }
    
    override func viewDidLoad() {
        view.themeBackgroundColor = .backgroundPrimary
        
        setNavBarTitle(snTitle)
        
        // Close button
        let closeButton = UIBarButtonItem(
            image: #imageLiteral(resourceName: "X").withRenderingMode(.alwaysTemplate),
            style: .plain,
            target: self,
            action: #selector(close)
        )
        closeButton.themeTintColor = .textPrimary
        navigationItem.leftBarButtonItem = closeButton
        
        view.addSubview(fallbackView)
        view.addSubview(imageView)
        view.addSubview(animatedImageView)
        
        fallbackView.center(in: view)
        imageView.center(in: view)
        animatedImageView.center(in: view)
        
        // Gesture recognizer
        let swipeGestureRecognizer = UISwipeGestureRecognizer(target: self, action: #selector(close))
        swipeGestureRecognizer.direction = .down
        view.addGestureRecognizer(swipeGestureRecognizer)
    }
    
    @objc private func close() {
        presentingViewController?.dismiss(animated: true, completion: nil)
    }
}
