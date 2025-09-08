// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import Lucide
import Combine
import SessionUtilitiesKit

public struct ProCTAModal: View {
    public enum Variant {
        case generic
        case longerMessages
        case animatedProfileImage(isSessionProActivated: Bool)
        case morePinnedConvos(isGrandfathered: Bool)
        case groupLimit(isAdmin: Bool, isSessionProActivated: Bool)
        case expiring(timeLeft: TimeInterval)

        // stringlint:ignore_contents
        public var backgroundImageName: String {
            switch self {
                case .generic, .expiring:
                    return "GenericCTA.webp"
                case .longerMessages:
                    return "HigherCharLimitCTA.webp"
                case .animatedProfileImage:
                    return "AnimatedProfileCTA.webp"
                case .morePinnedConvos:
                    return "PinnedConversationsCTA.webp"
                case .groupLimit(let isAdmin, let isSessionProActivated):
                    switch (isAdmin, isSessionProActivated) {
                        case (false, false):
                            return "GroupNonAdminCTA.webp"
                        default:
                            return "GroupAdminCTA.webp"
                    }
            }
        }
        
        public var themeColor: ThemeValue {
            switch self {
                case .expiring(let timeLeft): return timeLeft > 0 ? .primary : .disabled
                default: return .primary
            }
        }
        
        // stringlint:ignore_contents
        public var animatedAvatarImageURL: URL? {
            switch self {
                case .generic, .animatedProfileImage:
                    return Bundle.main.url(forResource: "AnimatedProfileCTAAnimationCropped", withExtension: "webp")
                default: return nil
            }
        }
        /// Note: This is a hack to manually position the animated avatar in the CTA background image to prevent heavy loading for the
        /// animated webp. These coordinates are based on the full size image and get scaled during rendering based on the actual size
        /// of the modal.
        public var animatedAvatarImagePadding: (leading: CGFloat, top: CGFloat) {
            switch self {
                case .generic:
                return (1313.5, 753)
                case .animatedProfileImage:
                return (690, 363)
                default: return (0, 0)
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
                case .groupLimit(let isAdmin, let isSessionProActivated):
                    switch (isAdmin, isSessionProActivated) {
                        case (_, true):
                            return "proGroupActivatedDescription".localized()
                        case (true, false):
                            return "proUserProfileModalCallToAction"
                                .put(key: "app_pro", value: Constants.app_pro)
                                .put(key: "app_name", value: Constants.app_name)
                                .localized()
                        case (false, false):
                            return "Want to upgrade this group to Pro? Tell one of the group admins to upgrade to Pro" // TODO: Localised
                    }
                case .expiring(let timeLeft):
                    return timeLeft > 0 ?
                        "proExpiringSoonDescription"
                            .put(key: "pro", value: Constants.pro)
                            .put(key: "time", value: timeLeft.formatted(format: .long))
                            .put(key: "app_pro", value: Constants.app_pro)
                            .localized() :
                        "proExpiredDescription"
                            .put(key: "pro", value: Constants.pro)
                            .put(key: "app_pro", value: Constants.app_pro)
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
                case .groupLimit(let isAdmin, let isSessionProActivated):
                    switch (isAdmin, isSessionProActivated) {
                        case (true, false):
                            return [
                                "proFeatureListLargerGroups".localized(),
                                "proFeatureListLongerMessages".localized(),
                                "proFeatureListLoadsMore".localized()
                            ]
                        default: return []
                    }
                case .expiring:
                    return [
                        "proFeatureListLargerGroups".localized(),
                        "proFeatureListLongerMessages".localized(),
                        "proFeatureListPinnedConversations".localized()
                    ]
            }
        }
        
        public var confirmButtonTitle: String {
            switch self {
                case .expiring(let timeLeft):
                    return timeLeft > 0 ? "updatePlan".localized() : "renew".localized()
                default: return "theContinue".localized()
            }
        }
        
        public var cancelButtonTitle: String {
            guard !self.onlyShowCloseButton else {
                return "close".localized()
            }
            
            switch self {
                case .expiring(let timeLeft):
                    return timeLeft > 0 ? "close".localized() : "cancel".localized()
                default: return "cancel".localized()
            }
        }
        
        public var onlyShowCloseButton: Bool {
            switch self {
                case .animatedProfileImage(let isSessionProActivated):
                    return isSessionProActivated
                case .groupLimit(let isAdmin, let isSessionProActivated):
                    return (!isAdmin || isSessionProActivated)
                default:
                    return false
            }
        }
    }
    
    @EnvironmentObject var host: HostWrapper
    @State var proCTAImageHeight: CGFloat = 0
    
    private let variant: ProCTAModal.Variant
    private var dataManager: ImageDataManagerType
    
    let dismissType: Modal.DismissType
    let afterClosed: (() -> Void)?
    let onConfirm: (() -> Void)?
    
    public init(
        variant: ProCTAModal.Variant,
        dataManager: ImageDataManagerType,
        dismissType: Modal.DismissType = .recursive,
        afterClosed: (() -> Void)? = nil,
        onConfirm: (() -> Void)? = nil
    
    ) {
        self.variant = variant
        self.dataManager = dataManager
        self.dismissType = dismissType
        self.afterClosed = afterClosed
        self.onConfirm = onConfirm
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
                        GeometryReader { geometry in
                            let size: CGFloat = geometry.size.width / 1522.0 * 187.0
                            let scale: CGFloat = geometry.size.width / 1522.0
                            SessionAsyncImage(
                                source: .url(animatedAvatarImageURL),
                                dataManager: dataManager,
                                content: { image in
                                    image
                                        .resizable()
                                        .aspectRatio(1, contentMode: .fit)
                                        .frame(width: size, height: size)
                                },
                                placeholder: {
                                    if let data = try? Data(contentsOf: animatedAvatarImageURL) {
                                        Image(uiImage: UIImage(data: data) ?? UIImage())
                                            .resizable()
                                            .aspectRatio(1, contentMode: .fit)
                                            .frame(width: size, height: size)
                                    } else {
                                        EmptyView()
                                    }
                                }
                            )
                            .padding(.leading, variant.animatedAvatarImagePadding.leading * scale)
                            .padding(.top, variant.animatedAvatarImagePadding.top * scale)
                            .onAppear {
                                proCTAImageHeight = geometry.size.width / 1522.0 * 1258.0
                            }
                        }
                        .frame(height: proCTAImageHeight)
                    }
                    
                    Image(uiImage: UIImage(named: variant.backgroundImageName) ?? UIImage())
                        .resizable()
                        .aspectRatio((1522.0/1258.0), contentMode: .fit)
                        .frame(maxWidth: .infinity)
                }
                .backgroundColor(themeColor: variant.themeColor)
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
                    } else if case .groupLimit(_, let isSessionProActivated) = variant, isSessionProActivated {
                        HStack(spacing: Values.smallSpacing) {
                            SessionProBadge_SwiftUI(size: .large)
                            
                            Text("proGroupActivated".localized())
                                .font(.Headings.H4)
                                .foregroundColor(themeColor: .textPrimary)
                        }
                    } else if case .expiring(let timeLeft) = variant {
                        let isExpired: Bool = (timeLeft <= 0)
                        HStack(spacing: Values.smallSpacing) {
                            SessionProBadge_SwiftUI(
                                size: .large,
                                themeBackgroundColor: variant.themeColor
                            )
                            
                            Text(isExpired ? "proExpired".localized() : "proExpiringSoon".localized())
                                .font(.Headings.H4)
                                .foregroundColor(themeColor: isExpired ? .disabled : .textPrimary)
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
                                
                                SessionProBadge_SwiftUI(size: .medium)
                            }
                        }
                        
                        if
                            case .groupLimit(_, let isSessionProActivated) = variant, isSessionProActivated,
                            let proBadgeImage: UIImage = SessionProBadge(size: .small).toImage()
                        {
                            (Text(variant.subtitle) + Text(" \(Image(uiImage: proBadgeImage))").baselineOffset(-2))
                                .font(.Body.largeRegular)
                                .foregroundColor(themeColor: .textSecondary)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text(variant.subtitle)
                                .font(.Body.largeRegular)
                                .foregroundColor(themeColor: .textSecondary)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
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
                    if variant.onlyShowCloseButton {
                        GeometryReader { geometry in
                            HStack {
                                Button {
                                    close(nil)
                                } label: {
                                    Text(variant.confirmButtonTitle)
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
                                onConfirm?()
                                close(nil)
                            } label: {
                                Text(variant.confirmButtonTitle)
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
                                close(nil)
                            } label: {
                                Text(variant.cancelButtonTitle)
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
    var isSessionProSubject: CurrentValueSubject<Bool, Never> { get }
    var isSessionProPublisher: AnyPublisher<Bool, Never> { get }
    func upgradeToPro(completion: ((_ result: Bool) -> Void)?)
}

struct ProCTAModal_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            PreviewThemeWrapper(theme: .classicDark) {
                ProCTAModal(
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
