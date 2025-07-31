// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import Lucide
import Combine

public struct UserProfileModel: View {
    @EnvironmentObject var host: HostWrapper
    @State private var isProfileImageToggled: Bool = true
    @State private var isProfileImageExpanding: Bool = false
    @State private var isSessionIdCopied: Bool = false
    @State private var isShowingTooltip: Bool = false
    @State private var tooltipContentFrame: CGRect = CGRect.zero
    
    private let tooltipViewId: String = "UserProfileModelToolTip" // stringlint:ignore
    private let coordinateSpaceName: String = "UserProfileModel" // stringlint:ignore
    
    private var info: Info
    private var dataManager: ImageDataManagerType
    private var sessionProState: SessionProManagerType
    let dismissType: Modal.DismissType
    let afterClosed: (() -> Void)?
    
    // TODO: Localised
    private var tooltipText: String {
        if info.sessionId == nil {
            return "Blinded IDs are used in communities to reduce spam and increase privacy"
        } else {
            return "The Account ID of {name} is visible based on your previous interactions"
        }
    }
    
    public init(
        info: Info,
        dataManager: ImageDataManagerType,
        sessionProState: SessionProManagerType,
        dismissType: Modal.DismissType = .recursive,
        afterClosed: (() -> Void)? = nil
    ) {
        self.info = info
        self.dataManager = dataManager
        self.sessionProState = sessionProState
        self.dismissType = dismissType
        self.afterClosed = afterClosed
    }
    
    public var body: some View {
        Modal_SwiftUI(
            host: host,
            dismissType: dismissType,
            afterClosed: afterClosed
        ) { close in
            ZStack(alignment: .topTrailing) {
                // Closed button
                Button {
                    close()
                } label: {
                    AttributedText(Lucide.Icon.x.attributedString(size: 12))
                        .font(.system(size: 12))
                        .foregroundColor(themeColor: .textPrimary)
                }
                .frame(width: 24, height: 24)
                .padding(8)
                
                VStack(spacing: 0) {
                    // Profile Image & QR Code
                    if isProfileImageToggled {
                        ZStack(alignment: .topTrailing) {
                            ProfilePictureSwiftUI(
                                size: .hero,
                                info: info.profileInfo,
                                dataManager: self.dataManager,
                                sessionProState: self.sessionProState
                            )
                            .frame(
                                width: ProfilePictureView.Size.hero.viewSize,
                                height: ProfilePictureView.Size.hero.viewSize,
                                alignment: .center
                            )
                            
                            if let sessionId = info.sessionId {
                                Button {
                                    withAnimation {
                                        self.isProfileImageToggled.toggle()
                                    }
                                } label: {
                                    AttributedText(Lucide.Icon.qrCode.attributedString(size: 12))
                                        .font(.system(size: 12))
                                        .foregroundColor(themeColor: .black)
                                        .background(
                                            Circle()
                                                .foregroundColor(themeColor: .primary)
                                                .frame(width: 20, height: 20)
                                        )
                                }
                            }
                        }
                        .scaleEffect(isProfileImageExpanding ? 2 : 1)
                    } else {
                        ZStack(alignment: .topTrailing) {
                            if let sessionId = info.sessionId {
                                QRCodeView(
                                    string: sessionId,
                                    hasBackground: false,
                                    logo: "SessionWhite40", // stringlint:ignore
                                    themeStyle: ThemeManager.currentTheme.interfaceStyle
                                )
                                .accessibility(
                                    Accessibility(
                                        identifier: "QR code",
                                        label: "QR code"
                                    )
                                )
                                .aspectRatio(1, contentMode: .fit)
                                .frame(width: 190, height: 190)
                                .padding(.top, 10)
                                .padding(.trailing, 17)
                                .onTapGesture {
                                    withAnimation {
                                        self.isProfileImageExpanding.toggle()
                                    }
                                }
                                
                                Button {
                                    withAnimation {
                                        self.isProfileImageToggled.toggle()
                                    }
                                } label: {
                                    Image("ic_user_round_fill")
                                        .resizable()
                                        .renderingMode(.template)
                                        .scaledToFit()
                                        .foregroundColor(themeColor: .black)
                                        .frame(width: 18, height: 18)
                                        .background(
                                            Circle()
                                                .foregroundColor(themeColor: .primary)
                                                .frame(width: 33, height: 33)
                                        )
                                }
                            }
                        }
                    }
                    
                    // Display name & Nickname (ProBadge)
                    HStack(spacing: Values.smallSpacing) {
                        Text(info.displayName)
                            .font(.Headings.H6)
                            .foregroundColor(themeColor: .textPrimary)
                        
                        if info.isProUser {
                            SessionProBadge_SwiftUI(size: .large)
                        }
                    }
                    
                    // Account Id | Blinded Id (Tooltips)
                    let (title, hexEncodedId): (String, String) = {
                        switch (info.sessionId, info.blindedId) {
                            case (.some(let sessionId), _): return ("accountId".localized(), sessionId)
                            case (.none, .some(let blindedId)): return ("blindedId".localized(), blindedId)
                            default : return ("", "") // Shouldn't happen
                        }
                    }()
                    
                    Seperator_SwiftUI(title: title)
                    
                    ZStack(alignment: .top) {
                        if info.blindedId != nil {
                            HStack {
                                Spacer()
                                
                                Button {
                                    withAnimation {
                                        isShowingTooltip.toggle()
                                    }
                                } label: {
                                    Image(systemName: "questionmark.circle")
                                        .font(.Body.extraLargeRegular)
                                        .foregroundColor(themeColor: .textPrimary)
                                }
                                .anchorView(viewId: tooltipViewId)
                            }
                        }
                        
                        Text(hexEncodedId)
                            .font(isIPhone5OrSmaller ? .Display.base : .Display.large)
                            .foregroundColor(themeColor: .textPrimary)
                    }
                    
                    // Buttons
                    if let sessionId = info.sessionId {
                        HStack(spacing: Values.mediumSpacing) {
                            Button {
                                info.onStartThread?(sessionId, info.openGroupServer, info.openGroupPublicKey)
                            } label: {
                                Text("message".localized())
                                    .font(.Body.baseBold)
                                    .foregroundColor(themeColor: .sessionButton_text)
                            }
                            .framing(
                                maxWidth: .infinity,
                                height: Values.smallButtonHeight
                            )
                            .overlay(
                                Capsule()
                                    .stroke(themeColor: .sessionButton_border)
                            )
                            .buttonStyle(PlainButtonStyle())
                            
                            Button {
                                copySessionId()
                            } label: {
                                Text(isSessionIdCopied ? "copied".localized() : "copy".localized())
                                    .font(.Body.baseBold)
                                    .foregroundColor(themeColor: .sessionButton_text)
                            }
                            .disabled(isSessionIdCopied)
                            .framing(
                                maxWidth: .infinity,
                                height: Values.smallButtonHeight
                            )
                            .overlay(
                                Capsule()
                                    .stroke(themeColor: .sessionButton_border)
                            )
                            .buttonStyle(PlainButtonStyle())
                        }
                    } else {
                        let isMessageButtonEnabled: Bool = (info.onStartThread != nil)
                        
                        if !isMessageButtonEnabled {
                            AttributedText("messageRequestsTurnedOff"
                                .put(key: "name", value: info.displayName)
                                .localizedFormatted(Fonts.Body.smallRegular)
                            )
                            .font(.Body.smallRegular)
                            .foregroundColor(themeColor: .textSecondary)
                        }
                        
                        GeometryReader { geometry in
                            HStack {
                                Button {
                                    if let blindedId = info.blindedId {
                                        info.onStartThread?(blindedId, info.openGroupServer, info.openGroupPublicKey)
                                    }
                                } label: {
                                    Text("message".localized())
                                        .font(.system(size: Values.mediumFontSize))
                                        .foregroundColor(themeColor: (isMessageButtonEnabled ? .sessionButton_text : .disabled))
                                }
                                .disabled(!isMessageButtonEnabled)
                                .frame(
                                    width: (geometry.size.width - Values.mediumSpacing) / 2,
                                    height: Values.smallButtonHeight
                                )
                                .overlay(
                                    Capsule()
                                        .stroke(themeColor: (isMessageButtonEnabled ? .sessionButton_border : .disabled))
                                )
                                .buttonStyle(PlainButtonStyle())
                            }
                            .frame(
                                width: geometry.size.width,
                                height: geometry.size.height,
                                alignment: .center
                            )
                        }
                        .frame(height: Values.largeButtonHeight)
                    }
                }
            }
            .padding(Values.mediumSpacing)
            .popoverView(
                content: {
                    ZStack {
                        Text(tooltipText)
                            .font(.Body.smallRegular)
                            .multilineTextAlignment(.center)
                            .foregroundColor(themeColor: .textPrimary)
                            .padding(.horizontal, Values.mediumSpacing)
                            .padding(.vertical, Values.smallSpacing)
                    }
                    .overlay(
                        GeometryReader { geometry in
                            Color.clear // Invisible overlay
                                .onAppear {
                                    self.tooltipContentFrame = geometry.frame(in: .global)
                                }
                        }
                    )
                },
                backgroundThemeColor: .toast_background,
                isPresented: $isShowingTooltip,
                frame: $tooltipContentFrame,
                position: .top,
                viewId: tooltipViewId
            )
        }
        .onAnyInteraction(scrollCoordinateSpaceName: coordinateSpaceName) {
            guard self.isShowingTooltip else {
                return
            }
            
            withAnimation(.spring()) {
                self.isShowingTooltip = false
            }
        }
    }
    
    private func copySessionId() {
        UIPasteboard.general.string = info.sessionId
        
        // Ensure we are on the main thread just in case
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.25)) {
                isSessionIdCopied.toggle()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(4250)) {
                withAnimation(.easeInOut(duration: 0.25)) {
                    isSessionIdCopied.toggle()
                }
            }
        }
    }
}

public extension UserProfileModel {
    struct Info {
        let sessionId: String?
        let blindedId: String?
        let profileInfo: ProfilePictureView.Info
        let displayName: String
        let nickname: String?
        let isProUser: Bool
        let openGroupServer: String?
        let openGroupPublicKey: String?
        let onStartThread: ((String, String?, String?) -> Void)?
        
        public init(
            sessionId: String?,
            blindedId: String?,
            profileInfo: ProfilePictureView.Info,
            displayName: String,
            nickname: String?,
            isProUser: Bool,
            openGroupServer: String?,
            openGroupPublicKey: String?,
            onStartThread: ((String, String?, String?) -> Void)?
        ) {
            self.sessionId = sessionId
            self.blindedId = blindedId
            self.profileInfo = profileInfo
            self.displayName = displayName
            self.nickname = nickname
            self.isProUser = isProUser
            self.openGroupServer = openGroupServer
            self.openGroupPublicKey = openGroupPublicKey
            self.onStartThread = onStartThread
        }
    }
}
