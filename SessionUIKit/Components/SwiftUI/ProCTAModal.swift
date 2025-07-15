// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import Lucide

public struct ProCTAModal: View {
    @EnvironmentObject var host: HostWrapper
    
    private var delegate: SessionProCTADelegate?
    private let touchPoint: TouchPoint
    private var dataManager: ImageDataManagerType
    
    let dismissType: Modal.DismissType
    let afterClosed: (() -> Void)?
    
    public init(
        delegate: SessionProCTADelegate?,
        touchPoint: TouchPoint,
        dataManager: ImageDataManagerType,
        dismissType: Modal.DismissType = .recursive,
        afterClosed: (() -> Void)? = nil
    ) {
        self.delegate = delegate
        self.touchPoint = touchPoint
        self.dataManager = dataManager
        self.dismissType = dismissType
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
                    if let animatedAvatarImageURL = touchPoint.animatedAvatarImageURL {
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
                    
                    Image(uiImage: UIImage(named: touchPoint.backgroundImageName) ?? UIImage())
                        .resizable()
                        .aspectRatio((1522.0/1258.0), contentMode: .fit)
                        .frame(maxWidth: .infinity)
                }
                .backgroundColor(themeColor: .primary)
                .overlay(alignment: .bottom, content: {
                    LinearGradient(
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
                    if case .animatedProfileImage(let isSessionProActivated) = touchPoint, isSessionProActivated {
                        HStack(spacing: Values.smallSpacing) {
                            SessionProBadge_SwiftUI(size: .large)
                            
                            Text("proActivated".localized())
                                .font(.system(size: Values.largeFontSize))
                                .bold()
                                .foregroundColor(themeColor: .textPrimary)
                        }
                    } else {
                        HStack(spacing: Values.smallSpacing) {
                            Text("upgradeTo".localized())
                                .font(.system(size: Values.largeFontSize))
                                .bold()
                                .foregroundColor(themeColor: .textPrimary)
                            
                            SessionProBadge_SwiftUI(size: .large)
                        }
                    }
                    
                    // Description, Subtitle
                    VStack(spacing: 0) {
                        if case .animatedProfileImage(let isSessionProActivated) = touchPoint, isSessionProActivated {
                            HStack(spacing: Values.verySmallSpacing) {
                                Text("proAlreadyPurchased".localized())
                                    .font(.system(size: Values.smallFontSize))
                                    .foregroundColor(themeColor: .textSecondary)
                                
                                SessionProBadge_SwiftUI(size: .small)
                            }
                        }
                        
                        Text(touchPoint.subtitle)
                            .font(.system(size: Values.smallFontSize))
                            .foregroundColor(themeColor: .textSecondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    
                    // Benefits
                    if !touchPoint.benefits.isEmpty {
                        VStack(alignment: .leading, spacing: Values.mediumSmallSpacing) {
                            ForEach(
                                0..<touchPoint.benefits.count,
                                id: \.self
                            ) { index in
                                HStack(spacing: Values.smallSpacing) {
                                    if index < touchPoint.benefits.count - 1 {
                                        AttributedText(Lucide.Icon.circleCheck.attributedString(size: 17))
                                            .font(.system(size: 17))
                                            .foregroundColor(themeColor: .primary)
                                    } else {
                                        CyclicGradientView {
                                            AttributedText(Lucide.Icon.sparkles.attributedString(size: 17))
                                                .font(.system(size: 17))
                                        }
                                    }
                                    
                                    Text(touchPoint.benefits[index])
                                        .font(.system(size: Values.smallFontSize))
                                        .foregroundColor(themeColor: .textPrimary)
                                }
                            }
                        }
                    }
                    
                    // Buttons
                    let onlyShowCloseButton: Bool = {
                        if case .groupLimit(let isAdmin) = touchPoint, !isAdmin { return true }
                        if case .animatedProfileImage(let isSessionProActivated) = touchPoint, isSessionProActivated { return true }
                        return false
                    }()
                    
                    if onlyShowCloseButton {
                        GeometryReader { geometry in
                            HStack {
                                Button {
                                    close()
                                } label: {
                                    Text("close".localized())
                                        .font(.system(size: Values.mediumFontSize))
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
                                delegate?.upgradeToPro {
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

// MARK: - Touch Point

public enum TouchPoint {
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
                return "proUserProfileModalCallToAction".localized()
            case .longerMessages:
                return "proCallToActionLongerMessages".localized()
            case .animatedProfileImage(let isSessionProActivated):
                return isSessionProActivated ?
                    "proAnimatedDisplayPicture".localized() :
                    "proAnimatedDisplayPictureCallToActionDescription".localized()
            case .morePinnedConvos(let isGrandfathered):
                return isGrandfathered ?
                    "proCallToActionPinnedConversations".localized() :
                    "proCallToActionPinnedConversationsMoreThan".localized()
            case .groupLimit:
                return "proUserProfileModalCallToAction".localized()
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
            case .animatedProfileImage(let isSessionProActivated):
                return isSessionProActivated ? [] :
                    [
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

// MARK: - SessionProCTADelegate

public protocol SessionProCTADelegate: AnyObject {
    func upgradeToPro(completion: (() -> Void)?)
}
