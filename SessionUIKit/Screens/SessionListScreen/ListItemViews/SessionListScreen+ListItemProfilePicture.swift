// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import Lucide
import DifferenceKit

// MARK: - ListItemProfilePicture

public struct ListItemProfilePicture: View {
    public struct Info: Equatable, Hashable, Differentiable {
        let sessionId: String?
        let qrCodeImage: UIImage?
        var size: ProfilePictureView.Info.Size
        let profileInfo: ProfilePictureView.Info?
        let additionalProfileInfo: ProfilePictureView.Info?
        let isExpandable: Bool
        
        public init(
            sessionId: String?,
            qrCodeImage: UIImage?,
            size: ProfilePictureView.Info.Size,
            profileInfo: ProfilePictureView.Info?,
            additionalProfileInfo: ProfilePictureView.Info?,
            isExpandable: Bool = true
        ) {
            self.sessionId = sessionId
            self.qrCodeImage = qrCodeImage
            self.size = size
            self.profileInfo = profileInfo
            self.additionalProfileInfo = additionalProfileInfo
            self.isExpandable = isExpandable
        }
        
        public init(
            sessionId: String?,
            qrCodeImage: UIImage?,
            size: ProfilePictureView.Info.Size,
            profileInfo: (front: ProfilePictureView.Info?, back: ProfilePictureView.Info?),
            isExpandable: Bool = true
        ) {
            self.sessionId = sessionId
            self.qrCodeImage = qrCodeImage
            self.size = size
            self.profileInfo = profileInfo.front
            self.additionalProfileInfo = profileInfo.back
            self.isExpandable = isExpandable
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
    let onProfilePictureTap: (@MainActor () -> Void)
    
    public var body: some View {
        let scale: CGFloat = (isProfileImageExpanding ?
            (ProfilePictureView.Info.Size.expanded.viewSize / ProfilePictureView.Info.Size.modal.viewSize) :
            1
        )
        
        ZStack(alignment: .top) {
            ZStack(alignment: .topTrailing) {
                if let profileInfo = info.profileInfo {
                    ZStack {
                        ProfilePictureSwiftUI(
                            size: info.size,
                            info: profileInfo,
                            additionalInfo: info.additionalProfileInfo,
                            dataManager: self.dataManager
                        )
                        .scaleEffect(scale, anchor: .topLeading)
                        .onTapGesture {
                            if info.isExpandable {
                                withAnimation(.easeInOut(duration: 0.1)) {
                                    self.isProfileImageExpanding.toggle()
                                }
                            } else {
                                onProfilePictureTap()
                            }
                        }
                    }
                    .frame(
                        width: (info.size.viewSize * scale),
                        height: (info.size.viewSize * scale),
                        alignment: .center
                    )
                }
                
                if info.qrCodeImage != nil {
                    let buttonSize: CGFloat = (isProfileImageExpanding ? 33 : 24)
                    let iconSize: CGFloat = (isProfileImageExpanding ? 20 : 14)
                    
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
                    .padding(.top, isProfileImageExpanding ? 30 : 8)
                    .padding(.trailing, isProfileImageExpanding ? 30 : 8)
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
            height: (content == .qrCode ? 200 : (info.size.viewSize * scale + 10)),
            alignment: .top
        )
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


#Preview {
    struct PreviewWrapper: View {
        @State private var content: ListItemProfilePicture.Content = .profilePicture
        @State private var isProfileImageExpanding: Bool = false
        private var size: ProfilePictureView.Info.Size = .modal

        var body: some View {
            ZStack {
                Color.gray
                
                HStack {
                    ListItemProfilePicture(
                        content: $content,
                        isProfileImageExpanding: $isProfileImageExpanding,
                        info: ListItemProfilePicture.Info(
                            sessionId: "051234",
                            qrCodeImage: nil,
                            size: size,
                            profileInfo: ProfilePictureView.Info(
                                source: .placeholderIcon(
                                    seed: "051234",
                                    text: "Test User",
                                    size: size.viewSize
                                ),
                                canAnimate: false
                            ),
                            additionalProfileInfo: nil
                        ),
                        dataManager: ImageDataManager(),
                        host: HostWrapper(),
                        onProfilePictureTap: {
                            print("Profile picture tapped")
                        }
                    )
                    .padding()
                    
                    ListItemProfilePicture(
                        content: $content,
                        isProfileImageExpanding: $isProfileImageExpanding,
                        info: ListItemProfilePicture.Info(
                            sessionId: "051234",
                            qrCodeImage: nil,
                            size: size,
                            profileInfo: ProfilePictureView.Info(
                                source: .image("preview", UIImage(systemName: "person.fill")),
                                canAnimate: false,
                                renderingMode: .alwaysTemplate,
                                themeTintColor: .white,
                                inset: size.multiImagePlaceholderInsets,
                                leadingIcon: .none,
                                trailingIcon: .none,
                                backgroundColor: .primary
                            ),
                            additionalProfileInfo: ProfilePictureView.Info(
                                source: .placeholderIcon(
                                    seed: "051234",
                                    text: "Test User",
                                    size: size.viewSize
                                ),
                                canAnimate: false
                            )
                        ),
                        dataManager: ImageDataManager(),
                        host: HostWrapper(),
                        onProfilePictureTap: {
                            print("Profile picture tapped")
                        }
                    )
                    .padding()
                }
            }
        }
    }

    return PreviewWrapper()
}
