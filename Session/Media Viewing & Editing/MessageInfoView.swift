// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import SessionUIKit
import SessionSnodeKit
import SessionUtilitiesKit
import SessionMessagingKit

struct MessageInfoView: View {
    @Environment(\.viewController) private var viewControllerHolder: UIViewController?
    
    @State var index = 1
    @State var showingAttachmentFullScreen = false
    
    static private let cornerRadius: CGFloat = 17
    
    var actions: [ContextMenuVC.Action]
    var messageViewModel: MessageViewModel
    var isMessageFailed: Bool {
        return [.failed, .failedToSync].contains(messageViewModel.state)
    }
    
    var dismiss: (() -> Void)?
    
    var body: some View {
        NavigationView {
            ZStack (alignment: .topLeading) {
                if #available(iOS 14.0, *) {
                    ThemeManager.currentTheme.colorSwiftUI(for: .backgroundPrimary).ignoresSafeArea()
                } else {
                    ThemeManager.currentTheme.colorSwiftUI(for: .backgroundPrimary)
                }
                
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(
                        alignment: .leading,
                        spacing: 10
                    ) {
                        // Message bubble snapshot
                        MessageBubble(
                            messageViewModel: messageViewModel
                        )
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: .infinity,
                            alignment: .topLeading
                        )
                        .fixedSize(horizontal: true, vertical: true)
                        .padding(.top, Values.smallSpacing)
                        .padding(.bottom, Values.verySmallSpacing)
                        .padding(.horizontal, Values.largeSpacing)
                        
                        
                        if isMessageFailed {
                            let (image, statusText, tintColor) = messageViewModel.state.statusIconInfo(
                                variant: messageViewModel.variant,
                                hasAtLeastOneReadReceipt: messageViewModel.hasAtLeastOneReadReceipt
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
                            let attachment: Attachment = attachments[(index - 1 + attachments.count) % attachments.count]
                            
                            ZStack(alignment: .bottomTrailing) {
                                if attachments.count > 1 {
                                    // Attachment carousel view
                                    SessionCarouselView_SwiftUI(
                                        index: $index,
                                        isOutgoing: (messageViewModel.variant == .standardOutgoing),
                                        contentInfos: attachments
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
                                        cornerRadius: 0
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
                                
                                Button {
                                    self.viewControllerHolder?.present(style: .fullScreen) {
                                        MediaGalleryViewModel.createDetailViewSwiftUI(
                                            for: messageViewModel.threadId,
                                            threadVariant: messageViewModel.threadVariant,
                                            interactionId: messageViewModel.id,
                                            selectedAttachmentId: attachment.id,
                                            options: [ .sliderEnabled ]
                                        )
                                    }
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
                            .padding(.vertical, Values.verySmallSpacing)
                            
                            // Attachment Info
                            ZStack {
                                RoundedRectangle(cornerRadius: Self.cornerRadius)
                                    .fill(themeColor: .backgroundSecondary)
                                    
                                VStack(
                                    alignment: .leading,
                                    spacing: Values.mediumSpacing
                                ) {
                                    InfoBlock(title: "ATTACHMENT_INFO_FILE_ID".localized() + ":") {
                                        Text(attachment.serverId ?? "")
                                            .font(.system(size: Values.mediumFontSize))
                                            .foregroundColor(themeColor: .textPrimary)
                                    }
                                    
                                    HStack(
                                        alignment: .center
                                    ) {
                                        InfoBlock(title: "ATTACHMENT_INFO_FILE_TYPE".localized() + ":") {
                                            Text(attachment.contentType)
                                                .font(.system(size: Values.mediumFontSize))
                                                .foregroundColor(themeColor: .textPrimary)
                                        }
                                        
                                        Spacer()
                                        
                                        InfoBlock(title: "ATTACHMENT_INFO_FILE_SIZE".localized() + ":") {
                                            Text(Format.fileSize(attachment.byteCount))
                                                .font(.system(size: Values.mediumFontSize))
                                                .foregroundColor(themeColor: .textPrimary)
                                        }
                                        
                                        Spacer()
                                    }
                                    HStack(
                                        alignment: .center
                                    ) {
                                        let resolution: String = {
                                            guard let width = attachment.width, let height = attachment.height else { return "N/A" }
                                            return "\(width)×\(height)"
                                        }()
                                        InfoBlock(title: "ATTACHMENT_INFO_RESOLUTION".localized() + ":") {
                                            Text(resolution)
                                                .font(.system(size: Values.mediumFontSize))
                                                .foregroundColor(themeColor: .textPrimary)
                                        }
                                        
                                        Spacer()
                                        
                                        let duration: String = {
                                            guard let duration = attachment.duration else { return "N/A" }
                                            return floor(duration).formatted(format: .videoDuration)
                                        }()
                                        InfoBlock(title: "ATTACHMENT_INFO_DURATION".localized() + ":") {
                                            Text(duration)
                                                .font(.system(size: Values.mediumFontSize))
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
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.vertical, Values.verySmallSpacing)
                            .padding(.horizontal, Values.largeSpacing)
                        }

                        // Message Info
                        ZStack {
                            RoundedRectangle(cornerRadius: Self.cornerRadius)
                                .fill(themeColor: .backgroundSecondary)
                                
                            VStack(
                                alignment: .leading,
                                spacing: Values.mediumSpacing
                            ) {
                                InfoBlock(title: "MESSAGE_INFO_SENT".localized() + ":") {
                                    Text(messageViewModel.dateForUI.fromattedForMessageInfo)
                                        .font(.system(size: Values.mediumFontSize))
                                        .foregroundColor(themeColor: .textPrimary)
                                }
                                
                                InfoBlock(title: "MESSAGE_INFO_RECEIVED".localized() + ":") {
                                    Text(messageViewModel.receivedDateForUI.fromattedForMessageInfo)
                                        .font(.system(size: Values.mediumFontSize))
                                        .foregroundColor(themeColor: .textPrimary)
                                }
                                
                                if isMessageFailed {
                                    let failureText: String = messageViewModel.mostRecentFailureText ?? "Message failed to send"
                                    InfoBlock(title: "ALERT_ERROR_TITLE".localized() + ":") {
                                        Text(failureText)
                                            .font(.system(size: Values.mediumFontSize))
                                            .foregroundColor(themeColor: .danger)
                                    }
                                }
                                
                                InfoBlock(title: "MESSAGE_INFO_FROM".localized() + ":") {
                                    HStack(
                                        spacing: 10
                                    ) {
                                        let (info, additionalInfo) = ProfilePictureView.getProfilePictureInfo(
                                            size: .message,
                                            publicKey: messageViewModel.authorId,
                                            threadVariant: .contact,    // Always show the display picture in 'contact' mode
                                            customImageData: nil,
                                            profile: messageViewModel.profile,
                                            profileIcon: (messageViewModel.isSenderOpenGroupModerator ? .crown : .none)
                                        )
                                        
                                        let size: ProfilePictureView.Size = .list
                                        
                                        if let info: ProfilePictureView.Info = info {
                                            ProfilePictureSwiftUI(
                                                size: size,
                                                info: info,
                                                additionalInfo: additionalInfo
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
                                            if !messageViewModel.authorName.isEmpty  {
                                                Text(messageViewModel.authorName)
                                                    .bold()
                                                    .font(.system(size: Values.mediumLargeFontSize))
                                                    .foregroundColor(themeColor: .textPrimary)
                                            }
                                            Text(messageViewModel.authorId)
                                                .font(.spaceMono(size: Values.mediumFontSize))
                                                .foregroundColor(themeColor: .textPrimary)
                                        }
                                    }
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
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, Values.verySmallSpacing)
                        .padding(.horizontal, Values.largeSpacing)

                        // Actions
                        if !actions.isEmpty {
                            ZStack {
                                RoundedRectangle(cornerRadius: Self.cornerRadius)
                                    .fill(themeColor: .backgroundSecondary)
                                
                                VStack(
                                    alignment: .leading,
                                    spacing: 0
                                ) {
                                    ForEach(
                                        0...(actions.count - 1),
                                        id: \.self
                                    ) { index in
                                        let tintColor: ThemeValue = actions[index].isDestructive ? .danger : .textPrimary
                                        Button(
                                            action: {
                                                actions[index].work()
                                                dismiss?()
                                            },
                                            label: {
                                                HStack(spacing: Values.largeSpacing) {
                                                    Image(uiImage: actions[index].icon!.withRenderingMode(.alwaysTemplate))
                                                        .resizable()
                                                        .scaledToFit()
                                                        .foregroundColor(themeColor: tintColor)
                                                        .frame(width: 26, height: 26)
                                                    Text(actions[index].title)
                                                        .bold()
                                                        .font(.system(size: Values.mediumLargeFontSize))
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
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.vertical, Values.verySmallSpacing)
                            .padding(.horizontal, Values.largeSpacing)
                        }
                    }
                }
            }
        }
    }
}

struct MessageBubble: View {
    static private let cornerRadius: CGFloat = 18
    
    let messageViewModel: MessageViewModel
    var bubbleBackgroundColor: ThemeValue {
        messageViewModel.variant == .standardIncoming || messageViewModel.variant == .standardIncomingDeleted ?
            .messageBubble_incomingBackground :
            .messageBubble_outgoingBackground
    }
    
    var body: some View {
        ZStack {
            switch messageViewModel.cellType {
                case .typingIndicator, .dateHeader, .unreadMarker: break
                
                case .textOnlyMessage:
                    let inset: CGFloat = 12
                    let maxWidth: CGFloat = (VisibleMessageCell.getMaxWidth(for: messageViewModel) - 2 * inset)
                    
                    if let linkPreview: LinkPreview = messageViewModel.linkPreview {
                        switch linkPreview.variant {
                            case .standard:
                                let linkPreviewView: LinkPreviewView = LinkPreviewView(maxWidth: maxWidth)
                                linkPreviewView.update(
                                    with: LinkPreview.SentState(
                                        linkPreview: linkPreview,
                                        imageAttachment: messageViewModel.linkPreviewAttachment
                                    ),
                                    isOutgoing: (messageViewModel.variant == .standardOutgoing),
                                    delegate: self,
                                    cellViewModel: messageViewModel,
                                    bodyLabelTextColor: bodyLabelTextColor,
                                    lastSearchText: lastSearchText
                                )
                                bubbleView.addSubview(linkPreviewView)
                                linkPreviewView.pin(to: bubbleView, withInset: 0)
                                snContentView.addArrangedSubview(bubbleBackgroundView)
                                self.bodyTappableLabel = linkPreviewView.bodyTappableLabel
                                
                            case .openGroupInvitation:
                                let openGroupInvitationView: OpenGroupInvitationView = OpenGroupInvitationView(
                                    name: (linkPreview.title ?? ""),
                                    url: linkPreview.url,
                                    textColor: bodyLabelTextColor,
                                    isOutgoing: (cellViewModel.variant == .standardOutgoing)
                                )
                                bubbleView.addSubview(openGroupInvitationView)
                                bubbleView.pin(to: openGroupInvitationView)
                                snContentView.addArrangedSubview(bubbleBackgroundView)
                        }
                    }
                    else {
                        // Stack view
                        let stackView = UIStackView(arrangedSubviews: [])
                        stackView.axis = .vertical
                        stackView.spacing = 2
                        
                        // Quote view
                        if let quote: Quote = cellViewModel.quote {
                            let hInset: CGFloat = 2
                            let quoteView: QuoteView = QuoteView(
                                for: .regular,
                                authorId: quote.authorId,
                                quotedText: quote.body,
                                threadVariant: cellViewModel.threadVariant,
                                currentUserPublicKey: cellViewModel.currentUserPublicKey,
                                currentUserBlinded15PublicKey: cellViewModel.currentUserBlinded15PublicKey,
                                currentUserBlinded25PublicKey: cellViewModel.currentUserBlinded25PublicKey,
                                direction: (cellViewModel.variant == .standardOutgoing ?
                                    .outgoing :
                                    .incoming
                                ),
                                attachment: cellViewModel.quoteAttachment,
                                hInset: hInset,
                                maxWidth: maxWidth
                            )
                            let quoteViewContainer = UIView(wrapping: quoteView, withInsets: UIEdgeInsets(top: 0, leading: hInset, bottom: 0, trailing: hInset))
                            stackView.addArrangedSubview(quoteViewContainer)
                        }
                        
                        // Body text view
                        let bodyTappableLabel = VisibleMessageCell.getBodyTappableLabel(
                            for: cellViewModel,
                            with: maxWidth,
                            textColor: bodyLabelTextColor,
                            searchText: lastSearchText,
                            delegate: self
                        )
                        self.bodyTappableLabel = bodyTappableLabel
                        stackView.addArrangedSubview(bodyTappableLabel)
                        
                        // Constraints
                        bubbleView.addSubview(stackView)
                        stackView.pin(to: bubbleView, withInset: inset)
                        stackView.widthAnchor.constraint(lessThanOrEqualToConstant: maxWidth).isActive = true
                        snContentView.addArrangedSubview(bubbleBackgroundView)
                    }
                    
                case .mediaMessage:
                    // Body text view
                    if let body: String = cellViewModel.body, !body.isEmpty {
                        let inset: CGFloat = 12
                        let maxWidth: CGFloat = (VisibleMessageCell.getMaxWidth(for: cellViewModel) - 2 * inset)
                        let bodyTappableLabel = VisibleMessageCell.getBodyTappableLabel(
                            for: cellViewModel,
                            with: maxWidth,
                            textColor: bodyLabelTextColor,
                            searchText: lastSearchText,
                            delegate: self
                        )

                        self.bodyTappableLabel = bodyTappableLabel
                        bubbleView.addSubview(bodyTappableLabel)
                        bodyTappableLabel.pin(to: bubbleView, withInset: inset)
                        snContentView.addArrangedSubview(bubbleBackgroundView)
                    }
                    
                    // Album view
                    let maxMessageWidth: CGFloat = VisibleMessageCell.getMaxWidth(for: cellViewModel)
                    let albumView = MediaAlbumView(
                        mediaCache: mediaCache,
                        items: (cellViewModel.attachments?
                            .filter { $0.isVisualMedia })
                            .defaulting(to: []),
                        isOutgoing: (cellViewModel.variant == .standardOutgoing),
                        maxMessageWidth: maxMessageWidth
                    )
                    self.albumView = albumView
                    let size = getSize(for: cellViewModel)
                    albumView.set(.width, to: size.width)
                    albumView.set(.height, to: size.height)
                    albumView.loadMedia()
                    snContentView.addArrangedSubview(albumView)
            
                    unloadContent = { albumView.unloadMedia() }
                    
                case .audio:
                    guard let attachment: Attachment = cellViewModel.attachments?.first(where: { $0.isAudio }) else {
                        return
                    }
                    
                    let voiceMessageView: VoiceMessageView = VoiceMessageView()
                    voiceMessageView.update(
                        with: attachment,
                        isPlaying: (playbackInfo?.state == .playing),
                        progress: (playbackInfo?.progress ?? 0),
                        playbackRate: (playbackInfo?.playbackRate ?? 1),
                        oldPlaybackRate: (playbackInfo?.oldPlaybackRate ?? 1)
                    )
                
                    bubbleView.addSubview(voiceMessageView)
                    voiceMessageView.pin(to: bubbleView)
                    snContentView.addArrangedSubview(bubbleBackgroundView)
                    self.voiceMessageView = voiceMessageView
                    
                case .genericAttachment:
                    guard let attachment: Attachment = cellViewModel.attachments?.first else { preconditionFailure() }
                    
                    let inset: CGFloat = 12
                    let maxWidth = (VisibleMessageCell.getMaxWidth(for: cellViewModel) - 2 * inset)
                    
                    // Stack view
                    let stackView = UIStackView(arrangedSubviews: [])
                    stackView.axis = .vertical
                    stackView.spacing = Values.smallSpacing
                    
                    // Document view
                    let documentView = DocumentView(attachment: attachment, textColor: bodyLabelTextColor)
                    stackView.addArrangedSubview(documentView)
                
                    // Body text view
                    if let body: String = cellViewModel.body, !body.isEmpty { // delegate should always be set at this point
                        let bodyContainerView: UIView = UIView()
                        let bodyTappableLabel = VisibleMessageCell.getBodyTappableLabel(
                            for: cellViewModel,
                            with: maxWidth,
                            textColor: bodyLabelTextColor,
                            searchText: lastSearchText,
                            delegate: self
                        )
                        
                        self.bodyTappableLabel = bodyTappableLabel
                        bodyContainerView.addSubview(bodyTappableLabel)
                        bodyTappableLabel.pin(.top, to: .top, of: bodyContainerView)
                        bodyTappableLabel.pin(.leading, to: .leading, of: bodyContainerView, withInset: 12)
                        bodyTappableLabel.pin(.trailing, to: .trailing, of: bodyContainerView, withInset: -12)
                        bodyTappableLabel.pin(.bottom, to: .bottom, of: bodyContainerView, withInset: -12)
                        stackView.addArrangedSubview(bodyContainerView)
                    }
                    
                    bubbleView.addSubview(stackView)
                    stackView.pin(to: bubbleView)
                    snContentView.addArrangedSubview(bubbleBackgroundView)
            }
                
        }
        .background(
            RoundedRectangle(cornerRadius: Self.cornerRadius)
                .fill(themeColor: bubbleBackgroundColor)
        )
    }
}

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
                .bold()
                .font(.system(size: Values.mediumLargeFontSize))
                .foregroundColor(themeColor: .textPrimary)
            self.content()
        }
        .frame(
            minWidth: minWidth,
            alignment: .leading
        )
    }
}

final class MessageInfoViewController: SessionHostingViewController<MessageInfoView> {
    init(actions: [ContextMenuVC.Action], messageViewModel: MessageViewModel) {
        let messageInfoView = MessageInfoView(
            actions: actions,
            messageViewModel: messageViewModel
        )
        
        super.init(rootView: messageInfoView)
        rootView.dismiss = dismiss
    }
    
    @MainActor required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        let customTitleFontSize = Values.largeFontSize
        setNavBarTitle("message_info_title".localized(), customFontSize: customTitleFontSize)
    }
    
    func dismiss() {
        self.navigationController?.popViewController(animated: true)
    }
}

struct MessageInfoView_Previews: PreviewProvider {
    static var messageViewModel: MessageViewModel {
        let result = MessageViewModel(
            optimisticMessageId: UUID(),
            threadId: "d4f1g54sdf5g1d5f4g65ds4564df65f4g65d54gdfsg",
            threadVariant: .contact,
            threadHasDisappearingMessagesEnabled: false,
            threadOpenGroupServer: nil,
            threadOpenGroupPublicKey: nil,
            threadContactNameInternal: "Test",
            timestampMs: SnodeAPI.currentOffsetTimestampMs(),
            receivedAtTimestampMs: SnodeAPI.currentOffsetTimestampMs(),
            authorId: "d4f1g54sdf5g1d5f4g65ds4564df65f4g65d54gdfsg",
            authorNameInternal: "Test",
            body: "Test Message",
            expiresStartedAtMs: nil,
            expiresInSeconds: nil,
            state: .failed,
            isSenderOpenGroupModerator: false,
            currentUserProfile: Profile.fetchOrCreateCurrentUser(),
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
            .reply(messageViewModel, nil, using: Dependencies()),
            .retry(messageViewModel, nil, using: Dependencies()),
            .delete(messageViewModel, nil, using: Dependencies())
        ]
    }
    
    static var previews: some View {
        MessageInfoView(
            actions: actions,
            messageViewModel: messageViewModel
        )
    }
}
