// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import Lucide
import DifferenceKit

// MARK: - ListItemProfilePicture

public struct ListItemProfilePicture: View {
    public struct Info: Equatable, Hashable, Differentiable {
        let sessionId: String?
        let qrCodeImage: UIImage?
        let profileInfo: ProfilePictureView.Info?
        
        public init(sessionId: String?, qrCodeImage: UIImage?, profileInfo: ProfilePictureView.Info?) {
            self.sessionId = sessionId
            self.qrCodeImage = qrCodeImage
            self.profileInfo = profileInfo
        }
    }
    
    public enum Content: Equatable, Hashable, Differentiable {
        case profilePicture
        case qrCode
    }
    
    @Binding var content: Content
    @Binding var isProfileImageExpanding: Bool
    
    var info: Info
    var dataManager: ImageDataManagerType
    let host: HostWrapper
    
    public var body: some View {
        let scale: CGFloat = isProfileImageExpanding ? (190.0 / 90) : 1
        ZStack(alignment: .top) {
            ZStack(alignment: .topTrailing) {
                if let profileInfo = info.profileInfo {
                    ZStack {
                        ProfilePictureSwiftUI(
                            size: .modal,
                            info: profileInfo,
                            dataManager: self.dataManager
                        )
                        .scaleEffect(scale, anchor: .topLeading)
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.1)) {
                                self.isProfileImageExpanding.toggle()
                            }
                        }
                    }
                    .frame(
                        width: ProfilePictureView.Info.Size.modal.viewSize * scale,
                        height: ProfilePictureView.Info.Size.modal.viewSize * scale,
                        alignment: .center
                    )
                }
                
                if info.qrCodeImage != nil {
                    let (buttonSize, iconSize): (CGFloat, CGFloat) = isProfileImageExpanding ? (33, 20) : (24, 14)
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
                            self.content = .qrCode
                        }
                    }
                }
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 10)
            .opacity((content == .profilePicture ? 1 : 0))
            
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
                    .frame(width: 190, height: 190, alignment: .top)
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
                                self.content = .profilePicture
                            }
                        }
                }
            }
            .opacity((content == .qrCode ? 1 : 0))
        }
        .frame(
            width: 210,
            height: content == .qrCode ? 200 : (ProfilePictureView.Info.Size.modal.viewSize * scale + 10),
            alignment: .top
        )
        .padding(.top, 12)
    }
    
    private func showQRCodeLightBox() {
        guard let qrCodeImage: UIImage = info.qrCodeImage else { return }
        
        let viewController = SessionHostingViewController(
            rootView: LightBox(
                itemsToShare: [
                    QRCode.qrCodeImageWithBackground(
                        image: qrCodeImage,
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
