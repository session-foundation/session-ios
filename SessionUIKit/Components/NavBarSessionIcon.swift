// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import UIKit

public class NavBarSessionIcon: UIView {
    // MARK: - Initialization
    
    public init(
        showDebugUI: Bool = false,
        serviceNetworkTitle: String = "",
        isMainnet: Bool = true
    ) {
        super.init(frame: .zero)
        
        clipsToBounds = false
        
        let logoImageView = UIImageView()
        logoImageView.image = #imageLiteral(resourceName: "SessionGreen32")
        logoImageView.contentMode = .scaleAspectFit
        logoImageView.set(.width, to: 32)
        logoImageView.set(.height, to: 32)
        
        addSubview(logoImageView)
        logoImageView.pin(to: self)
        
        if showDebugUI {
            setupNetworkUI(serviceNetworkTitle: serviceNetworkTitle, isMainnet: isMainnet)
        }
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: - Functions
    
    private func setupNetworkUI(
        serviceNetworkTitle: String,
        isMainnet: Bool
    ) {
        let labelStackView: UIStackView = UIStackView()
        labelStackView.axis = .vertical
        addSubview(labelStackView)
        labelStackView.center(in: self)
        labelStackView.transform = CGAffineTransform.identity.rotated(by: -(CGFloat.pi / 6))
        
        let testnetLabel: UILabel = UILabel()
        testnetLabel.font = Fonts.boldSpaceMono(ofSize: 14)
        testnetLabel.textAlignment = .center
        
        if !isMainnet {
            labelStackView.addArrangedSubview(testnetLabel)
        }
        
        let offlineLabel: UILabel = UILabel()
        offlineLabel.font = Fonts.boldSpaceMono(ofSize: 14)
        offlineLabel.textAlignment = .center
        labelStackView.addArrangedSubview(offlineLabel)
        
        ThemeManager.onThemeChange(observer: testnetLabel) { [weak testnetLabel, weak offlineLabel] theme, primaryColor in
            guard
                let textColor: UIColor = theme.color(for: .textPrimary),
                let strokeColor: UIColor = theme.color(for: .backgroundPrimary)
            else { return }
            
            if !isMainnet {
                testnetLabel?.attributedText = NSAttributedString(
                    string: serviceNetworkTitle,
                    attributes: [
                        .foregroundColor: textColor,
                        .strokeColor: strokeColor,
                        .strokeWidth: -3
                    ]
                )
            }
            
            offlineLabel?.attributedText = NSAttributedString(
                string: "Offline",  // stringlint:ignore
                attributes: [
                    .foregroundColor: textColor,
                    .strokeColor: strokeColor,
                    .strokeWidth: -3
                ]
            )
        }
    }
}
