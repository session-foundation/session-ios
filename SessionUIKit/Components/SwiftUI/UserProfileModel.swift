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
    
    private var tooltipText: ThemedAttributedString {
        if info.sessionId == nil {
            return "tooltipBlindedIdCommunities"
                .localizedFormatted(baseFont: Fonts.Body.smallRegular)
        } else {
            return "tooltipAccountIdVisible"
                .put(key: "name", value: info.displayName)
                .localizedFormatted(baseFont: Fonts.Body.smallRegular)
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
                    close(nil)
                } label: {
                    AttributedText(Lucide.Icon.x.attributedString(size: 20))
                        .font(.system(size: 20))
                        .foregroundColor(themeColor: .textPrimary)
                }
                .frame(width: 24, height: 24)
                
                VStack(spacing: Values.mediumSpacing) {
                    // Profile Image & QR Code
                    let scale: CGFloat = isProfileImageExpanding ? (190.0 / 90) : 1
                    if isProfileImageToggled {
                        ZStack(alignment: .topTrailing) {
                            ZStack {
                                ProfilePictureSwiftUI(
                                    size: .userProfileModal,
                                    info: info.profileInfo,
                                    dataManager: self.dataManager,
                                    sessionProState: self.sessionProState
                                )
                                .scaleEffect(scale, anchor: .topLeading)
                            }
                            .frame(
                                width: ProfilePictureView.Size.userProfileModal.viewSize * scale,
                                height: ProfilePictureView.Size.userProfileModal.viewSize * scale,
                                alignment: .center
                            )
                            
                            if info.sessionId != nil {
                                let (buttonSize, iconSize): (CGFloat, CGFloat) = isProfileImageExpanding ? (33, 20) : (20, 12)
                                Button {
                                    withAnimation {
                                        self.isProfileImageToggled.toggle()
                                    }
                                } label: {
                                    AttributedText(Lucide.Icon.qrCode.attributedString(size: iconSize, baselineOffset: 0))
                                        .font(.system(size: iconSize))
                                        .foregroundColor(themeColor: .black)
                                        .background(
                                            Circle()
                                                .foregroundColor(themeColor: .primary)
                                                .frame(width: buttonSize, height: buttonSize)
                                        )
                                }
                                .padding(.trailing, isProfileImageExpanding ? 28 : 4)
                            }
                        }
                        .padding(.top, 12)
                        .padding(.vertical, 5)
                        .padding(.horizontal, 10)
                        .onTapGesture {
                            withAnimation {
                                self.isProfileImageExpanding.toggle()
                            }
                        }
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
                                .padding(.vertical, 5)
                                .padding(.horizontal, 10)
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
                        .padding(.top, 12)
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
                            case (.some(let sessionId), .none):
                                return ("accountId".localized(), sessionId)
                            case (.some(let sessionId), .some(_)):
                                return ("accountId".localized(), sessionId.splitIntoLines(charactersForLines: [23, 23, 20]))
                            case (.none, .some(let blindedId)):
                                return ("blindedId".localized(), blindedId)
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
                            .multilineTextAlignment(.center)
                            .lineLimit(info.blindedId == nil ? 0 : 1)
                            .truncationMode(.middle)
                            .padding(.horizontal, info.blindedId == nil ? 0 : Values.largeSpacing)
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
                        if !info.isMessageRequestsEnabled {
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
                                    let hexEncodedId: String = {
                                        switch (info.sessionId, info.blindedId) {
                                            case (.some(let sessionId), _): return sessionId
                                            case (.none, .some(let blindedId)): return blindedId
                                            default : return "" // Shouldn't happen
                                        }
                                    }()
                                    
                                    info.onStartThread?(
                                        hexEncodedId,
                                        info.openGroupServer,
                                        info.openGroupPublicKey
                                    )
                                } label: {
                                    Text("message".localized())
                                        .font(.system(size: Values.mediumFontSize))
                                        .foregroundColor(themeColor: (info.isMessageRequestsEnabled ? .sessionButton_text : .disabled))
                                }
                                .disabled(!info.isMessageRequestsEnabled)
                                .frame(
                                    width: (geometry.size.width - Values.mediumSpacing) / 2,
                                    height: Values.smallButtonHeight
                                )
                                .overlay(
                                    Capsule()
                                        .stroke(themeColor: (info.isMessageRequestsEnabled ? .sessionButton_border : .disabled))
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
        }
        .popoverView(
            content: {
                ZStack {
                    AttributedText(tooltipText)
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
        let isMessageRequestsEnabled: Bool
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
            isMessageRequestsEnabled: Bool,
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
            self.isMessageRequestsEnabled = isMessageRequestsEnabled
            self.onStartThread = onStartThread
        }
    }
}
