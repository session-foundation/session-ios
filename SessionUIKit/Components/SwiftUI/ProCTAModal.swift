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
        case groupLimit(isAdmin: Bool, isSessionProActivated: Bool, proBadgeImage: UIImage)
        case expiring(timeLeft: String?)
    }
    
    @EnvironmentObject var host: HostWrapper
    @State var proCTAImageHeight: CGFloat = 0
    
    private let variant: ProCTAModal.Variant
    private let dataManager: ImageDataManagerType
    private let sessionProUIManager: SessionProUIManagerType
    
    let dismissType: Modal.DismissType
    let onConfirm: (() -> Void)?
    let onCancel: (() -> Void)?
    let afterClosed: (() -> Void)?
    
    public init(
        variant: ProCTAModal.Variant,
        dataManager: ImageDataManagerType,
        sessionProUIManager: SessionProUIManagerType,
        dismissType: Modal.DismissType = .recursive,
        onConfirm: (() -> Void)? = nil,
        onCancel: (() -> Void)? = nil,
        afterClosed: (() -> Void)? = nil
    ) {
        self.variant = variant
        self.dataManager = dataManager
        self.sessionProUIManager = sessionProUIManager
        self.dismissType = dismissType
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        self.afterClosed = afterClosed
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
                            let size: CGFloat = geometry.size.width / 1522.0 * 135
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
                    switch variant {
                        case .animatedProfileImage(let isSessionProActivated) where isSessionProActivated:
                            HStack(spacing: Values.smallSpacing) {
                                SessionProBadge_SwiftUI(size: .large)

                                Text("proActivated".localized())
                                    .font(.Headings.H4)
                                    .foregroundColor(themeColor: .textPrimary)
                            }

                        case .groupLimit(_, let isSessionProActivated, _) where isSessionProActivated:
                            HStack(spacing: Values.smallSpacing) {
                                SessionProBadge_SwiftUI(size: .large)
                                
                                Text("proGroupActivated".localized())
                                    .font(.Headings.H4)
                                    .foregroundColor(themeColor: .textPrimary)
                            }

                        case .expiring(let timeLeft):
                            let isExpired: Bool = (timeLeft?.isEmpty != false)
                            HStack(spacing: Values.smallSpacing) {
                                SessionProBadge_SwiftUI(
                                    size: .large,
                                    themeBackgroundColor: variant.themeColor
                                )
                                
                                Text(isExpired ? "proExpired".localized() : "proExpiringSoon".localized())
                                    .font(.Headings.H4)
                                    .foregroundColor(themeColor: isExpired ? .disabled : .textPrimary)
                            }

                        default:
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
                            case .groupLimit(_, let isSessionProActivated, let proBadgeImage) = variant,
                            isSessionProActivated
                        {
                            (Text(variant.subtitle(sessionProUIManager: sessionProUIManager).string) + Text(" \(Image(uiImage: proBadgeImage))"))
                                .font(.Body.largeRegular)
                                .foregroundColor(themeColor: .textSecondary)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            AttributedText(variant.subtitle(sessionProUIManager: sessionProUIManager))
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
                                    if case .loadsMore = variant.benefits[index] {
                                        CyclicGradientView {
                                            AttributedText(Lucide.Icon.sparkles.attributedString(size: 17))
                                                .font(.system(size: 17))
                                        }
                                    } else {
                                        AttributedText(Lucide.Icon.circleCheck.attributedString(size: 17))
                                            .font(.system(size: 17))
                                            .foregroundColor(themeColor: .primary)
                                    }
                                    
                                    Text(variant.benefits[index].description)
                                        .font(.Body.largeRegular)
                                        .foregroundColor(themeColor: .textPrimary)
                                        .fixedSize(horizontal: false, vertical: true)
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
                                onCancel?()
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

// MARK: - ProCTAModal.Benefits

public extension ProCTAModal {
    enum Benefits: Equatable {
        case largerGroups
        case longerMessages
        case animatedProfileImage
        case morePinnedConvos
        case loadsMore
        
        var description: String {
            return switch self {
                case .largerGroups: "proFeatureListLargerGroups".localized()
                case .longerMessages: "proFeatureListLongerMessages".localized()
                case .animatedProfileImage: "proFeatureListAnimatedDisplayPicture".localized()
                case .morePinnedConvos: "proFeatureListPinnedConversations".localized()
                case .loadsMore: "proFeatureListLoadsMore".localized()
            }
        }
    }
}

// MARK: - Variant Content

public extension ProCTAModal.Variant {
    // stringlint:ignore_contents
    var backgroundImageName: String {
        switch self {
            case .generic, .expiring: return "GenericCTA.webp"
            case .longerMessages: return "HigherCharLimitCTA.webp"
            case .animatedProfileImage: return "AnimatedProfileCTA.webp"
            case .morePinnedConvos: return "PinnedConversationsCTA.webp"
            case .groupLimit(false, false, _): return "GroupNonAdminCTA.webp"
            case .groupLimit: return "GroupAdminCTA.webp"
        }
    }
    
    var themeColor: ThemeValue {
        switch self {
            case .expiring(let timeLeft): return (timeLeft?.isEmpty == false ? .primary : .disabled)
            default: return .primary
        }
    }
    
    // stringlint:ignore_contents
    var animatedAvatarImageURL: URL? {
        switch self {
            case .generic, .animatedProfileImage:
                return Bundle.main.url(forResource: "AnimatedProfileCTAAnimationCropped", withExtension: "webp")
            default: return nil
        }
    }
    
    /// Note: This is a hack to manually position the animated avatar in the CTA background image to prevent heavy loading for the
    /// animated webp. These coordinates are based on the full size image and get scaled during rendering based on the actual size
    /// of the modal.
    var animatedAvatarImagePadding: (leading: CGFloat, top: CGFloat) {
        switch self {
            case .generic: return (1293, 743)
            case .animatedProfileImage: return (690, 363)
            default: return (0, 0)
        }
    }

    func subtitle(sessionProUIManager: SessionProUIManagerType) -> ThemedAttributedString {
        switch self {
            case .generic:
                return "proUserProfileModalCallToAction"
                    .put(key: "app_pro", value: Constants.app_pro)
                    .put(key: "app_name", value: Constants.app_name)
                    .localizedFormatted()
            
            case .longerMessages:
                return "proCallToActionLongerMessages"
                    .put(key: "app_pro", value: Constants.app_pro)
                    .localizedFormatted()
            
            case .animatedProfileImage(isSessionProActivated: true):
                return "proAnimatedDisplayPicture"
                    .localizedFormatted(baseFont: .systemFont(ofSize: 14))
                
            case .animatedProfileImage(isSessionProActivated: false):
                return "proAnimatedDisplayPictureCallToActionDescription"
                    .put(key: "app_pro", value: Constants.app_pro)
                    .localizedFormatted()
            
            case .morePinnedConvos(isGrandfathered: true):
                return "proCallToActionPinnedConversations"
                    .put(key: "app_pro", value: Constants.app_pro)
                    .localizedFormatted()
                
            case .morePinnedConvos(isGrandfathered: false):
                return "proCallToActionPinnedConversationsMoreThan"
                    .put(key: "app_pro", value: Constants.app_pro)
                    .put(key: "limit", value: sessionProUIManager.pinnedConversationLimit)
                    .localizedFormatted()
            
            case .groupLimit(_, isSessionProActivated: true, _):
                return "proGroupActivatedDescription"
                    .localizedFormatted(baseFont: .systemFont(ofSize: 14))
            
            case .groupLimit(isAdmin: true, isSessionProActivated: false, _):
                return "proUserProfileModalCallToAction"
                    .put(key: "app_pro", value: Constants.app_pro)
                    .put(key: "app_name", value: Constants.app_name)
                    .localizedFormatted()
                
            case .groupLimit(isAdmin: false, isSessionProActivated: false, _):
                // TODO: [PRO] Localised
                return ThemedAttributedString(
                    string: "Want to upgrade this group to Pro? Tell one of the group admins to upgrade to Pro"
                )
            
            case .expiring(let timeLeft) where timeLeft?.isEmpty == false:
                return "proExpiringSoonDescription"
                    .put(key: "pro", value: Constants.pro)
                    .put(key: "time", value: timeLeft ?? "")
                    .put(key: "app_pro", value: Constants.app_pro)
                    .localizedFormatted()
                
            case .expiring:
                return "proExpiredDescription"
                    .put(key: "pro", value: Constants.pro)
                    .put(key: "app_pro", value: Constants.app_pro)
                    .localizedFormatted()
        }
    }
    
    var benefits: [ProCTAModal.Benefits] {
        switch self {
            case .generic: return [ .largerGroups, .longerMessages, .loadsMore ]
            case .longerMessages: return [ .longerMessages, .morePinnedConvos, .loadsMore ]
            case .animatedProfileImage: return [ .animatedProfileImage, .largerGroups, .loadsMore ]
            case .morePinnedConvos: return [ .morePinnedConvos, .largerGroups, .loadsMore ]
            case .groupLimit(isAdmin: true, isSessionProActivated: false, _):
                return [ .largerGroups, .longerMessages, .loadsMore ]
                
            case .groupLimit: return []
            case .expiring: return [ .longerMessages, .morePinnedConvos, .animatedProfileImage ]
        }
    }
    
    var confirmButtonTitle: String {
        switch self {
            case .expiring(let timeLeft) where timeLeft?.isEmpty == false: return "update".localized()
            case .expiring: return "renew".localized()
            default: return "theContinue".localized()
        }
    }
    
    var cancelButtonTitle: String {
        guard !self.onlyShowCloseButton else {
            return "close".localized()
        }
        
        switch self {
            case .expiring(let timeLeft) where timeLeft?.isEmpty == false: return "close".localized()
            case .expiring: return "cancel".localized()
            default: return "cancel".localized()
        }
    }
    
    var onlyShowCloseButton: Bool {
        switch self {
            case .animatedProfileImage(let isSessionProActivated): return isSessionProActivated
            case .groupLimit(let isAdmin, let isSessionProActivated, _): return (!isAdmin || isSessionProActivated)
            default: return false
        }
    }
}

// MARK: - Previews

struct ProCTAModal_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            PreviewThemeWrapper(theme: .classicDark) {
                ProCTAModal(
                    variant: .generic,
                    dataManager: ImageDataManager(),
                    sessionProUIManager: NoopSessionProUIManager(),
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
                    sessionProUIManager: NoopSessionProUIManager(),
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
                    sessionProUIManager: NoopSessionProUIManager(),
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
                    sessionProUIManager: NoopSessionProUIManager(),
                    dismissType: .single,
                    afterClosed: nil
                )
                .environmentObject(HostWrapper())
                .previewDisplayName("Ocean Light")
            }
        }
    }
}
