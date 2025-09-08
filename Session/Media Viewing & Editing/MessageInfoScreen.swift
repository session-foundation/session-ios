// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import SessionUIKit
import SessionSnodeKit
import SessionUtilitiesKit
import SessionMessagingKit
import Lucide

struct MessageInfoScreen: View {
    @EnvironmentObject var host: HostWrapper
    
    @State var index = 1
    @State var feedbackMessage: String? = nil
    @State var isExpanded: Bool = false
    
    static private let cornerRadius: CGFloat = 17
    
    var actions: [ContextMenuVC.Action]
    var messageViewModel: MessageViewModel
    let threadCanWrite: Bool
    let onStartThread: (() -> Void)?
    let dependencies: Dependencies
    let isMessageFailed: Bool
    let isCurrentUser: Bool
    let profileInfo: ProfilePictureView.Info?
    var proFeatures: [String] = []
    var proCTAVariant: ProCTAModal.Variant = .generic
    
    public init(
        actions: [ContextMenuVC.Action],
        messageViewModel: MessageViewModel,
        threadCanWrite: Bool,
        onStartThread: (() -> Void)?,
        using dependencies: Dependencies
    ) {
        self.actions = actions
        self.messageViewModel = messageViewModel
        self.threadCanWrite = threadCanWrite
        self.onStartThread = onStartThread
        self.dependencies = dependencies
        
        self.isMessageFailed = [.failed, .failedToSync].contains(messageViewModel.state)
        self.isCurrentUser = (messageViewModel.currentUserSessionIds ?? []).contains(messageViewModel.authorId)
        self.profileInfo = ProfilePictureView.getProfilePictureInfo(
            size: .message,
            publicKey: (
                // Prioritise the profile.id because we override it for
                // messages sent by the current user in communities
                messageViewModel.profile?.id ??
                messageViewModel.authorId
            ),
            threadVariant: .contact,    // Always show the display picture in 'contact' mode
            displayPictureUrl: nil,
            profile: messageViewModel.profile,
            profileIcon: (messageViewModel.isSenderModeratorOrAdmin ? .crown : .none),
            using: dependencies
        ).info
        
        (self.proFeatures, self.proCTAVariant) = getProFeaturesInfo()
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
                            messageViewModel: messageViewModel,
                            attachmentOnly: false,
                            dependencies: dependencies
                        )
                        .clipShape(
                            RoundedRectangle(cornerRadius: Self.cornerRadius)
                        )
                        .background(
                            RoundedRectangle(cornerRadius: Self.cornerRadius)
                                .fill(
                                    themeColor: (messageViewModel.variant == .standardIncoming || messageViewModel.variant == .standardIncomingDeleted || messageViewModel.variant == .standardIncomingDeletedLocally ?
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
                        
                        
                        if isMessageFailed {
                            let (image, statusText, tintColor) = messageViewModel.state.statusIconInfo(
                                variant: messageViewModel.variant,
                                hasBeenReadByRecipient: messageViewModel.hasBeenReadByRecipient,
                                hasAttachments: (messageViewModel.attachments?.isEmpty == false)
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
                            .padding(.top, -Values.smallSpacing)
                            .padding(.bottom, Values.verySmallSpacing)
                            .padding(.horizontal, Values.largeSpacing)
                        }
                        
                        if let attachments = messageViewModel.attachments {
                            switch messageViewModel.cellType {
                                case .mediaMessage:
                                    let attachment: Attachment = attachments[(index - 1 + attachments.count) % attachments.count]
                                    
                                    ZStack(alignment: .bottomTrailing) {
                                        if attachments.count > 1 {
                                            // Attachment carousel view
                                            SessionCarouselView_SwiftUI(
                                                index: $index,
                                                isOutgoing: (messageViewModel.variant == .standardOutgoing),
                                                contentInfos: attachments,
                                                using: dependencies
                                            )
                                            .frame(
                                                maxWidth: .infinity,
                                                maxHeight: .infinity,
                                                alignment: .topLeading
                                            )
                                        } else {
                                            MediaView_SwiftUI(
                                                attachment: attachments[0],
                                                isOutgoing: (messageViewModel.variant == .standardOutgoing),
                                                shouldSupressControls: true,
                                                cornerRadius: 0,
                                                using: dependencies
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
                                        messageViewModel: messageViewModel,
                                        attachmentOnly: true,
                                        dependencies: dependencies
                                    )
                                    .clipShape(
                                        RoundedRectangle(cornerRadius: Self.cornerRadius)
                                    )
                                    .background(
                                        RoundedRectangle(cornerRadius: Self.cornerRadius)
                                            .fill(
                                                themeColor: (messageViewModel.variant == .standardIncoming || messageViewModel.variant == .standardIncomingDeleted || messageViewModel.variant == .standardIncomingDeletedLocally ?
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
                    if let attachments = messageViewModel.attachments, !attachments.isEmpty {
                        let attachment: Attachment = attachments[(index - 1 + attachments.count) % attachments.count]
                        
                        ZStack {
                            VStack(
                                alignment: .leading,
                                spacing: Values.mediumSpacing
                            ) {
                                InfoBlock(title: "attachmentsFileId".localized()) {
                                    Text(attachment.downloadUrl.map { Attachment.fileId(for: $0) } ?? "")
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
                            if proFeatures.count > 0 {
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
                                    .onTapGesture {
                                        showSessionProCTAIfNeeded()
                                    }
                                    
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
                                        ForEach(self.proFeatures, id: \.self) { feature in
                                            HStack(spacing: Values.smallSpacing) {
                                                AttributedText(Lucide.Icon.circleCheck.attributedString(size: 17))
                                                    .font(.system(size: 17))
                                                    .foregroundColor(themeColor: .primary)
                                                
                                                Text(feature)
                                                    .font(.Body.largeRegular)
                                                    .foregroundColor(themeColor: .textPrimary)
                                            }
                                        }
                                    }
                                }
                            }
                            
                            InfoBlock(title: "sent".localized()) {
                                Text(messageViewModel.dateForUI.fromattedForMessageInfo)
                                    .font(.Body.largeRegular)
                                    .foregroundColor(themeColor: .textPrimary)
                            }
                            
                            InfoBlock(title: "received".localized()) {
                                Text(messageViewModel.receivedDateForUI.fromattedForMessageInfo)
                                    .font(.Body.largeRegular)
                                    .foregroundColor(themeColor: .textPrimary)
                            }
                            
                            if isMessageFailed {
                                let failureText: String = messageViewModel.mostRecentFailureText ?? "messageStatusFailedToSend".localized()
                                InfoBlock(title: "theError".localized() + ":") {
                                    Text(failureText)
                                        .font(.Body.largeRegular)
                                        .foregroundColor(themeColor: .danger)
                                }
                            }
                            
                            InfoBlock(title: "from".localized()) {
                                HStack(
                                    spacing: 10
                                ) {
                                    let size: ProfilePictureView.Size = .list
                                    if let info: ProfilePictureView.Info = self.profileInfo {
                                        ProfilePictureSwiftUI(
                                            size: size,
                                            info: info,
                                            additionalInfo: nil,
                                            dataManager: dependencies[singleton: .imageDataManager]
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
                                            if isCurrentUser {
                                                Text("you".localized())
                                                    .font(.Body.extraLargeBold)
                                                    .foregroundColor(themeColor: .textPrimary)
                                            }
                                            else if !messageViewModel.authorName.isEmpty {
                                                Text(messageViewModel.authorName)
                                                    .font(.Body.extraLargeBold)
                                                    .foregroundColor(themeColor: .textPrimary)
                                            }
                                            
                                            if (dependencies.mutate(cache: .libSession) { $0.validateSessionProState(for: messageViewModel.authorId)}) {
                                                SessionProBadge_SwiftUI(size: .small)
                                                    .onTapGesture {
                                                        showSessionProCTAIfNeeded()
                                                    }
                                            }
                                        }
                                        
                                        Text(messageViewModel.authorId)
                                            .font(.Display.base)
                                            .foregroundColor(themeColor: .textPrimary)
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
                    if !actions.isEmpty {
                        ZStack {
                            VStack(
                                alignment: .leading,
                                spacing: 0
                            ) {
                                ForEach(
                                    0...(actions.count - 1),
                                    id: \.self
                                ) { index in
                                    let tintColor: ThemeValue = actions[index].themeColor
                                    Button(
                                        action: {
                                            actions[index].work() {
                                                switch (actions[index].shouldDismissInfoScreen, actions[index].feedback) {
                                                    case (false, _): break
                                                    case (true, .some):
                                                        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: {
                                                            dismiss()
                                                        })
                                                    default: dismiss()
                                                }
                                            }
                                            feedbackMessage = actions[index].feedback
                                        },
                                        label: {
                                            HStack(spacing: Values.largeSpacing) {
                                                Image(uiImage: actions[index].icon!.withRenderingMode(.alwaysTemplate))
                                                    .resizable()
                                                    .scaledToFit()
                                                    .foregroundColor(themeColor: tintColor)
                                                    .frame(width: 26, height: 26)
                                                Text(actions[index].title)
                                                    .font(.Headings.H8)
                                                    .foregroundColor(themeColor: tintColor)
                                            }
                                            .frame(maxWidth: .infinity, alignment: .topLeading)
                                        }
                                    )
                                    .frame(height: 60)
                                    
                                    if index < (actions.count - 1) {
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
    
    private func getProFeaturesInfo() -> (proFeatures: [String], proCTAVariant: ProCTAModal.Variant) {
        var proFeatures: [String] = []
        var proCTAVariant: ProCTAModal.Variant = .generic
        
        guard dependencies[feature: .sessionProEnabled] else { return (proFeatures, proCTAVariant) }
        
        if (dependencies.mutate(cache: .libSession) { $0.shouldShowProBadge(for: messageViewModel.profile) }) {
            proFeatures.append("appProBadge".put(key: "app_pro", value: Constants.app_pro).localized())
        }
        
        if (messageViewModel.isProMessage || messageViewModel.body.defaulting(to: "").utf16.count > LibSession.CharacterLimit) {
            proFeatures.append("proIncreasedMessageLengthFeature".localized())
            proCTAVariant = (proFeatures.count > 1 ? .generic : .longerMessages)
        }
        
        if ImageDataManager.isAnimatedImage(profileInfo?.source?.imageData) {
            proFeatures.append("proAnimatedDisplayPictureFeature".localized())
            proCTAVariant = (proFeatures.count > 1 ? .generic : .animatedProfileImage(isSessionProActivated: false))
        }
        
        return (proFeatures, proCTAVariant)
    }
    
    private func showSessionProCTAIfNeeded() {
        guard dependencies[feature: .sessionProEnabled] && (!dependencies[cache: .libSession].isSessionPro) else {
            return
        }
        let sessionProModal: ModalHostingViewController = ModalHostingViewController(
            modal: ProCTAModal(
                variant: proCTAVariant,
                dataManager: dependencies[singleton: .imageDataManager],
                onConfirm: { [dependencies] in
                    dependencies[singleton: .sessionProState].upgradeToPro(completion: nil)
                }
            )
        )
        self.host.controller?.present(sessionProModal, animated: true)
    }
    
    func showUserProfileModal() {
        guard threadCanWrite else { return }
        // FIXME: Add in support for starting a thread with a 'blinded25' id (disabled until we support this decoding)
        guard (try? SessionId.Prefix(from: messageViewModel.authorId)) != .blinded25 else { return }
        
        guard let profileInfo: ProfilePictureView.Info = ProfilePictureView.getProfilePictureInfo(
            size: .message,
            publicKey: (
                // Prioritise the profile.id because we override it for
                // messages sent by the current user in communities
                messageViewModel.profile?.id ??
                messageViewModel.authorId
            ),
            threadVariant: .contact,    // Always show the display picture in 'contact' mode
            displayPictureUrl: nil,
            profile: messageViewModel.profile,
            profileIcon: .none,
            using: dependencies
        ).info else {
            return
        }
        
        let (sessionId, blindedId): (String?, String?) = {
            guard (try? SessionId.Prefix(from: messageViewModel.authorId)) == .blinded15 else {
                return (messageViewModel.authorId, nil)
            }
            let lookup: BlindedIdLookup? = dependencies[singleton: .storage].read { db in
                try? BlindedIdLookup.fetchOne(db, id: messageViewModel.authorId)
            }
            return (lookup?.sessionId, messageViewModel.authorId)
        }()
        
        let qrCodeImage: UIImage? = {
            guard let sessionId: String = sessionId else { return nil }
            return QRCode.generate(for: sessionId, hasBackground: false, iconName: "SessionWhite40") // stringlint:ignore
        }()
        
        let isMessasgeRequestsEnabled: Bool = {
            guard messageViewModel.threadVariant == .community else { return true }
            return messageViewModel.profile?.blocksCommunityMessageRequests != true
        }()
        
        let userProfileModal: ModalHostingViewController = ModalHostingViewController(
            modal: UserProfileModel(
                info: .init(
                    sessionId: sessionId,
                    blindedId: blindedId,
                    qrCodeImage: qrCodeImage,
                    profileInfo: profileInfo,
                    displayName: messageViewModel.authorName,
                    nickname: messageViewModel.profile?.displayName(
                        for: messageViewModel.threadVariant,
                        ignoringNickname: true
                    ),
                    isProUser: dependencies.mutate(cache: .libSession, { $0.validateProProof(for: messageViewModel.profile) }),
                    isMessageRequestsEnabled: isMessasgeRequestsEnabled,
                    onStartThread: self.onStartThread,
                    onProBadgeTapped: self.showSessionProCTAIfNeeded
                ),
                dataManager: dependencies[singleton: .imageDataManager]
            )
        )
        self.host.controller?.present(userProfileModal, animated: true, completion: nil)
    }
    
    private func showMediaFullScreen(attachment: Attachment) {
        if let mediaGalleryView = MediaGalleryViewModel.createDetailViewController(
            for: messageViewModel.threadId,
            threadVariant: messageViewModel.threadVariant,
            interactionId: messageViewModel.id,
            selectedAttachmentId: attachment.id,
            options: [ .sliderEnabled ],
            useTransitioningDelegate: false,
            using: dependencies
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
            let maxWidth: CGFloat = (VisibleMessageCell.getMaxWidth(for: messageViewModel, includingOppositeGutter: false) - 2 * Self.inset)
            let maxHeight: CGFloat = VisibleMessageCell.getMaxHeightAfterTruncation(for: messageViewModel)
            let height: CGFloat = VisibleMessageCell.getBodyTappableLabel(
                for: messageViewModel,
                with: maxWidth,
                textColor: bodyLabelTextColor,
                searchText: nil,
                delegate: nil,
                using: dependencies
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
                                    state: LinkPreview.SentState(
                                        linkPreview: linkPreview,
                                        imageAttachment: messageViewModel.linkPreviewAttachment,
                                        using: dependencies
                                    ),
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
                        if let quote = messageViewModel.quote {
                            QuoteView_SwiftUI(
                                info: .init(
                                    mode: .regular,
                                    authorId: quote.authorId,
                                    quotedText: quote.body,
                                    threadVariant: messageViewModel.threadVariant,
                                    currentUserSessionIds: (messageViewModel.currentUserSessionIds ?? []),
                                    direction: (messageViewModel.variant == .standardOutgoing ? .outgoing : .incoming),
                                    attachment: messageViewModel.quoteAttachment
                                ),
                                using: dependencies
                            )
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, Self.inset)
                            .padding(.horizontal, Self.inset)
                            .padding(.bottom, (messageViewModel.body?.isEmpty == false ?
                                -Values.smallSpacing :
                                Self.inset
                            ))
                        }
                    }
                    
                    if let bodyText: ThemedAttributedString = VisibleMessageCell.getBodyAttributedText(
                        for: messageViewModel,
                        textColor: bodyLabelTextColor,
                        searchText: nil,
                        using: dependencies
                    ) {
                        TappableLabel_SwiftUI(themeAttributedText: bodyText, maxWidth: maxWidth)
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
                            if let attachment: Attachment = messageViewModel.attachments?.first(where: { $0.isAudio }){
                                // TODO: Playback Info and check if playing function is needed
                                VoiceMessageView_SwiftUI(attachment: attachment)
                                    .padding(.top, Self.inset)
                            }
                        case .audio, .genericAttachment:
                            if let attachment: Attachment = messageViewModel.attachments?.first {
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
        onStartThread: (() -> Void)?,
        using dependencies: Dependencies
    ) {
        let messageInfoView = MessageInfoScreen(
            actions: actions,
            messageViewModel: messageViewModel,
            threadCanWrite: threadCanWrite,
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
        let result = MessageViewModel(
            optimisticMessageId: UUID(),
            threadId: "d4f1g54sdf5g1d5f4g65ds4564df65f4g65d54gdfsg",
            threadVariant: .contact,
            threadExpirationType: nil,
            threadExpirationTimer: nil,
            threadOpenGroupServer: nil,
            threadOpenGroupPublicKey: nil,
            threadContactNameInternal: "Test",
            timestampMs: dependencies[cache: .snodeAPI].currentOffsetTimestampMs(),
            receivedAtTimestampMs: dependencies[cache: .snodeAPI].currentOffsetTimestampMs(),
            authorId: "d4f1g54sdf5g1d5f4g65ds4564df65f4g65d54gdfsg",
            authorNameInternal: "Test",
            body: "Mauris sapien dui, sagittis et fringilla eget, tincidunt vel mauris. Mauris bibendum quis ipsum ac pulvinar. Integer semper elit vitae placerat efficitur. Quisque blandit scelerisque orci, a fringilla dui. In a sollicitudin tortor. Vivamus consequat sollicitudin felis, nec pretium dolor bibendum sit amet. Integer non congue risus, id imperdiet diam. Proin elementum enim at felis commodo semper. Pellentesque magna magna, laoreet nec hendrerit in, suscipit sit amet risus. Nulla et imperdiet massa. Donec commodo felis quis arcu dignissim lobortis. Praesent nec fringilla felis, ut pharetra sapien. Donec ac dignissim nisi, non lobortis justo. Nulla congue velit nec sodales bibendum. Nullam feugiat, mauris ac consequat posuere, eros sem dignissim nulla, ac convallis dolor sem rhoncus dolor. Cras ut luctus risus, quis viverra mauris.",
            expiresStartedAtMs: nil,
            expiresInSeconds: nil,
            isProMessage: true,
            state: .failed,
            isSenderModeratorOrAdmin: false,
            currentUserProfile: Profile(
                id: "0588672ccb97f40bb57238989226cf429b575ba355443f47bc76c5ab144a96c65b",
                name: "TestUser"
            ),
            quote: nil,
            quoteAttachment: nil,
            linkPreview: nil,
            linkPreviewAttachment: nil,
            attachments: nil
        )
        
        return result
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
            onStartThread: nil,
            using: Dependencies.createEmpty()
        )
    }
}
