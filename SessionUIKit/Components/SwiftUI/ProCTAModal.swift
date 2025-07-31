// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import Lucide
import Combine

public struct ProCTAModal: View {
    public enum Variant {
        case generic
        case longerMessages
        case animatedProfileImage(isSessionProActivated: Bool)
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
                    return "AnimatedProfileCTA.webp"
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
                case .animatedProfileImage:
                    return Bundle.main.url(forResource: "AnimatedProfileCTAAnimation", withExtension: "webp")
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
                case .animatedProfileImage(let isSessionProActivated):
                    return isSessionProActivated ?
                        "proAnimatedDisplayPicture".localized() :
                        "proAnimatedDisplayPictureCallToActionDescription"
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
                // Background images
                ZStack {
                    if let animatedAvatarImageURL = variant.animatedAvatarImageURL {
                        SessionAsyncImage(
                            source: .url(animatedAvatarImageURL),
                            dataManager: dataManager,
                            content: { image in
                                image
                                    .resizable()
                                    .aspectRatio((1522.0/1258.0), contentMode: .fit)
                                    .frame(maxWidth: .infinity)
                            },
                            placeholder: {
                                if let data = try? Data(contentsOf: animatedAvatarImageURL) {
                                    Image(uiImage: UIImage(data: data) ?? UIImage())
                                        .resizable()
                                        .aspectRatio((1522.0/1258.0), contentMode: .fit)
                                        .frame(maxWidth: .infinity)
                                } else {
                                    EmptyView()
                                }
                            }
                        )
                    }
                    
                    Image(uiImage: UIImage(named: variant.backgroundImageName) ?? UIImage())
                        .resizable()
                        .aspectRatio((1522.0/1258.0), contentMode: .fit)
                        .frame(maxWidth: .infinity)
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
                // Content
                VStack(spacing: Values.largeSpacing) {
                    // Title
                    if case .animatedProfileImage(let isSessionProActivated) = variant, isSessionProActivated {
                        HStack(spacing: Values.smallSpacing) {
                            SessionProBadge_SwiftUI(size: .large)
                            
                            Text("proActivated".localized())
                                .font(.Headings.H4)
                                .foregroundColor(themeColor: .textPrimary)
                        }
                    } else {
                        HStack(spacing: Values.smallSpacing) {
                            Text("upgradeTo".localized())
                                .font(.Headings.H4)
                                .foregroundColor(themeColor: .textPrimary)
                            
                            SessionProBadge_SwiftUI(size: .large)
                        }
                    }
                    
                    // Description, Subtitle
                    VStack(spacing: 0) {
                        if case .animatedProfileImage(let isSessionProActivated) = variant, isSessionProActivated {
                            HStack(spacing: Values.verySmallSpacing) {
                                Text("proAlreadyPurchased".localized())
                                    .font(.Body.largeRegular)
                                    .foregroundColor(themeColor: .textSecondary)
                                
                                SessionProBadge_SwiftUI(size: .small)
                            }
                        }
                        
                        Text(variant.subtitle)
                            .font(.Body.largeRegular)
                            .foregroundColor(themeColor: .textSecondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    
                    // Benefits
                    if !variant.benefits.isEmpty {
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
                                        .font(.Body.largeRegular)
                                        .foregroundColor(themeColor: .textPrimary)
                                }
                            }
                        }
                    }
                    
                    // Buttons
                    let onlyShowCloseButton: Bool = {
                        if case .groupLimit(let isAdmin) = variant, !isAdmin { return true }
                        if case .animatedProfileImage(let isSessionProActivated) = variant, isSessionProActivated { return true }
                        return false
                    }()
                    
                    if onlyShowCloseButton {
                        GeometryReader { geometry in
                            HStack {
                                Button {
                                    close()
                                } label: {
                                    Text("close".localized())
                                        .font(.Body.baseRegular)
                                        .foregroundColor(themeColor: .textPrimary)
                                }
                                .frame(
                                    width: (geometry.size.width - Values.smallSpacing) / 2,
                                    height: Values.largeButtonHeight
                                )
                                .backgroundColor(themeColor: .inputButton_background)
                                .cornerRadius(6)
                                .clipped()
                                .buttonStyle(PlainButtonStyle())
                            }
                            .frame(
                                width: geometry.size.width,
                                height: geometry.size.height,
                                alignment: .center
                            )
                        }
                        .frame(height: Values.largeButtonHeight)
                    } else {
                        HStack(spacing: Values.smallSpacing) {
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
                                    .font(.Body.baseRegular)
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
                                    .font(.Body.baseRegular)
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
