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
        afterClosed: (() -> Void)?
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
                ZStack {
                    if let animatedAvatarImageName = touchPoint.animatedAvatarImageName {
                        // TODO: Merge SessionAsyncImage
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
                        Text(touchPoint.subtitle)
                            .font(.system(size: Values.smallFontSize))
                            .foregroundColor(themeColor: .textSecondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // Benefits
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
                    // Buttons
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
                                .frame(height: Values.largeButtonHeight)
                                .frame(maxWidth: .infinity)
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
                                .frame(height: Values.largeButtonHeight)
                                .frame(maxWidth: .infinity)
                        }
                        .backgroundColor(themeColor: .inputButton_background)
                        .cornerRadius(6)
                        .clipped()
                        .buttonStyle(PlainButtonStyle())
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
    public var animatedAvatarImageName: String? {
        switch self {
            case .generic: return "GenericCTAAnimation"
            default: return nil
        }
    }

    public var subtitle: String {
        switch self {
            case .generic:
                return "proUserProfileModalCallToAction".localized()
            case .longerMessages:
                return "proCallToActionLongerMessages".localized()
            case .animatedProfileImage:
                return "proAnimatedDisplayPictureCallToActionDescription".localized()
            case .morePinnedConvos(let isGrandfathered):
                return isGrandfathered ?
                    "proCallToActionPinnedConversations".localized() :
                    "proCallToActionPinnedConversationsMoreThan".localized()
            case .groupLimit(let isAdmin):
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

// MARK: - SessionProCTADelegate

public protocol SessionProCTADelegate: AnyObject {
    func upgradeToPro(completion: (() -> Void)?)
}
