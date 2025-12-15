// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import DifferenceKit
import Lucide

// MARK: - Pro Features Info

public struct ProFeaturesInfo {
    public enum ProState {
        case none
        case expired
        case active
    }
    
    public let icon: UIImage?
    public let backgroundColors: [ThemeValue]
    public let title: String
    public let description: ThemedAttributedString
    public let inlineImageInfo: SessionListScreenContent.TextInfo.InlineImageInfo?
    
    public init(
        icon: UIImage?,
        backgroundColors: [ThemeValue],
        title: String,
        description: ThemedAttributedString,
        inlineImageInfo: SessionListScreenContent.TextInfo.InlineImageInfo? = nil
    ) {
        self.icon = icon
        self.backgroundColors = backgroundColors
        self.title = title
        self.description = description
        self.inlineImageInfo = inlineImageInfo
    }
    
    public static func allCases(proState: ProState) -> [ProFeaturesInfo] {
        return [
            ProFeaturesInfo(
                icon: Lucide.image(icon: .messageSquare, size: IconSize.medium.size),
                backgroundColors: (proState == .expired) ? [ThemeValue.disabled] : [.explicitPrimary(.blue), .explicitPrimary(.purple)],
                title: "proLongerMessages".localized(),
                description: (
                    proState == .none ?
                        "nonProLongerMessagesDescription".localizedFormatted(baseFont: Fonts.Body.smallRegular) :
                        "proLongerMessagesDescription".localizedFormatted(baseFont: Fonts.Body.smallRegular)
                )
            ),
            ProFeaturesInfo(
                icon: Lucide.image(icon: .pin, size: IconSize.medium.size),
                backgroundColors: (proState == .expired) ? [ThemeValue.disabled] : [.explicitPrimary(.purple), .explicitPrimary(.pink)],
                title: "proUnlimitedPins".localized(),
                description: "proUnlimitedPinsDescription".localizedFormatted(baseFont: Fonts.Body.smallRegular)
            ),
            ProFeaturesInfo(
                icon: Lucide.image(icon: .squarePlay, size: IconSize.medium.size),
                backgroundColors: (proState == .expired) ? [ThemeValue.disabled] : [.explicitPrimary(.pink), .explicitPrimary(.red)],
                title: "proAnimatedDisplayPictures".localized(),
                description: "proAnimatedDisplayPicturesDescription".localizedFormatted(baseFont: Fonts.Body.smallRegular)
            ),
            ProFeaturesInfo(
                icon: Lucide.image(icon: .rectangleEllipsis, size: IconSize.medium.size),
                backgroundColors: (proState == .expired) ? [ThemeValue.disabled] : [.explicitPrimary(.red), .explicitPrimary(.orange)],
                title: "proBadges".localized(),
                description: "proBadgesDescription".put(key: "app_name", value: Constants.app_name).localizedFormatted(Fonts.Body.smallRegular),
                inlineImageInfo: {
                    let themeBackgroundColor: ThemeValue = {
                        return switch proState {
                            case .expired: .disabled
                            default: .primary
                        }
                    }()
                    
                    return .init(
                        image: UIView.image(
                            for: .themedKey(
                                SessionProBadge.Size.mini.cacheKey,
                                themeBackgroundColor: themeBackgroundColor
                            ),
                            generator: {
                                SessionProBadge(
                                    size: .mini,
                                    themeBackgroundColor: themeBackgroundColor
                                )
                            }
                        ),
                        position: .leading
                    )
                }()
            )
        ]
    }
    
    public static func plusMoreFeatureInfo(proState: ProState) -> ProFeaturesInfo {
        ProFeaturesInfo(
            icon: Lucide.image(icon: .circlePlus, size: IconSize.medium.size),
            backgroundColors: (proState == .expired) ? [ThemeValue.disabled] : [.explicitPrimary(.orange), .explicitPrimary(.yellow)],
            title: "plusLoadsMore".localized(),
            description: "plusLoadsMoreDescription"
                .put(key: "pro", value: Constants.pro)
                .put(key: "icon", value: Lucide.Icon.squareArrowUpRight)
                .localizedFormatted(Fonts.Body.smallRegular)
        )
    }
}
