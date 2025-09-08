// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import Lucide
import SessionUIKit
import SessionUtilitiesKit

/// Shown when the user taps a profile picture in the conversation settings.
final class ProfilePictureVC: BaseVC {
    private let dependencies: Dependencies
    private let imageSource: ImageDataManager.DataSource
    private let snTitle: String
    
    private var imageSize: CGFloat { (UIScreen.main.bounds.width - (2 * Values.largeSpacing)) }
    
    // MARK: - UI
    
    private lazy var fallbackView: UIView = {
        let result: UIView = UIView()
        result.clipsToBounds = true
        result.themeBackgroundColor = .backgroundSecondary
        result.layer.cornerRadius = (imageSize / 2)
        result.isHidden = true
        result.set(.width, to: imageSize)
        result.set(.height, to: imageSize)
        
        return result
    }()
    
    private lazy var imageView: SessionImageView = {
        let result: SessionImageView = SessionImageView(
            dataManager: dependencies[singleton: .imageDataManager]
        )
        result.clipsToBounds = true
        result.contentMode = .scaleAspectFill
        result.layer.cornerRadius = (imageSize / 2)
        result.loadImage(imageSource)
        result.set(.width, to: imageSize)
        result.set(.height, to: imageSize)
        
        return result
    }()
    
    // MARK: - Initialization
    
    init(imageSource: ImageDataManager.DataSource, title: String, using dependencies: Dependencies) {
        self.dependencies = dependencies
        self.imageSource = imageSource
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
            image: Lucide.image(icon: .x, size: IconSize.medium.size)?
                .withRenderingMode(.alwaysTemplate),
            style: .plain,
            target: self,
            action: #selector(close)
        )
        closeButton.themeTintColor = .textPrimary
        navigationItem.leftBarButtonItem = closeButton
        
        view.addSubview(fallbackView)
        view.addSubview(imageView)
        
        fallbackView.center(in: view)
        imageView.center(in: view)
        
        // Gesture recognizer
        let swipeGestureRecognizer = UISwipeGestureRecognizer(target: self, action: #selector(close))
        swipeGestureRecognizer.direction = .down
        view.addGestureRecognizer(swipeGestureRecognizer)
    }
    
    @objc private func close() {
        presentingViewController?.dismiss(animated: true, completion: nil)
    }
}
