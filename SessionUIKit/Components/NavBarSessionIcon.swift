// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import UIKit

public class NavBarSessionIcon: UIView {
    // MARK: - Initialization
    
    public init(
        showDebugUI: Bool = false,
        serviceNetworkTitle: String = "",
        isMainnet: Bool = true,
        isOffline: Bool = false
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
            setupNetworkUI(serviceNetworkTitle: serviceNetworkTitle, isMainnet: isMainnet, isOffline: isOffline)
        }
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: - Functions
    
    private func setupNetworkUI(
        serviceNetworkTitle: String,
        isMainnet: Bool,
        isOffline: Bool
    ) {
        let labelStackView: UIStackView = UIStackView()
        labelStackView.axis = .vertical
        addSubview(labelStackView)
        labelStackView.center(in: self)
        labelStackView.transform = CGAffineTransform.identity.rotated(by: -(CGFloat.pi / 6))
        
        if !isMainnet {
            let testnetLabel: UILabel = UILabel()
            testnetLabel.font = Fonts.boldSpaceMono(ofSize: 14)
            testnetLabel.themeAttributedText = ThemedAttributedString(
                string: serviceNetworkTitle,
                attributes: [
                    .themeForegroundColor: ThemeValue.textPrimary,
                    .themeStrokeColor: ThemeValue.backgroundPrimary,
                    .strokeWidth: -3
                ]
            )
            testnetLabel.textAlignment = .center
            labelStackView.addArrangedSubview(testnetLabel)
        }
        
        if isOffline {
            let offlineLabel: UILabel = UILabel()
            offlineLabel.font = Fonts.boldSpaceMono(ofSize: 14)
            offlineLabel.themeAttributedText = ThemedAttributedString(
                string: "Offline",  // stringlint:ignore
                attributes: [
                    .themeForegroundColor: ThemeValue.textPrimary,
                    .themeStrokeColor: ThemeValue.backgroundPrimary,
                    .strokeWidth: -3
                ]
            )
            offlineLabel.textAlignment = .center
            labelStackView.addArrangedSubview(offlineLabel)
        }
    }
}
