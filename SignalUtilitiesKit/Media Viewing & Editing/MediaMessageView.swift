//  Copyright (c) 2019 Open Whisper Systems. All rights reserved.

import UIKit
import Combine
import MediaPlayer
import NVActivityIndicatorView
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit

public class MediaMessageView: UIView {
    public enum Mode: UInt {
        case large
        case small
        case attachmentApproval
    }

    // MARK: Properties

    private let dependencies: Dependencies
    public let mode: Mode
    public let attachment: PendingAttachment

    // MARK: Initializers

    @available(*, unavailable, message:"use other constructor instead.")
    required public init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // Currently we only use one mode (AttachmentApproval), so we could simplify this class, but it's kind
    // of nice that it's written in a flexible way in case we'd want to use it elsewhere again in the future.
    @MainActor public required init(
        attachment: PendingAttachment,
        mode: MediaMessageView.Mode,
        using dependencies: Dependencies
    ) {
        self.dependencies = dependencies
        self.attachment = attachment
        self.mode = mode
        
        super.init(frame: CGRect.zero)
        
        setupViews(using: dependencies)
        setupLayout()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - UI
    
    private lazy var stackView: UIStackView = {
        let stackView: UIStackView = UIStackView()
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.axis = .vertical
        stackView.alignment = .center
        stackView.distribution = .fill
        
        switch mode {
            case .attachmentApproval: stackView.spacing = 2
            case .large: stackView.spacing = 10
            case .small: stackView.spacing = 5
        }
        
        return stackView
    }()
    
    private let loadingView: NVActivityIndicatorView = {
        let result: NVActivityIndicatorView = NVActivityIndicatorView(
            frame: CGRect.zero,
            type: .circleStrokeSpin,
            color: .black,
            padding: nil
        )
        result.translatesAutoresizingMaskIntoConstraints = false
        result.isHidden = true
        
        ThemeManager.onThemeChange(observer: result) { [weak result] _, _, resolve in
            guard let textPrimary: UIColor = resolve(.textPrimary) else { return }
            
            result?.color = textPrimary
        }
        
        return result
    }()
    
    private lazy var imageView: SessionImageView = {
        let view: SessionImageView = SessionImageView(
            dataManager: dependencies[singleton: .imageDataManager]
        )
        view.translatesAutoresizingMaskIntoConstraints = false
        view.contentMode = .scaleAspectFit
        view.themeTintColor = .textPrimary
        
        // Override the image to the correct one
        if attachment.isValid, let source: ImageDataManager.DataSource = attachment.visualMediaSource {
            view.layer.minificationFilter = .trilinear
            view.layer.magnificationFilter = .trilinear
            view.loadImage(source)
        }
        else if !attachment.utType.conforms(to: .url) {
            view.image = UIImage(named: "FileLarge")?.withRenderingMode(.alwaysTemplate)
        }
        
        return view
    }()
    
    private lazy var fileTypeImageView: UIImageView = {
        let view: UIImageView = UIImageView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isHidden = true
        
        return view
    }()
    
    private lazy var titleSeparator: UIView = {
        let result: UIView = UIView.vhSpacer(10, 10)
        result.isHidden = !titleLabel.isHidden
        
        return result
    }()
    
    private lazy var titleStackView: UIStackView = {
        let stackView: UIStackView = UIStackView()
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.axis = .vertical
        stackView.distribution = .fill
        stackView.alignment = .center
        
        switch mode {
            case .attachmentApproval: stackView.spacing = 2
            case .large: stackView.spacing = 10
            case .small: stackView.spacing = 5
        }
        
        return stackView
    }()
    
    private lazy var titleLabel: UILabel = {
        let label: UILabel = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        
        // Styling
        switch mode {
            case .attachmentApproval:
                label.font = UIFont.boldSystemFont(ofSize: Values.scaleFromIPhone5To7Plus(16, 22))
                label.themeTextColor = .textPrimary
                
            case .large:
                label.font = UIFont.systemFont(ofSize: Values.scaleFromIPhone5To7Plus(18, 24))
                label.themeTextColor = .primary
                
            case .small:
                label.font = UIFont.systemFont(ofSize: Values.scaleFromIPhone5To7Plus(14, 14))
                label.themeTextColor = .primary
        }
        
        // Title for everything except these types
        if !attachment.utType.conforms(to: .url) && !attachment.isValid {
            if let fileName: String = attachment.sourceFilename?.trimmingCharacters(in: .whitespacesAndNewlines), fileName.count > 0 {
                label.text = fileName
            }
            else if let fileExtension: String = attachment.fileExtension {
                label.text = "attachmentsFileType".localized() + " " + fileExtension.uppercased()
            }
            
            label.textAlignment = .center
            label.lineBreakMode = .byTruncatingMiddle
        }
        
        // Hide the label if it has no content
        label.isHidden = ((label.text?.count ?? 0) == 0)
        
        return label
    }()
    
    private lazy var subtitleLabel: UILabel = {
        let label: UILabel = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        
        // Styling
        switch mode {
            case .attachmentApproval:
                label.font = UIFont.systemFont(ofSize: Values.scaleFromIPhone5To7Plus(12, 18))
                label.themeTextColor = .textSecondary
                
            case .large:
                label.font = UIFont.systemFont(ofSize: Values.scaleFromIPhone5To7Plus(18, 24))
                label.themeTextColor = .primary
                
            case .small:
                label.font = UIFont.systemFont(ofSize: Values.scaleFromIPhone5To7Plus(14, 14))
                label.themeTextColor = .primary
        }
        
        // Subtitle for everything else except these types
        if !attachment.utType.conforms(to: .url) && !attachment.isValid {
            // Format string for file size label in call interstitial view.
            // Embeds: {{file size as 'N mb' or 'N kb'}}.
            let fileSize: UInt = UInt(attachment.fileSize)
            let duration: TimeInterval? = (attachment.duration > 0 ? attachment.duration : nil)
            label.text = duration
                .map { "\(Format.fileSize(fileSize)), \(Format.duration($0))" }
                .defaulting(to: Format.fileSize(fileSize))
            label.textAlignment = .center
        }
        
        // Hide the label if it has no content
        label.isHidden = ((label.text?.count ?? 0) == 0)
        
        return label
    }()
    
    // MARK: - Layout

    @MainActor private func setupViews(using dependencies: Dependencies) {
        switch attachment.source {
            case .text where attachment.utType.conforms(to: .url): break    /// URLs should be handled
            case .text: return  /// Plain text will just be put in the 'message' input so do nothing
            default: break
        }
        
        // Setup the view hierarchy
        addSubview(stackView)
        addSubview(loadingView)
        
        stackView.addArrangedSubview(imageView)
        stackView.addArrangedSubview(titleSeparator)
        stackView.addArrangedSubview(titleStackView)
        
        titleStackView.addArrangedSubview(titleLabel)
        titleStackView.addArrangedSubview(subtitleLabel)
        
        imageView.alpha = 1
        imageView.addSubview(fileTypeImageView)
        
        // Type-specific configurations
        if attachment.utType.isAudio {
            // Hide the 'audioPlayPauseButton' if the 'audioPlayer' failed to get created
            fileTypeImageView.image = UIImage(named: "table_ic_notification_sound")?
                .withRenderingMode(.alwaysTemplate)
            fileTypeImageView.themeTintColor = .textPrimary
            fileTypeImageView.isHidden = false
        }
        else if !attachment.utType.conforms(to: .url) {
            imageView.set(.width, to: .width, of: stackView)
        }
    }
    
    @MainActor private func setupLayout() {
        switch attachment.source {
            case .text where attachment.utType.conforms(to: .url): break    /// URLs should be handled
            case .text: return  /// Plain text will just be put in the 'message' input so do nothing
            default: break
        }
        
        // Sizing calculations
        let clampedRatio: CGFloat = {
            if attachment.utType.conforms(to: .url) {
                return 1
            }
            
            // All other types should maintain the ratio of the image in the 'imageView'
            let imageSize: CGSize = (imageView.image?.size ?? CGSize(width: 1, height: 1))
            let aspectRatio: CGFloat = (imageSize.width / imageSize.height)
        
            return aspectRatio.clamp(0.05, 95.0)
        }()
        
        let maybeImageSize: CGFloat? = {
            if attachment.utType.isImage || attachment.utType.isAnimated {
                guard attachment.isValid else { return nil }
                
                // If we don't have a valid image then use the 'generic' case
            }
            else if attachment.utType.isVideo {
                guard attachment.isValid else { return nil }
                
                // If we don't have a valid image then use the 'generic' case
            }
            else if attachment.utType.conforms(to: .url) {
                return nil
            }
            
            // Generic file size
            switch mode {
                case .large: return 200
                case .attachmentApproval: return 120
                case .small: return 80
            }
        }()
        
        let imageSize: CGFloat = (maybeImageSize ?? 0)
        
        // Actual layout
        NSLayoutConstraint.activate([
            stackView.centerXAnchor.constraint(equalTo: centerXAnchor),
            stackView.centerYAnchor.constraint(equalTo: centerYAnchor),
            stackView.heightAnchor.constraint(lessThanOrEqualTo: heightAnchor),
            
            (maybeImageSize != nil ?
                stackView.widthAnchor.constraint(equalTo: widthAnchor) :
                stackView.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor)
            ),

            (maybeImageSize != nil ?
                imageView.widthAnchor.constraint(equalToConstant: imageSize) :
                imageView.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor)
            ),
            (maybeImageSize != nil ?
                imageView.heightAnchor.constraint(equalToConstant: imageSize) :
                imageView.heightAnchor.constraint(lessThanOrEqualTo: heightAnchor)
            ),
            
            fileTypeImageView.centerXAnchor.constraint(equalTo: imageView.centerXAnchor),
            fileTypeImageView.centerYAnchor.constraint(
                equalTo: imageView.centerYAnchor,
                constant: ceil(imageSize * 0.15)
            ),
            
            fileTypeImageView.widthAnchor.constraint(equalToConstant: imageSize * 0.5),
            fileTypeImageView.heightAnchor.constraint(equalToConstant: imageSize * 0.5),

            loadingView.centerXAnchor.constraint(equalTo: imageView.centerXAnchor),
            loadingView.centerYAnchor.constraint(equalTo: imageView.centerYAnchor),
            loadingView.widthAnchor.constraint(equalToConstant: ceil(imageSize / 3)),
            loadingView.heightAnchor.constraint(equalToConstant: ceil(imageSize / 3))
        ])
        
        if imageView.image?.size == nil {
            // Handle `clampedRatio` ratio when image is from data
            NSLayoutConstraint.activate([
                imageView.widthAnchor.constraint(
                    equalTo: imageView.heightAnchor,
                    multiplier: clampedRatio
                )
            ])
        }
        
        // No inset for the text for URLs but there is for all other layouts
        if !attachment.utType.conforms(to: .url) {
            NSLayoutConstraint.activate([
                titleLabel.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -(32 * 2)),
                subtitleLabel.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -(32 * 2))
            ])
        }
    }
    
    @MainActor public func setError(title: String?, subtitle: String?) {
        switch (title, subtitle) {
            case (.some(let title), .some(let subtitle)):
                titleLabel.text = title
                titleLabel.textAlignment = .center
                titleLabel.isHidden = false
                titleSeparator.isHidden = false
                subtitleLabel.text = subtitle
                subtitleLabel.themeTextColor = .textPrimary
                subtitleLabel.textAlignment = .center
                subtitleLabel.numberOfLines = 0
                subtitleLabel.isHidden = false
                
            case (.some(let title), .none):
                titleLabel.text = title
                titleLabel.isHidden = false
                titleSeparator.isHidden = true
                subtitleLabel.isHidden = true
                
            case (.none, .some(let subtitle)):
                titleLabel.isHidden = true
                titleSeparator.isHidden = true
                subtitleLabel.text = subtitle
                subtitleLabel.themeTextColor = .textSecondary
                subtitleLabel.textAlignment = .center
                subtitleLabel.numberOfLines = 0
                subtitleLabel.isHidden = false
                
            case (.none, .none):
                titleLabel.isHidden = true
                titleSeparator.isHidden = true
                subtitleLabel.isHidden = true
        }
    }
}
