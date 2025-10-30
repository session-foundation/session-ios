// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import DifferenceKit
import Lucide

public protocol SessionProBottomSheetViewModelType: SessionListScreenContent.ViewModelType {
    func showLoadingModal(title: String, description: String)
    func showErrorModal(title: String, description: ThemedAttributedString)
    func openUrl(_ urlString: String)
}

// MARK: - Pro Features Info

public struct ProFeaturesInfo {
    public let icon: UIImage?
    public let backgroundColors: [ThemeValue]
    public let title: String
    public let description: ThemedAttributedString
    public let accessory: SessionListScreenContent.TextInfo.Accessory
    
    public static func allCases(proStateExpired: Bool) -> [ProFeaturesInfo] {
        return [
            ProFeaturesInfo(
                icon: Lucide.image(icon: .messageSquare, size: IconSize.medium.size),
                backgroundColors: proStateExpired ? [ThemeValue.disabled] : [.explicitPrimary(.blue), .explicitPrimary(.purple)],
                title: "proLongerMessages".localized(),
                description: "proLongerMessagesDescription".localizedFormatted(baseFont: Fonts.Body.smallRegular),
                accessory: .none
            ),
            ProFeaturesInfo(
                icon: Lucide.image(icon: .pin, size: IconSize.medium.size),
                backgroundColors: proStateExpired ? [ThemeValue.disabled] : [.explicitPrimary(.purple), .explicitPrimary(.pink)],
                title: "proUnlimitedPins".localized(),
                description: "proUnlimitedPinsDescription".localizedFormatted(baseFont: Fonts.Body.smallRegular),
                accessory: .none
            ),
            ProFeaturesInfo(
                icon: Lucide.image(icon: .squarePlay, size: IconSize.medium.size),
                backgroundColors: proStateExpired ? [ThemeValue.disabled] : [.explicitPrimary(.pink), .explicitPrimary(.red)],
                title: "proAnimatedDisplayPictures".localized(),
                description: "proAnimatedDisplayPicturesDescription".localizedFormatted(baseFont: Fonts.Body.smallRegular),
                accessory: .none
            ),
            ProFeaturesInfo(
                icon: Lucide.image(icon: .rectangleEllipsis, size: IconSize.medium.size),
                backgroundColors: proStateExpired ? [ThemeValue.disabled] : [.explicitPrimary(.red), .explicitPrimary(.orange)],
                title: "proBadges".localized(),
                description: "proBadgesDescription".put(key: "app_name", value: Constants.app_name).localizedFormatted(Fonts.Body.smallRegular),
                accessory: .proBadgeLeading(themeBackgroundColor: proStateExpired ? .disabled : .primary)
            )
        ]
    }
    
    public static func plusMoreFeatureInfo(proStateExpired: Bool) -> ProFeaturesInfo {
        ProFeaturesInfo(
            icon: Lucide.image(icon: .circlePlus, size: IconSize.medium.size),
            backgroundColors: proStateExpired ? [ThemeValue.disabled] : [.explicitPrimary(.orange), .explicitPrimary(.yellow)],
            title: "plusLoadsMore".localized(),
            description: "plusLoadsMoreDescription"
                .put(key: "pro", value: Constants.pro)
                .put(key: "icon", value: Lucide.Icon.squareArrowUpRight)
                .localizedFormatted(Fonts.Body.smallRegular),
            accessory: .proBadgeLeading(themeBackgroundColor: proStateExpired ? .disabled : .primary)
        )
    }
}
