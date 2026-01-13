// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import SessionUIKit
import SessionNetworkingKit
import SessionUtilitiesKit
import SessionMessagingKit
import Lucide

struct MessageInfoScreen: View {
    public struct ViewModel {
        let dependencies: Dependencies
        let actions: [ContextMenuVC.Action]
        let messageViewModel: MessageViewModel
        let threadCanWrite: Bool
        let openGroupServer: String?
        let openGroupPublicKey: String?
        let onStartThread: (@MainActor () -> Void)?
        let isMessageFailed: Bool
        let isCurrentUser: Bool
        let profileInfo: ProfilePictureView.Info?
        
        /// These are the features that were enabled at the time the message was received
        let proFeatures: [ProFeature]
        
        /// This flag is separate to the `proFeatures` because it should be based on the _current_ pro state of the user rather than
        /// the state the user was in when the message was sent
        let shouldShowProBadge: Bool
        
        func ctaVariant(currentUserProStatus: Network.SessionPro.BackendUserProStatus) -> ProCTAModal.Variant {
            guard let firstFeature: ProFeature = proFeatures.first, proFeatures.count > 1 else {
                return .generic(renew: (currentUserProStatus == .expired))
            }
            
            switch firstFeature {
                case .proBadge: return .generic(renew: (currentUserProStatus == .expired))
                case .increasedMessageLength: return .longerMessages(renew: (currentUserProStatus == .expired))
                case .animatedDisplayPicture:
                    return .animatedProfileImage(
                        isSessionProActivated: (currentUserProStatus == .active),
                        renew: (currentUserProStatus == .expired)
                    )
            }
        }
    }
    
    public enum ProFeature: Equatable {
        case proBadge
        case increasedMessageLength
        case animatedDisplayPicture
        
        var title: String {
            switch self {
                case .proBadge:
                    return "appProBadge"
                        .put(key: "app_pro", value: Constants.app_pro)
                        .localized()
                    
                case .increasedMessageLength: return "proIncreasedMessageLengthFeature".localized()
                case .animatedDisplayPicture: return "proAnimatedDisplayPictureFeature".localized()
            }
        }
        
        static func from(
            messageFeatures: SessionPro.MessageFeatures,
            profileFeatures: SessionPro.ProfileFeatures
        ) -> [ProFeature] {
            var result: [ProFeature] = []
            
            if profileFeatures.contains(.proBadge) {
                result.append(.proBadge)
            }
            
            if messageFeatures.contains(.largerCharacterLimit) {
                result.append(.increasedMessageLength)
            }
            
            if profileFeatures.contains(.animatedAvatar) {
                result.append(.animatedDisplayPicture)
            }
            
            return result
        }
    }
    
    @EnvironmentObject var host: HostWrapper
    
    @State var index = 1
    @State var feedbackMessage: String? = nil
    @State var isExpanded: Bool = false
    
    static private let cornerRadius: CGFloat = 17
    
    var viewModel: ViewModel
    
    public init(
        actions: [ContextMenuVC.Action],
        messageViewModel: MessageViewModel,
        threadCanWrite: Bool,
        openGroupServer: String?,
        openGroupPublicKey: String?,
        onStartThread: (@MainActor () -> Void)?,
        using dependencies: Dependencies
    ) {
        self.viewModel = ViewModel(
            dependencies: dependencies,
            actions: actions.filter { $0.actionType != .emoji },    // Exclude emoji actions
            messageViewModel: messageViewModel,
            threadCanWrite: threadCanWrite,
            openGroupServer: openGroupServer,
            openGroupPublicKey: openGroupPublicKey,
            onStartThread: onStartThread,
            isMessageFailed: [.failed, .failedToSync].contains(messageViewModel.state),
            isCurrentUser: messageViewModel.currentUserSessionIds.contains(messageViewModel.authorId),
            profileInfo: ProfilePictureView.Info.generateInfoFrom(
                size: .message,
                publicKey: messageViewModel.profile.id,
                threadVariant: .contact,    // Always show the display picture in 'contact' mode
                displayPictureUrl: nil,
                profile: messageViewModel.profile,
                profileIcon: (messageViewModel.isSenderModeratorOrAdmin ? .crown : .none),
                using: dependencies
            ).front,
            proFeatures: ProFeature.from(
                messageFeatures: messageViewModel.proMessageFeatures,
                profileFeatures: messageViewModel.proProfileFeatures
            ),
            shouldShowProBadge: messageViewModel.profile.proFeatures.contains(.proBadge)
        )
    }
    
    var body: some View {
        ZStack (alignment: .topLeading) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(
                    alignment: .leading,
                    spacing: 10
                ) {
                    VStack(
                        alignment: .leading,
                        spacing: 0
                    ) {
                        // Message bubble snapshot
                        MessageBubble(
                            messageViewModel: viewModel.messageViewModel,
                            attachmentOnly: false,
                            dependencies: viewModel.dependencies
                        )
                        .clipShape(
                            RoundedRectangle(cornerRadius: Self.cornerRadius)
                        )
                        .background(
                            RoundedRectangle(cornerRadius: Self.cornerRadius)
                                .fill(
                                    themeColor: (viewModel.messageViewModel.variant == .standardIncoming || viewModel.messageViewModel.variant == .standardIncomingDeleted || viewModel.messageViewModel.variant == .standardIncomingDeletedLocally ?
                                        .messageBubble_incomingBackground :
                                            .messageBubble_outgoingBackground)
                                )
                        )
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: .infinity,
                            alignment: .topLeading
                        )
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, Values.smallSpacing)
                        .padding(.bottom, Values.verySmallSpacing)
                        .padding(.horizontal, Values.largeSpacing)
                        
                        
                        if viewModel.isMessageFailed {
                            let (image, statusText, tintColor) = viewModel.messageViewModel.state.statusIconInfo(
                                variant: viewModel.messageViewModel.variant,
                                hasBeenReadByRecipient: viewModel.messageViewModel.hasBeenReadByRecipient,
                                hasAttachments: !viewModel.messageViewModel.attachments.isEmpty
                            )
                            
                            HStack(spacing: 6) {
                                if let image: UIImage = image?.withRenderingMode(.alwaysTemplate) {
                                    Image(uiImage: image)
                                        .resizable()
                                        .scaledToFit()
                                        .foregroundColor(themeColor: tintColor)
                                        .frame(width: 13, height: 12)
                                }
                                
                                if let statusText: String = statusText {
                                    Text(statusText)
                                        .font(.system(size: Values.verySmallFontSize))
                                        .foregroundColor(themeColor: tintColor)
                                }
                            }
                            .padding(.bottom, Values.verySmallSpacing)
                            .padding(.horizontal, Values.largeSpacing)
                        }
                        
                        if !viewModel.messageViewModel.attachments.isEmpty {
                            let attachments: [Attachment] = viewModel.messageViewModel.attachments
                            
                            switch viewModel.messageViewModel.cellType {
                                case .mediaMessage:
                                    let attachment: Attachment = attachments[(index - 1 + attachments.count) % attachments.count]
                                    
                                    ZStack(alignment: .bottomTrailing) {
                                        if attachments.count > 1 {
                                            // Attachment carousel view
                                            SessionCarouselView_SwiftUI(
                                                index: $index,
                                                isOutgoing: (viewModel.messageViewModel.variant == .standardOutgoing),
                                                contentInfos: attachments,
                                                using: viewModel.dependencies
                                            )
                                            .frame(
                                                maxWidth: .infinity,
                                                maxHeight: .infinity,
                                                alignment: .topLeading
                                            )
                                        } else {
                                            MediaView_SwiftUI(
                                                attachment: attachments[0],
                                                isOutgoing: (viewModel.messageViewModel.variant == .standardOutgoing),
                                                shouldSupressControls: true,
                                                cornerRadius: 0,
                                                using: viewModel.dependencies
                                            )
                                            .frame(
                                                maxWidth: .infinity,
                                                maxHeight: .infinity,
                                                alignment: .topLeading
                                            )
                                            .aspectRatio(1, contentMode: .fit)
                                            .clipShape(RoundedRectangle(cornerRadius: 15))
                                            .padding(.horizontal, Values.largeSpacing)
                                        }
                                        
                                        if [ .downloaded, .uploaded ].contains(attachment.state) {
                                            Button {
                                                self.showMediaFullScreen(attachment: attachment)
                                            } label: {
                                                ZStack {
                                                    Circle()
                                                        .foregroundColor(.init(white: 0, opacity: 0.4))
                                                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                                                        .font(.system(size: 13))
                                                        .foregroundColor(.white)
                                                }
                                                .frame(width: 26, height: 26)
                                            }
                                            .padding(.bottom, Values.smallSpacing)
                                            .padding(.trailing, 38)
                                        }
                                    }
                                    .padding(.vertical, Values.verySmallSpacing)
                                    
                                default:
                                    MessageBubble(
                                        messageViewModel: viewModel.messageViewModel,
                                        attachmentOnly: true,
                                        dependencies: viewModel.dependencies
                                    )
                                    .clipShape(
                                        RoundedRectangle(cornerRadius: Self.cornerRadius)
                                    )
                                    .background(
                                        RoundedRectangle(cornerRadius: Self.cornerRadius)
                                            .fill(
                                                themeColor: (viewModel.messageViewModel.variant == .standardIncoming || viewModel.messageViewModel.variant == .standardIncomingDeleted || viewModel.messageViewModel.variant == .standardIncomingDeletedLocally ?
                                                    .messageBubble_incomingBackground :
                                                        .messageBubble_outgoingBackground)
                                            )
                                    )
                                    .frame(
                                        maxWidth: .infinity,
                                        maxHeight: .infinity,
                                        alignment: .topLeading
                                    )
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.bottom, Values.verySmallSpacing)
                                    .padding(.horizontal, Values.largeSpacing)
                            }
                        }
                    }
                        
                    // Attachment Info
                    if !viewModel.messageViewModel.attachments.isEmpty {
                        let attachments: [Attachment] = viewModel.messageViewModel.attachments
                        let attachment: Attachment = attachments[(index - 1 + attachments.count) % attachments.count]
                        
                        ZStack {
                            VStack(
                                alignment: .leading,
                                spacing: Values.mediumSpacing
                            ) {
                                InfoBlock(title: "attachmentsFileId".localized()) {
                                    Text(attachment.downloadUrl.map { Network.FileServer.fileId(for: URL(string: $0)?.strippingQueryAndFragment?.absoluteString) } ?? "")
                                        .font(.Body.largeRegular)
                                        .foregroundColor(themeColor: .textPrimary)
                                }
                                
                                HStack(
                                    alignment: .center
                                ) {
                                    InfoBlock(title: "attachmentsFileType".localized()) {
                                        Text(attachment.contentType)
                                            .font(.Body.largeRegular)
                                            .foregroundColor(themeColor: .textPrimary)
                                    }
                                    
                                    Spacer()
                                    
                                    InfoBlock(title: "attachmentsFileSize".localized()) {
                                        Text(Format.fileSize(attachment.byteCount))
                                            .font(.Body.largeRegular)
                                            .foregroundColor(themeColor: .textPrimary)
                                    }
                                    
                                    Spacer()
                                }
                                HStack(
                                    alignment: .center
                                ) {
                                    let resolution: String = {
                                        guard let width = attachment.width, let height = attachment.height else { return "attachmentsNa".localized() }
                                        return "\(width)×\(height)"
                                    }()
                                    InfoBlock(title: "attachmentsResolution".localized()) {
                                        Text(resolution)
                                            .font(.Body.largeRegular)
                                            .foregroundColor(themeColor: .textPrimary)
                                    }
                                    
                                    Spacer()
                                    
                                    let duration: String = {
                                        guard let duration = attachment.duration else { return "attachmentsNa".localized() }
                                        return floor(duration).formatted(format: .videoDuration)
                                    }()
                                    InfoBlock(title: "attachmentsDuration".localized()) {
                                        Text(duration)
                                            .font(.Body.largeRegular)
                                            .foregroundColor(themeColor: .textPrimary)
                                    }
                                    
                                    Spacer()
                                }
                            }
                            .frame(
                                maxWidth: .infinity,
                                maxHeight: .infinity,
                                alignment: .topLeading
                            )
                            .padding(.all, Values.largeSpacing)
                        }
                        .frame(maxHeight: .infinity)
                        .backgroundColor(themeColor: .backgroundSecondary)
                        .cornerRadius(Self.cornerRadius)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, Values.verySmallSpacing)
                        .padding(.horizontal, Values.largeSpacing)
                    }

                    // Message Info
                    ZStack {
                        VStack(
                            alignment: .leading,
                            spacing: Values.mediumSpacing
                        ) {
                            // Pro feature message
                            if viewModel.proFeatures.count > 0 {
                                VStack(
                                    alignment: .leading,
                                    spacing: Values.mediumSpacing
                                ) {
                                    HStack(spacing: Values.verySmallSpacing) {
                                        SessionProBadge_SwiftUI(size: .small)
                                        Text("message".localized())
                                            .font(.Body.extraLargeBold)
                                            .foregroundColor(themeColor: .textPrimary)
                                    }
                                    .onTapGesture { showSessionProCTAIfNeeded() }
                                    
                                    Text(
                                        "proMessageInfoFeatures"
                                            .put(key: "app_pro", value: Constants.app_pro)
                                            .localized()
                                    )
                                    .font(.Body.largeRegular)
                                    .foregroundColor(themeColor: .textPrimary)
                                    
                                    VStack(
                                        alignment: .leading,
                                        spacing: Values.smallSpacing
                                    ) {
                                        ForEach(viewModel.proFeatures, id: \.self) { feature in
                                            HStack(spacing: Values.smallSpacing) {
                                                AttributedText(Lucide.Icon.circleCheck.attributedString(size: 17))
                                                    .font(.system(size: 17))
                                                    .foregroundColor(themeColor: .primary)
                                                
                                                Text(feature.title)
                                                    .font(.Body.largeRegular)
                                                    .foregroundColor(themeColor: .textPrimary)
                                            }
                                        }
                                    }
                                }
                            }
                            
                            if viewModel.isMessageFailed {
                                let failureText: String = viewModel.messageViewModel.mostRecentFailureText ?? "messageStatusFailedToSend".localized()
                                InfoBlock(title: "theError".localized() + ":") {
                                    Text(failureText)
                                        .font(.Body.largeRegular)
                                        .foregroundColor(themeColor: .danger)
                                }
                            } else {
                                InfoBlock(title: "sent".localized()) {
                                    Text(viewModel.messageViewModel.dateForUI.fromattedForMessageInfo)
                                        .font(.Body.largeRegular)
                                        .foregroundColor(themeColor: .textPrimary)
                                }
                                
                                InfoBlock(title: "received".localized()) {
                                    Text(viewModel.messageViewModel.receivedDateForUI.fromattedForMessageInfo)
                                        .font(.Body.largeRegular)
                                        .foregroundColor(themeColor: .textPrimary)
                                }
                            }
                            
                            InfoBlock(title: "from".localized()) {
                                HStack(
                                    spacing: 10
                                ) {
                                    let size: ProfilePictureView.Info.Size = .list
                                    
                                    if let info: ProfilePictureView.Info = viewModel.profileInfo {
                                        ProfilePictureSwiftUI(
                                            size: size,
                                            info: info,
                                            additionalInfo: nil,
                                            dataManager: viewModel.dependencies[singleton: .imageDataManager]
                                        )
                                        .frame(
                                            width: size.viewSize,
                                            height: size.viewSize,
                                            alignment: .topLeading
                                        )
                                    }
                                    
                                    VStack(
                                        alignment: .leading,
                                        spacing: Values.verySmallSpacing
                                    ) {
                                        HStack(spacing: Values.verySmallSpacing) {
                                            if viewModel.isCurrentUser {
                                                Text("you".localized())
                                                    .font(.Body.extraLargeBold)
                                                    .foregroundColor(themeColor: .textPrimary)
                                            }
                                            else if !viewModel.messageViewModel.authorName().isEmpty {
                                                Text(viewModel.messageViewModel.authorName())
                                                    .font(.Body.extraLargeBold)
                                                    .foregroundColor(themeColor: .textPrimary)
                                            }
                                            
                                            if viewModel.shouldShowProBadge {
                                                SessionProBadge_SwiftUI(size: .small)
                                                    .onTapGesture { showSessionProCTAIfNeeded() }
                                            }
                                        }
                                        
                                        Text(viewModel.messageViewModel.authorId)
                                            .font(.Display.base)
                                            .foregroundColor(
                                                themeColor: {
                                                    if
                                                        viewModel.messageViewModel.authorId.hasPrefix(SessionId.Prefix.blinded15.rawValue) ||
                                                        viewModel.messageViewModel.authorId.hasPrefix(SessionId.Prefix.blinded25.rawValue)
                                                    {
                                                        return .textSecondary
                                                    }
                                                    else {
                                                        return .textPrimary
                                                    }
                                                }()
                                            )
                                    }
                                }
                            }
                            .onTapGesture {
                                showUserProfileModal()
                            }
                        }
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: .infinity,
                            alignment: .topLeading
                        )
                        .padding(.all, Values.largeSpacing)
                    }
                    .frame(maxHeight: .infinity)
                    .backgroundColor(themeColor: .backgroundSecondary)
                    .cornerRadius(Self.cornerRadius)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, Values.verySmallSpacing)
                    .padding(.horizontal, Values.largeSpacing)

                    // Actions
                    if !viewModel.actions.isEmpty {
                        ZStack {
                            VStack(
                                alignment: .leading,
                                spacing: 0
                            ) {
                                ForEach(
                                    0...(viewModel.actions.count - 1),
                                    id: \.self
                                ) { index in
                                    let tintColor: ThemeValue = viewModel.actions[index].themeColor
                                    Button(
                                        action: {
                                            viewModel.actions[index].work() {
                                                switch (viewModel.actions[index].shouldDismissInfoScreen, viewModel.actions[index].feedback) {
                                                    case (false, _): break
                                                    case (true, .some):
                                                        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: {
                                                            dismiss()
                                                        })
                                                    default: dismiss()
                                                }
                                            }
                                            feedbackMessage = viewModel.actions[index].feedback
                                        },
                                        label: {
                                            HStack(spacing: Values.largeSpacing) {
                                                if let icon: UIImage = viewModel.actions[index].icon?.withRenderingMode(.alwaysTemplate) {
                                                    Image(uiImage: icon)
                                                        .resizable()
                                                        .scaledToFit()
                                                        .scaleEffect(x: (viewModel.actions[index].flipIconForRTL ? -1 : 1), y: 1)
                                                        .foregroundColor(themeColor: tintColor)
                                                        .frame(width: 26, height: 26)
                                                }
                                                
                                                Text(viewModel.actions[index].title)
                                                    .font(.Headings.H8)
                                                    .foregroundColor(themeColor: tintColor)
                                            }
                                            .frame(maxWidth: .infinity, alignment: .topLeading)
                                        }
                                    )
                                    .frame(height: 60)
                                    
                                    if index < (viewModel.actions.count - 1) {
                                        Divider()
                                            .foregroundColor(themeColor: .borderSeparator)
                                    }
                                }
                            }
                            .frame(
                                maxWidth: .infinity,
                                maxHeight: .infinity,
                                alignment: .topLeading
                            )
                            .padding(.horizontal, Values.largeSpacing)
                        }
                        .frame(maxHeight: .infinity)
                        .backgroundColor(themeColor: .backgroundSecondary)
                        .cornerRadius(Self.cornerRadius)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, Values.verySmallSpacing)
                        .padding(.horizontal, Values.largeSpacing)
                    }
                }
            }
        }
        .backgroundColor(themeColor: .backgroundPrimary)
        .toastView(message: $feedbackMessage)
    }
    
    private func showSessionProCTAIfNeeded() {
        viewModel.dependencies[singleton: .sessionProManager].showSessionProCTAIfNeeded(
            viewModel.ctaVariant(
                currentUserProStatus: viewModel.dependencies[singleton: .sessionProManager]
                    .currentUserCurrentProState
                    .status
            ),
            onConfirm: {
                viewModel.dependencies[singleton: .sessionProManager].showSessionProBottomSheetIfNeeded(
                    presenting: { bottomSheet in
                        self.host.controller?.present(bottomSheet, animated: true)
                    }
                )
            },
            presenting: { modal in
                self.host.controller?.present(modal, animated: true)
            }
        )
    }
    
    func showUserProfileModal() {
        guard viewModel.threadCanWrite else { return }
        
        Task.detached(priority: .userInitiated) {
            guard
                let info: UserProfileModal.Info = await viewModel.messageViewModel.createUserProfileModalInfo(
                    openGroupServer: viewModel.openGroupServer,
                    openGroupPublicKey: viewModel.openGroupPublicKey,
                    onStartThread: viewModel.onStartThread,
                    onProBadgeTapped: showSessionProCTAIfNeeded,
                    using: viewModel.dependencies
                )
            else { return }
            
            await MainActor.run {
                let userProfileModal: ModalHostingViewController = ModalHostingViewController(
                    modal: UserProfileModal(
                        info: info,
                        dataManager: viewModel.dependencies[singleton: .imageDataManager]
                    )
                )
                self.host.controller?.present(userProfileModal, animated: true, completion: nil)
            }
        }
    }
    
    private func showMediaFullScreen(attachment: Attachment) {
        if let mediaGalleryView = MediaGalleryViewModel.createDetailViewController(
            for: viewModel.messageViewModel.threadId,
            threadVariant: viewModel.messageViewModel.threadVariant,
            interactionId: viewModel.messageViewModel.id,
            selectedAttachmentId: attachment.id,
            options: [ .sliderEnabled ],
            useTransitioningDelegate: false,
            using: viewModel.dependencies
        ) {
            self.host.controller?.present(mediaGalleryView, animated: true)
        }
    }
    
    func dismiss() {
        self.host.controller?.navigationController?.popViewController(animated: true)
    }
}

// MARK: - MessageBubble

struct MessageBubble: View {
    @State private var maxWidth: CGFloat?
    @State private var isExpanded: Bool = false
    
    static private let cornerRadius: CGFloat = 18
    static private let inset: CGFloat = 12
    
    let messageViewModel: MessageViewModel
    let attachmentOnly: Bool
    let dependencies: Dependencies
    
    var bodyLabelTextColor: ThemeValue {
        messageViewModel.variant == .standardOutgoing ?
            .messageBubble_outgoingText :
            .messageBubble_incomingText
    }
    
    var body: some View {
        ZStack {
            let maxWidth: CGFloat = (
                VisibleMessageCell.getMaxWidth(
                    for: messageViewModel,
                    cellWidth: UIScreen.main.bounds.width
                ) - 2 * Self.inset
            )
            let maxHeight: CGFloat = VisibleMessageCell.getMaxHeightAfterTruncation(for: messageViewModel)
            let height: CGFloat = VisibleMessageCell.getBodyLabel(
                for: messageViewModel,
                with: maxWidth,
                textColor: bodyLabelTextColor,
                searchText: nil
            ).height
            
            VStack(
                alignment: .leading,
                spacing: 0
            ) {
                if !attachmentOnly {
                    // FIXME: We should support rendering link previews alongside quotes (bigger refactor)
                    if let linkPreview: LinkPreview = messageViewModel.linkPreview {
                        switch linkPreview.variant {
                            case .standard:
                                LinkPreviewView_SwiftUI(
                                    viewModel: linkPreview.sentState(
                                        imageAttachment: messageViewModel.linkPreviewAttachment,
                                        using: dependencies
                                    ),
                                    dataManager: dependencies[singleton: .imageDataManager],
                                    isOutgoing: (messageViewModel.variant == .standardOutgoing),
                                    maxWidth: maxWidth,
                                    messageViewModel: messageViewModel,
                                    bodyLabelTextColor: bodyLabelTextColor,
                                    lastSearchText: nil
                                )
                                
                            case .openGroupInvitation:
                                OpenGroupInvitationView_SwiftUI(
                                    name: (linkPreview.title ?? ""),
                                    url: linkPreview.url,
                                    textColor: bodyLabelTextColor,
                                    isOutgoing: (messageViewModel.variant == .standardOutgoing))
                        }
                    }
                    else {
                        if let quoteViewModel: QuoteViewModel = messageViewModel.quoteViewModel {
                            QuoteView_SwiftUI(
                                viewModel: quoteViewModel,
                                dataManager: dependencies[singleton: .imageDataManager]
                            )
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, Self.inset)
                            .padding(.horizontal, Self.inset)
                            .padding(.bottom, (messageViewModel.bubbleBody?.isEmpty == false ?
                                -Values.smallSpacing :
                                Self.inset
                            ))
                        }
                    }
                    
                    if let bodyText: ThemedAttributedString = VisibleMessageCell.getBodyAttributedText(
                        for: messageViewModel,
                        textColor: bodyLabelTextColor,
                        searchText: nil
                    ) {
                        AttributedLabel(bodyText, maxWidth: maxWidth)
                            .padding(.horizontal, Self.inset)
                            .padding(.top, Self.inset)
                            .frame(
                                maxHeight: (isExpanded ? .infinity : maxHeight)
                            )
                    }
                    
                    if (maxHeight < height && !isExpanded) {
                        Text("messageBubbleReadMore".localized())
                            .bold()
                            .font(.system(size: Values.smallFontSize))
                            .foregroundColor(themeColor: bodyLabelTextColor)
                            .padding(.horizontal, Self.inset)
                    }
                }
                else {
                    switch messageViewModel.cellType {
                        case .voiceMessage:
                            if let attachment: Attachment = messageViewModel.attachments.first(where: { $0.isAudio }){
                                // TODO: Playback Info and check if playing function is needed
                                VoiceMessageView_SwiftUI(attachment: attachment)
                                    .padding(.top, Self.inset)
                            }
                        case .audio, .genericAttachment:
                            if let attachment: Attachment = messageViewModel.attachments.first {
                                DocumentView_SwiftUI(
                                    maxWidth: $maxWidth,
                                    attachment: attachment,
                                    textColor: bodyLabelTextColor
                                )
                                .modifier(MaxWidthEqualizer.notify)
                                .padding(.top, Self.inset)
                                .frame(
                                    width: maxWidth,
                                    alignment: .leading
                                )
                            }
                        default: EmptyView()
                    }
                }
            }
            .padding(.bottom, Self.inset)
            .onTapGesture {
                self.isExpanded = true
            }
        }
    }
}

// MARK: - InfoBlock

struct InfoBlock<Content>: View where Content: View {
    let title: String
    let content: () -> Content
    
    private let minWidth: CGFloat = 100
    
    var body: some View {
        VStack(
            alignment: .leading,
            spacing: Values.verySmallSpacing
        ) {
            Text(self.title)
                .font(.Body.extraLargeBold)
                .foregroundColor(themeColor: .textPrimary)
            self.content()
        }
        .frame(
            minWidth: minWidth,
            alignment: .leading
        )
    }
}

// MARK: - MessageInfoViewController

final class MessageInfoViewController: SessionHostingViewController<MessageInfoScreen> {
    init(
        actions: [ContextMenuVC.Action],
        messageViewModel: MessageViewModel,
        threadCanWrite: Bool,
        openGroupServer: String?,
        openGroupPublicKey: String?,
        onStartThread: (() -> Void)?,
        using dependencies: Dependencies
    ) {
        let messageInfoView = MessageInfoScreen(
            actions: actions,
            messageViewModel: messageViewModel,
            threadCanWrite: threadCanWrite,
            openGroupServer: openGroupServer,
            openGroupPublicKey: openGroupPublicKey,
            onStartThread: onStartThread,
            using: dependencies
        )
        
        super.init(rootView: messageInfoView)
    }
    
    @MainActor required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        let customTitleFontSize = Values.largeFontSize
        setNavBarTitle("messageInfo".localized(), customFontSize: customTitleFontSize)
    }
}

// MARK: - Preview

struct MessageInfoView_Previews: PreviewProvider {
    static var messageViewModel: MessageViewModel {
        let dependencies: Dependencies = .createEmpty()
        let threadId: String = "d4f1g54sdf5g1d5f4g65ds4564df65f4g65d54gdfsg"
        var dataCache: ConversationDataCache = ConversationDataCache(
            userSessionId: SessionId(
                .standard,
                hex: "0588672ccb97f40bb57238989226cf429b575ba355443f47bc76c5ab144a961111"
            ),
            context: ConversationDataCache.Context(
                source: .messageList(threadId: threadId),
                requireFullRefresh: false,
                requireAuthMethodFetch: false,
                requiresMessageRequestCountUpdate: false,
                requiresInitialUnreadInteractionInfo: false,
                requireRecentReactionEmojiUpdate: false
            )
        )
        dataCache.insert(
            Profile.with(
                id: "0588672ccb97f40bb57238989226cf429b575ba355443f47bc76c5ab144a96c65b",
                name: "TestUser",
                proFeatures: .proBadge
            )
        )
        dataCache.setCurrentUserSessionIds([
            threadId: ["0588672ccb97f40bb57238989226cf429b575ba355443f47bc76c5ab144a961111"]
        ])
        
        let result = MessageViewModel(
            optimisticMessageId: 0,
            interaction: Interaction(
                threadId: "d4f1g54sdf5g1d5f4g65ds4564df65f4g65d54gdfsg",
                threadVariant: .contact,
                authorId: "d4f1g54sdf5g1d5f4g65ds4564df65f4g65d54gdfsg",
                variant: .standardIncoming,
                body: "Mauris sapien dui, sagittis et fringilla eget, tincidunt vel mauris. Mauris bibendum quis ipsum ac pulvinar. Integer semper elit vitae placerat efficitur. Quisque blandit scelerisque orci, a fringilla dui. In a sollicitudin tortor. Vivamus consequat sollicitudin felis, nec pretium dolor bibendum sit amet. Integer non congue risus, id imperdiet diam. Proin elementum enim at felis commodo semper. Pellentesque magna magna, laoreet nec hendrerit in, suscipit sit amet risus. Nulla et imperdiet massa. Donec commodo felis quis arcu dignissim lobortis. Praesent nec fringilla felis, ut pharetra sapien. Donec ac dignissim nisi, non lobortis justo. Nulla congue velit nec sodales bibendum. Nullam feugiat, mauris ac consequat posuere, eros sem dignissim nulla, ac convallis dolor sem rhoncus dolor. Cras ut luctus risus, quis viverra mauris.",
                timestampMs: dependencies[cache: .snodeAPI].currentOffsetTimestampMs(),
                state: .failed,
                proMessageFeatures: .largerCharacterLimit,
                using: dependencies
            ),
            reactionInfo: nil,
            maybeUnresolvedQuotedInfo: nil,
            userSessionId: SessionId(
                .standard,
                hex: "0588672ccb97f40bb57238989226cf429b575ba355443f47bc76c5ab144a961111"
            ),
            threadInfo: ConversationInfoViewModel(
                thread: SessionThread(
                    id: "d4f1g54sdf5g1d5f4g65ds4564df65f4g65d54gdfsg",
                    variant: .contact,
                    creationDateTimestamp: 0
                ),
                dataCache: dataCache,
                using: dependencies
            ),
            dataCache: dataCache,
            previousInteraction: nil,
            nextInteraction: nil,
            isLast: true,
            isLastOutgoing: false,
            currentUserMentionImage: nil,
            using: dependencies
        )
        
        return result!
    }
    
    static var actions: [ContextMenuVC.Action] {
        return [
            .reply(messageViewModel, nil),
            .retry(messageViewModel, nil),
            .delete(messageViewModel, nil)
        ]
    }
    
    static var previews: some View {
        MessageInfoScreen(
            actions: actions,
            messageViewModel: messageViewModel,
            threadCanWrite: true,
            openGroupServer: nil,
            openGroupPublicKey: nil,
            onStartThread: nil,
            using: Dependencies.createEmpty()
        )
    }
}
