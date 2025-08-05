// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import Lucide
import Combine

public struct ProCTAModal: View {
    public enum Variant {
        case generic
        case longerMessages
        case animatedProfileImage
        case morePinnedConvos(isGrandfathered: Bool)
        case groupLimit(isAdmin: Bool)

        // stringlint:ignore_contents
        public var backgroundImageName: String {
            switch self {
                case .generic:
                    return "GenericCTA.webp"
                case .longerMessages:
                    return "HigherCharLimitCTA.webp"
                case .animatedProfileImage:
                    return "session_pro_modal_background_animated_profile_image"
                case .morePinnedConvos:
                    return "PinnedConversationsCTA.webp"
                case .groupLimit(let isAdmin):
                    return isAdmin ? "" : ""
            }
        }
        // stringlint:ignore_contents
        public var animatedAvatarImageURL: URL? {
            switch self {
                case .generic:
                    return Bundle.main.url(forResource: "GenericCTAAnimation", withExtension: "webp")
                default: return nil
            }
        }

        public var subtitle: String {
            switch self {
                case .generic:
                    return "proUserProfileModalCallToAction"
                        .put(key: "app_pro", value: Constants.app_pro)
                        .put(key: "app_name", value: Constants.app_name)
                        .localized()
                case .longerMessages:
                    return "proCallToActionLongerMessages"
                        .put(key: "app_pro", value: Constants.app_pro)
                        .localized()
                case .animatedProfileImage:
                    return "proAnimatedDisplayPictureCallToActionDescription"
                        .put(key: "app_pro", value: Constants.app_pro)
                        .localized()
                case .morePinnedConvos(let isGrandfathered):
                    return isGrandfathered ?
                        "proCallToActionPinnedConversations"
                            .put(key: "app_pro", value: Constants.app_pro)
                            .localized() :
                        "proCallToActionPinnedConversationsMoreThan"
                            .put(key: "app_pro", value: Constants.app_pro)
                            .localized()
                case .groupLimit:
                    return "proUserProfileModalCallToAction"
                        .put(key: "app_pro", value: Constants.app_pro)
                        .put(key: "app_name", value: Constants.app_name)
                        .localized()
            }
        }
        
        public var benefits: [String] {
            switch self {
                case .generic:
                    return  [
                        "proFeatureListLargerGroups".localized(),
                        "proFeatureListLongerMessages".localized(),
                        "proFeatureListLoadsMore".localized()
                    ]
                case .longerMessages:
                    return [
                        "proFeatureListLongerMessages".localized(),
                        "proFeatureListLargerGroups".localized(),
                        "proFeatureListLoadsMore".localized()
                    ]
                case .animatedProfileImage:
                    return [
                        "proFeatureListAnimatedDisplayPicture".localized(),
                        "proFeatureListLargerGroups".localized(),
                        "proFeatureListLoadsMore".localized()
                    ]
                case .morePinnedConvos:
                    return [
                        "proFeatureListPinnedConversations".localized(),
                        "proFeatureListLargerGroups".localized(),
                        "proFeatureListLoadsMore".localized()
                    ]
                case .groupLimit(let isAdmin):
                    return !isAdmin ? [] :
                        [
                            "proFeatureListLargerGroups".localized(),
                            "proFeatureListLongerMessages".localized(),
                            "proFeatureListLoadsMore".localized()
                        ]
            }
        }
    }
    
    @EnvironmentObject var host: HostWrapper
    
    private var delegate: SessionProManagerType?
    private let variant: ProCTAModal.Variant
    private var dataManager: ImageDataManagerType
    
    let dismissType: Modal.DismissType
    let afterClosed: (() -> Void)?
    let afterUpgrade: (() -> Void)?
    
    public init(
        delegate: SessionProManagerType?,
        variant: ProCTAModal.Variant,
        dataManager: ImageDataManagerType,
        dismissType: Modal.DismissType = .recursive,
        afterClosed: (() -> Void)? = nil,
        afterUpgrade: (() -> Void)? = nil
    ) {
        self.delegate = delegate
        self.variant = variant
        self.dataManager = dataManager
        self.dismissType = dismissType
        self.afterClosed = afterClosed
        self.afterUpgrade = afterUpgrade
    }
    
    public var body: some View {
        Modal_SwiftUI(
            host: host,
            dismissType: dismissType,
            afterClosed: afterClosed
        ) { close in
            VStack(spacing: 0) {
                ZStack {
                    SessionAsyncImage(
                        source: (
                            variant.animatedAvatarImageURL.map { .url($0) } ??
                            .image(
                                variant.backgroundImageName,
                                UIImage(named: variant.backgroundImageName) ??
                                UIImage()
                            )
                        ),
                        dataManager: dataManager,
                        content: { image in
                            image
                                .resizable()
                                .aspectRatio((1522.0/1258.0), contentMode: .fit)
                                .frame(maxWidth: .infinity)
                        },
                        placeholder: {
                            ThemeColor(.alert_background)
                                .aspectRatio((1522.0/1258.0), contentMode: .fit)
                                .frame(maxWidth: .infinity)
                        }
                    )
                }
                .backgroundColor(themeColor: .primary)
                .overlay(alignment: .bottom, content: {
                    ThemeLinearGradient(
                        themeColors: [
                            .clear,
                            .alert_background
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .framing(
                        maxWidth: .infinity,
                        height: 90
                    )
                })
                .frame(
                    maxWidth: .infinity,
                    alignment: .bottom
                )
            
                VStack(spacing: Values.largeSpacing) {
                    // Title
                    HStack(spacing: Values.smallSpacing) {
                        Text("upgradeTo".localized())
                            .font(.system(size: Values.largeFontSize))
                            .bold()
                            .foregroundColor(themeColor: .textPrimary)
                        
                        SessionProBadge_SwiftUI(size: .large)
                    }
                    // Description, Subtitle
                    VStack(spacing: Values.smallSpacing) {
                        Text(variant.subtitle)
                            .font(.system(size: Values.smallFontSize))
                            .foregroundColor(themeColor: .textSecondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // Benefits
                    VStack(alignment: .leading, spacing: Values.mediumSmallSpacing) {
                        ForEach(
                            0..<variant.benefits.count,
                            id: \.self
                        ) { index in
                            HStack(spacing: Values.smallSpacing) {
                                if index < variant.benefits.count - 1 {
                                    AttributedText(Lucide.Icon.circleCheck.attributedString(size: 17))
                                        .font(.system(size: 17))
                                        .foregroundColor(themeColor: .primary)
                                } else {
                                    CyclicGradientView {
                                        AttributedText(Lucide.Icon.sparkles.attributedString(size: 17))
                                            .font(.system(size: 17))
                                    }
                                }
                                
                                Text(variant.benefits[index])
                                    .font(.system(size: Values.smallFontSize))
                                    .foregroundColor(themeColor: .textPrimary)
                            }
                        }
                    }
                    // Buttons
                    HStack(spacing: Values.smallSpacing) {
                        if case .groupLimit(let isAdmin) = variant, !isAdmin {
                            Button {
                                close()
                            } label: {
                                GeometryReader { geometry in
                                    Text("close".localized())
                                        .font(.system(size: Values.mediumFontSize))
                                        .foregroundColor(themeColor: .textPrimary)
                                        .frame(
                                            width: (geometry.size.width - Values.smallSpacing) / 2,
                                            height: Values.largeButtonHeight
                                        )
                                }
                                .frame(height: Values.largeButtonHeight)
                            }
                            .backgroundColor(themeColor: .inputButton_background)
                            .cornerRadius(6)
                            .clipped()
                            .buttonStyle(PlainButtonStyle())
                        } else {
                            // Upgrade Button
                            ShineButton {
                                delegate?.upgradeToPro { result in
                                    if result {
                                        afterUpgrade?()
                                    }
                                    close()
                                }
                            } label: {
                                Text("theContinue".localized())
                                    .font(.system(size: Values.mediumFontSize))
                                    .foregroundColor(themeColor: .sessionButton_primaryFilledText)
                                    .framing(
                                        maxWidth: .infinity,
                                        height: Values.largeButtonHeight
                                    )
                            }
                            .frame(height: Values.largeButtonHeight)
                            .backgroundColor(themeColor: .sessionButton_primaryFilledBackground)
                            .cornerRadius(6)
                            .clipped()
                            .buttonStyle(PlainButtonStyle()) // prevents default blue highlight

                            // Cancel Button
                            Button {
                                close()
                            } label: {
                                Text("cancel".localized())
                                    .font(.system(size: Values.mediumFontSize))
                                    .foregroundColor(themeColor: .textPrimary)
                                    .framing(
                                        maxWidth: .infinity,
                                        height: Values.largeButtonHeight
                                    )
                            }
                            .backgroundColor(themeColor: .inputButton_background)
                            .cornerRadius(6)
                            .clipped()
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                }
                .padding(Values.mediumSpacing)
            }
        }
    }
}

// MARK: - SessionProManagerType

public protocol SessionProManagerType: AnyObject {
    var isSessionProPublisher: AnyPublisher<Bool, Never> { get }
    func upgradeToPro(completion: ((_ result: Bool) -> Void)?)
}

struct ProCTAModal_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            PreviewThemeWrapper(theme: .classicDark) {
                ProCTAModal(
                    delegate: nil,
                    variant: .generic,
                    dataManager: ImageDataManager(),
                    dismissType: .single,
                    afterClosed: nil
                )
                .environmentObject(HostWrapper())
                .previewDisplayName("Classic Dark")
            }
            
            PreviewThemeWrapper(theme: .classicLight) {
                ProCTAModal(
                    delegate: nil,
                    variant: .generic,
                    dataManager: ImageDataManager(),
                    dismissType: .single,
                    afterClosed: nil
                )
                .environmentObject(HostWrapper())
                .previewDisplayName("Classic Light")
            }
            
            PreviewThemeWrapper(theme: .oceanDark) {
                ProCTAModal(
                    delegate: nil,
                    variant: .generic,
                    dataManager: ImageDataManager(),
                    dismissType: .single,
                    afterClosed: nil
                )
                .environmentObject(HostWrapper())
                .previewDisplayName("Ocean Dark")
            }
            
            PreviewThemeWrapper(theme: .oceanLight) {
                ProCTAModal(
                    delegate: nil,
                    variant: .generic,
                    dataManager: ImageDataManager(),
                    dismissType: .single,
                    afterClosed: nil
                )
                .environmentObject(HostWrapper())
                .previewDisplayName("Ocean Light")
            }
        }
    }
}
