// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit

class VersionFooterView: UIView {
    private static let footerHeight: CGFloat = 75
    private static let logoHeight: CGFloat = 24
    
    private let logoTapCallback: () -> Void
    private let versionTapCallback: () -> Void
    
    // MARK: - UI
    
    private lazy var logoImageView: UIImageView = {
        let result: UIImageView = UIImageView(
            image: UIImage(named: "token_logo")?
                .withRenderingMode(.alwaysTemplate)
        )
        result.setContentHuggingPriority(.required, for: .vertical)
        result.setContentCompressionResistancePriority(.required, for: .vertical)
        result.themeTintColor = .textSecondary
        result.contentMode = .scaleAspectFit
        result.set(.height, to: VersionFooterView.logoHeight)
        result.isUserInteractionEnabled = true
        
        return result
    }()
    
    private lazy var versionLabelContainer: UIView = UIView()
    
    private lazy var versionLabel: UILabel = {
        let result: UILabel = UILabel()
        result.setContentHuggingPriority(.required, for: .vertical)
        result.setContentCompressionResistancePriority(.required, for: .vertical)
        result.font = .systemFont(ofSize: Values.verySmallFontSize)
        result.themeTextColor = .textSecondary
        result.textAlignment = .center
        result.lineBreakMode = .byCharWrapping
        result.numberOfLines = 0
        
        // stringlint:ignore_start
        let infoDict = Bundle.main.infoDictionary
        let version: String = ((infoDict?["CFBundleShortVersionString"] as? String) ?? "0.0.0")
        let buildNumber: String? = (infoDict?["CFBundleVersion"] as? String)
        let commitInfo: String? = (infoDict?["GitCommitHash"] as? String)
        let buildInfo: String? = [buildNumber, commitInfo]
            .compactMap { $0 }
            .joined(separator: " - ")
            .nullIfEmpty
            .map { "(\($0))" }
        // stringlint:ignore_stop
        result.text = [
            "Version \(version)",
            buildInfo
        ].compactMap { $0 }.joined(separator: " ")
        
        return result
    }()
    
    // MARK: - Initialization
    
    init(
        numVersionTapsRequired: Int = 0,
        logoTapCallback: @escaping () -> Void,
        versionTapCallback: @escaping () -> Void
    ) {
        self.logoTapCallback = logoTapCallback
        self.versionTapCallback = versionTapCallback
        
        // Note: Need to explicitly set the height for a table footer view
        // or it will have no height
        super.init(
            frame: CGRect(
                x: 0,
                y: 0,
                width: 0,
                height: VersionFooterView.footerHeight
            )
        )
        
        setupViewHierarchy(numVersionTapsRequired: numVersionTapsRequired)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: - Content
    
    private func setupViewHierarchy(numVersionTapsRequired: Int) {
        addSubview(logoImageView)
        addSubview(versionLabelContainer)
        versionLabelContainer.addSubview(versionLabel)
        
        logoImageView.pin(.top, to: .top, of: self, withInset: Values.mediumSpacing)
        logoImageView.center(.horizontal, in: self, withInset: -2)
        versionLabelContainer.pin(.top, to: .bottom, of: logoImageView)
        versionLabelContainer.pin(.leading, to: .leading, of: self)
        versionLabelContainer.pin(.trailing, to: .trailing, of: self)
        versionLabelContainer.pin(.bottom, to: .bottom, of: self)
        
        versionLabel.pin(.top, to: .top, of: versionLabelContainer, withInset: Values.mediumSpacing)
        versionLabel.pin(.leading, to: .leading, of: versionLabelContainer)
        versionLabel.pin(.trailing, to: .trailing, of: versionLabelContainer)
        versionLabel.pin(.bottom, to: .bottom, of: versionLabelContainer)
        
        let tapGestureRecognizer: UITapGestureRecognizer = UITapGestureRecognizer(
            target: self,
            action: #selector(onLogoTap)
        )
        logoImageView.addGestureRecognizer(tapGestureRecognizer)
        
        if numVersionTapsRequired > 0 {
            let tapGestureRecognizer: UITapGestureRecognizer = UITapGestureRecognizer(
                target: self,
                action: #selector(onVersionMultiTap)
            )
            tapGestureRecognizer.numberOfTapsRequired = numVersionTapsRequired
            versionLabelContainer.addGestureRecognizer(tapGestureRecognizer)
        }
    }
    
    @objc private func onLogoTap() {
        self.logoTapCallback()
    }
    
    @objc private func onVersionMultiTap() {
        self.versionTapCallback()
    }
}
