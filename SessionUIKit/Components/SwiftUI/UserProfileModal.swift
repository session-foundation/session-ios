// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import Lucide
import Combine

public struct UserProfileModal: View {
    @EnvironmentObject var host: HostWrapper
    @State private var isProfileImageToggled: Bool = true
    @State private var isProfileImageExpanding: Bool = false
    @State private var isSessionIdCopied: Bool = false
    @State private var isShowingTooltip: Bool = false
    @State private var tooltipContentFrame: CGRect = CGRect.zero
    
    private let tooltipViewId: String = "UserProfileModalToolTip" // stringlint:ignore
    private let coordinateSpaceName: String = "UserProfileModal" // stringlint:ignore
    
    private var info: Info
    private var dataManager: ImageDataManagerType
    let dismissType: Modal.DismissType
    let afterClosed: (() -> Void)?
    
    private var tooltipText: ThemedAttributedString {
        if info.sessionId == nil {
            return "tooltipBlindedIdCommunities"
                .localizedFormatted(baseFont: Fonts.Body.smallRegular)
        } else {
            return "tooltipAccountIdVisible"
                .put(key: "name", value: (info.displayName ?? ""))
                .localizedFormatted(baseFont: Fonts.Body.smallRegular)
        }
    }
    
    public init(
        info: Info,
        dataManager: ImageDataManagerType,
        dismissType: Modal.DismissType = .recursive,
        afterClosed: (() -> Void)? = nil
    ) {
        self.info = info
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
                                    size: .modal,
                                    info: info.profileInfo,
                                    dataManager: self.dataManager
                                )
                                .scaleEffect(scale, anchor: .topLeading)
                                .onTapGesture {
                                    withAnimation {
                                        self.isProfileImageExpanding.toggle()
                                    }
                                }
                            }
                            .frame(
                                width: ProfilePictureView.Size.modal.viewSize * scale,
                                height: ProfilePictureView.Size.modal.viewSize * scale,
                                alignment: .center
                            )
                            
                            if info.sessionId != nil {
                                let (buttonSize, iconSize): (CGFloat, CGFloat) = isProfileImageExpanding ? (33, 20) : (20, 12)
                                ZStack {
                                    Circle()
                                        .foregroundColor(themeColor: .primary)
                                        .frame(width: buttonSize, height: buttonSize)
                                    
                                    if let icon: UIImage = Lucide.image(icon: .qrCode, size: iconSize) {
                                        Image(uiImage: icon)
                                            .resizable()
                                            .renderingMode(.template)
                                            .scaledToFit()
                                            .foregroundColor(themeColor: .black)
                                            .frame(width: iconSize, height: iconSize)
                                    }
                                }
                                .padding(.trailing, isProfileImageExpanding ? 28 : 4)
                                .onTapGesture {
                                    withAnimation {
                                        self.isProfileImageToggled.toggle()
                                    }
                                }
                            }
                        }
                        .padding(.top, 12)
                        .padding(.vertical, 5)
                        .padding(.horizontal, 10)
                    } else {
                        ZStack(alignment: .topTrailing) {
                            if let qrCodeImage = info.qrCodeImage {
                                QRCodeView(
                                    qrCodeImage: qrCodeImage,
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
                                    showQRCodeLightBox()
                                }
                                
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
                                    .onTapGesture {
                                        withAnimation {
                                            self.isProfileImageToggled.toggle()
                                        }
                                    }
                            }
                        }
                        .padding(.top, 12)
                    }
                    
                    // Display name & Nickname (ProBadge)
                    if let displayName: String = info.displayName {
                        VStack(spacing: Values.smallSpacing) {
                            HStack(spacing: Values.smallSpacing) {
                                Text(displayName)
                                    .font(.Headings.H6)
                                    .foregroundColor(themeColor: .textPrimary)
                                    .multilineTextAlignment(.center)
                                
                                if info.isProUser {
                                    SessionProBadge_SwiftUI(size: .large)
                                        .onTapGesture {
                                            info.onProBadgeTapped?()
                                        }
                                }
                            }
                            
                            if let contactDisplayName: String = info.contactDisplayName, contactDisplayName != displayName {
                                Text("(\(contactDisplayName))") // stringlint:ignroe
                                    .font(.Body.smallRegular)
                                    .foregroundColor(themeColor: .textSecondary)
                                    .multilineTextAlignment(.center)
                            }
                        }
                    }
                    
                    // Account Id | Blinded Id (Tooltips)
                    let (title, hexEncodedId): (String, String) = {
                        switch (info.sessionId, info.blindedId) {
                            case (.some(let sessionId), .none):
                                return ("accountId".localized(), sessionId)
                            case (.some(let sessionId), .some):
                                return ("accountId".localized(), sessionId.splitIntoLines(charactersForLines: [23, 23, 20]))
                            case (.none, .some(let blindedId)):
                                return ("blindedId".localized(), blindedId)
                            case (.none, .none):
                                return ("", "") // Shouldn't happen
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
                            .padding(.horizontal, info.blindedId == nil ? 0 : Values.largeSpacing)
                    }
                    
                    // Buttons
                    if let sessionId = info.sessionId {
                        HStack(spacing: Values.mediumSpacing) {
                            Button {
                                close(info.onStartThread)
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
                                copySessionId(sessionId)
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
                        .padding(.bottom, 12)
                    } else {
                        if !info.isMessageRequestsEnabled, let displayName: String = info.displayName {
                            AttributedText("messageRequestsTurnedOff"
                                .put(key: "name", value: displayName)
                                .localizedFormatted(Fonts.Body.smallRegular)
                            )
                            .font(.Body.smallRegular)
                            .foregroundColor(themeColor: .textSecondary)
                            .multilineTextAlignment(.center)
                        }
                        
                        GeometryReader { geometry in
                            HStack {
                                Button {
                                    close(info.onStartThread)
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
                        .padding(.bottom, 12)
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
                        .frame(maxWidth: 260)
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
            position: .topLeft,
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
    
    private func copySessionId(_ sessionId: String) {
        guard !isSessionIdCopied else { return }
        
        UIPasteboard.general.string = sessionId
        
        // Ensure we are on the main thread just in case
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.25)) {
                isSessionIdCopied.toggle()
            }
            // 4 seconds delay + the animation duration above
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(4) + .milliseconds(250)) {
                withAnimation(.easeInOut(duration: 0.25)) {
                    isSessionIdCopied.toggle()
                }
            }
        }
    }
    
    private func showQRCodeLightBox() {
        guard let qrCodeImage: UIImage = info.qrCodeImage else { return }
        
        let viewController = SessionHostingViewController(
            rootView: LightBox(
                itemsToShare: [
                    QRCode.qrCodeImageWithTintAndBackground(
                        image: qrCodeImage,
                        themeStyle: ThemeManager.currentTheme.interfaceStyle,
                        size: CGSize(width: 400, height: 400),
                        insets: UIEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
                    )
                ]
            ) {
                VStack {
                    Spacer()
                    
                    QRCodeView(
                        qrCodeImage: qrCodeImage,
                        themeStyle: ThemeManager.currentTheme.interfaceStyle
                    )
                    .aspectRatio(1, contentMode: .fit)
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity
                    )
                    
                    Spacer()
                }
                .backgroundColor(themeColor: .newConversation_background)
            },
            customizedNavigationBackground: .backgroundSecondary
        )
        viewController.modalPresentationStyle = .fullScreen
        self.host.controller?.present(viewController, animated: true)
    }
}

public extension UserProfileModal {
    struct Info {
        let sessionId: String?
        let blindedId: String?
        let qrCodeImage: UIImage?
        let profileInfo: ProfilePictureView.Info
        let displayName: String?
        let contactDisplayName: String?
        let isProUser: Bool
        let isMessageRequestsEnabled: Bool
        let onStartThread: (() -> Void)?
        let onProBadgeTapped: (() -> Void)?
        
        public init(
            sessionId: String?,
            blindedId: String?,
            qrCodeImage: UIImage?,
            profileInfo: ProfilePictureView.Info,
            displayName: String?,
            contactDisplayName: String?,
            isProUser: Bool,
            isMessageRequestsEnabled: Bool,
            onStartThread: (() -> Void)?,
            onProBadgeTapped: (() -> Void)?
        ) {
            self.sessionId = sessionId
            self.blindedId = blindedId
            self.qrCodeImage = qrCodeImage
            self.profileInfo = profileInfo
            self.displayName = displayName
            self.contactDisplayName = contactDisplayName
            self.isProUser = isProUser
            self.isMessageRequestsEnabled = isMessageRequestsEnabled
            self.onStartThread = onStartThread
            self.onProBadgeTapped = onProBadgeTapped
        }
    }
}
