// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation

final class MediaInfoVC: BaseVC {
    private static let mediaInfoContainerCornerRadius: CGFloat = 8
    
    // MARK: - UI
    
    private lazy var fullScreenButton: UIButton = {
        let result: UIButton = UIButton(type: .custom)
        
        return result
    }()
    
    private lazy var fileIdLabel: UILabel = {
        let result: UILabel = UILabel()
        result.font = .systemFont(ofSize: Values.mediumFontSize)
        result.themeTextColor = .textPrimary
        
        return result
    }()
    
    private lazy var fileTypeLabel: UILabel = {
        let result: UILabel = UILabel()
        result.font = .systemFont(ofSize: Values.mediumFontSize)
        result.themeTextColor = .textPrimary
        
        return result
    }()
    
    private lazy var fileSizeLabel: UILabel = {
        let result: UILabel = UILabel()
        result.font = .systemFont(ofSize: Values.mediumFontSize)
        result.themeTextColor = .textPrimary
        
        return result
    }()
    
    private lazy var resolutionLabel: UILabel = {
        let result: UILabel = UILabel()
        result.font = .systemFont(ofSize: Values.mediumFontSize)
        result.themeTextColor = .textPrimary
        
        return result
    }()
    
    private lazy var durationLabel: UILabel = {
        let result: UILabel = UILabel()
        result.font = .systemFont(ofSize: Values.mediumFontSize)
        result.themeTextColor = .textPrimary
        
        return result
    }()
    
    // MARK: - Initialization
    
    init() {
        super.init(nibName: nil, bundle: nil)
    }

    override init(nibName: String?, bundle: Bundle?) {
        preconditionFailure("Use init() instead.")
    }

    required init?(coder: NSCoder) {
        preconditionFailure("Use init() instead.")
    }
    
    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        
        let mediaInfoContainer: UIView = UIView()
        mediaInfoContainer.clipsToBounds = true
        mediaInfoContainer.themeBackgroundColor = .contextMenu_background
        mediaInfoContainer.layer.cornerRadius = Self.mediaInfoContainerCornerRadius
        
        // File ID
        let fileIdTitleLabel: UILabel = {
            let result = UILabel()
            result.font = .boldSystemFont(ofSize: Values.mediumFontSize)
            result.text = "ATTACHMENT_INFO_FILE_ID".localized() + ":"
            result.themeTextColor = .textPrimary
            
            return result
        }()
        fileIdLabel.text = "" // TODO:
        let fileIdContainerStackView: UIStackView = UIStackView(arrangedSubviews: [ fileIdTitleLabel, fileIdLabel ])
        fileIdContainerStackView.axis = .vertical
        
        // File Type
        let fileTypeTitleLabel: UILabel = {
            let result = UILabel()
            result.font = .boldSystemFont(ofSize: Values.mediumFontSize)
            result.text = "ATTACHMENT_INFO_FILE_TYPE".localized() + ":"
            result.themeTextColor = .textPrimary
            
            return result
        }()
        fileTypeLabel.text = "" // TODO:
        let fileTypeContainerStackView: UIStackView = UIStackView(arrangedSubviews: [ fileTypeTitleLabel, fileTypeLabel ])
        fileTypeContainerStackView.axis = .vertical
        
        // File Size
        let fileSizeTitleLabel: UILabel = {
            let result = UILabel()
            result.font = .boldSystemFont(ofSize: Values.mediumFontSize)
            result.text = "ATTACHMENT_INFO_FILE_SIZE".localized() + ":"
            result.themeTextColor = .textPrimary
            
            return result
        }()
        fileSizeLabel.text = "" // TODO:
        let fileSizeContainerStackView: UIStackView = UIStackView(arrangedSubviews: [ fileSizeTitleLabel, fileSizeLabel ])
        fileSizeContainerStackView.axis = .vertical
        
        // Resolution
        let resolutionTitleLabel: UILabel = {
            let result = UILabel()
            result.font = .boldSystemFont(ofSize: Values.mediumFontSize)
            result.text = "ATTACHMENT_INFO_RESOLUTION".localized() + ":"
            result.themeTextColor = .textPrimary
            
            return result
        }()
        resolutionLabel.text = "" // TODO:
        let resolutionContainerStackView: UIStackView = UIStackView(arrangedSubviews: [ resolutionTitleLabel, resolutionLabel ])
        resolutionContainerStackView.axis = .vertical
        
        // File Size
        let durationTitleLabel: UILabel = {
            let result = UILabel()
            result.font = .boldSystemFont(ofSize: Values.mediumFontSize)
            result.text = "ATTACHMENT_INFO_DURATION".localized() + ":"
            result.themeTextColor = .textPrimary
            
            return result
        }()
        durationLabel.text = "" // TODO:
        let durationContainerStackView: UIStackView = UIStackView(arrangedSubviews: [ durationTitleLabel, durationLabel ])
        durationContainerStackView.axis = .vertical
        
    }
}
