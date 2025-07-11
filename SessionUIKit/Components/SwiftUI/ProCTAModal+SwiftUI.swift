// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import Lucide

public struct ProCTAModal_SwiftUI: View {
    @EnvironmentObject var host: HostWrapper
    
    private var delegate: SessionProCTADelegate?
    private let touchPoint: ProCTAModal.TouchPoint
    private var dataManager: ImageDataManagerType
    
    let dismissType: Modal.DismissType
    let afterClosed: (() -> Void)?
    
    public init(
        delegate: SessionProCTADelegate?,
        touchPoint: ProCTAModal.TouchPoint,
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
        Modal_SwiftUI(host: host, dismissType: dismissType, afterClosed: afterClosed) { close in
            VStack(spacing: 0) {
                ZStack {
                    if let animatedAvatarImageName = touchPoint.animatedAvatarImageName {
                        
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
                        ShineButton_SwiftUI {
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
