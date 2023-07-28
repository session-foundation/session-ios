// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import SessionUIKit
import SessionSnodeKit

struct MessageInfoView: View {
    @State var index = 1
    var actions: [ContextMenuVC.Action]
    var messageViewModel: MessageViewModel
    var isMessageFailed: Bool {
        return [.failed, .failedToSync].contains(messageViewModel.state)
    }
    
    var body: some View {
        ZStack (alignment: .topLeading) {
            if #available(iOS 14.0, *) {
                Color.black.ignoresSafeArea()
            } else {
                Color.black
            }
            
            ScrollView(.vertical, showsIndicators: false) {
                VStack(
                    alignment: .leading,
                    spacing: 10
                ) {
                    // Message bubble snapshot
                    if let body: String = messageViewModel.body {
                        let (bubbleBackgroundColor, bubbleTextColor): (ThemeValue, ThemeValue) = (
                            messageViewModel.variant == .standardIncoming ||
                            messageViewModel.variant == .standardIncomingDeleted
                        ) ?
                        (.messageBubble_incomingBackground, .messageBubble_incomingText) :
                        (.messageBubble_outgoingBackground, .messageBubble_outgoingText)
                        
                        ZStack {
                            RoundedRectangle(cornerRadius: 18)
                                .fill(themeColor: bubbleBackgroundColor)
                            
                            Text(body)
                                .foregroundColor(themeColor: bubbleTextColor)
                                .padding(
                                    EdgeInsets(
                                        top: 8,
                                        leading: 16,
                                        bottom: 8,
                                        trailing: 16
                                    )
                                )
                        }
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: .infinity,
                            alignment: .topLeading
                        )
                        .fixedSize(horizontal: true, vertical: true)
                        .padding(
                            EdgeInsets(
                                top: 8,
                                leading: 30,
                                bottom: 4,
                                trailing: 30
                            )
                        )
                    }
                    
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
                                    .font(.system(size: 11))
                                    .foregroundColor(themeColor: tintColor)
                            }
                        }
                        .padding(
                            EdgeInsets(
                                top: -8,
                                leading: 30,
                                bottom: 4,
                                trailing: 30
                            )
                        )
                    }
                    
                    if let attachments = messageViewModel.attachments {
                        if attachments.count > 1 {
                            // Attachment carousel view
                            SessionCarouselView_SwiftUI(index: $index, contentInfos: [.orange, .gray, .blue, .yellow])
                                .frame(
                                    maxWidth: .infinity,
                                    maxHeight: .infinity,
                                    alignment: .topLeading
                                )
                                .padding(
                                    EdgeInsets(
                                        top: 4,
                                        leading: 0,
                                        bottom: 4,
                                        trailing: 0
                                    )
                                )
                        } else {
                            // TODO: one attachment
                        }
                        
                        // Attachment Info
                        ZStack {
                            RoundedRectangle(cornerRadius: 17)
                                .fill(Color(red: 27.0/255, green: 27.0/255, blue: 27.0/255))
                                
                            VStack(
                                alignment: .leading,
                                spacing: 16
                            ) {
                                InfoBlock(title: "ATTACHMENT_INFO_FILE_ID".localized() + ":") {
                                    Text("12378965485235985214")
                                        .font(.system(size: 16))
                                        .foregroundColor(themeColor: .textPrimary)
                                }
                                
                                HStack(
                                    alignment: .center
                                ) {
                                    InfoBlock(title: "ATTACHMENT_INFO_FILE_TYPE".localized() + ":") {
                                        Text(".PNG")
                                            .font(.system(size: 16))
                                            .foregroundColor(themeColor: .textPrimary)
                                    }
                                    
                                    Spacer()
                                    
                                    InfoBlock(title: "ATTACHMENT_INFO_FILE_SIZE".localized() + ":") {
                                        Text("6mb")
                                            .font(.system(size: 16))
                                            .foregroundColor(themeColor: .textPrimary)
                                    }
                                    
                                    Spacer()
                                }

                                HStack(
                                    alignment: .center
                                ) {
                                    InfoBlock(title: "ATTACHMENT_INFO_RESOLUTION".localized() + ":") {
                                        Text("550×550")
                                            .font(.system(size: 16))
                                            .foregroundColor(themeColor: .textPrimary)
                                    }
                                    
                                    Spacer()
                                    
                                    InfoBlock(title: "ATTACHMENT_INFO_DURATION".localized() + ":") {
                                        Text("N/A")
                                            .font(.system(size: 16))
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
                            .padding(
                                EdgeInsets(
                                    top: 24,
                                    leading: 24,
                                    bottom: 24,
                                    trailing: 24
                                )
                            )
                        }
                        .frame(maxHeight: .infinity)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(
                            EdgeInsets(
                                top: 4,
                                leading: 30,
                                bottom: 4,
                                trailing: 30
                            )
                        )
                    }

                    // Message Info
                    ZStack {
                        RoundedRectangle(cornerRadius: 17)
                            .fill(themeColor: .backgroundSecondary)
                            
                        VStack(
                            alignment: .leading,
                            spacing: 16
                        ) {
                            InfoBlock(title: "MESSAGE_INFO_SENT".localized() + ":") {
                                Text(messageViewModel.dateForUI.fromattedForMessageInfo)
                                    .font(.system(size: 16))
                                    .foregroundColor(themeColor: .textPrimary)
                            }
                            
                            InfoBlock(title: "MESSAGE_INFO_RECEIVED".localized() + ":") {
                                Text(messageViewModel.receivedDateForUI.fromattedForMessageInfo)
                                    .font(.system(size: 16))
                                    .foregroundColor(themeColor: .textPrimary)
                            }
                            
                            if isMessageFailed {
                                let failureText: String = messageViewModel.mostRecentFailureText ?? "Message failed to send"
                                InfoBlock(title: "ALERT_ERROR_TITLE".localized() + ":") {
                                    Text(failureText)
                                        .font(.system(size: 16))
                                        .foregroundColor(themeColor: .danger)
                                }
                            }
                            
                            InfoBlock(title: "MESSAGE_INFO_FROM".localized() + ":") {
                                HStack(
                                    spacing: 10
                                ) {
                                    Circle()
                                        .frame(
                                            width: 46,
                                            height: 46,
                                            alignment: .topLeading
                                        )
                                        .foregroundColor(themeColor: .primary)
    //                                ProfilePictureSwiftUI(size: .message)
                                        
                                        
                                    VStack(
                                        alignment: .leading,
                                        spacing: 4
                                    ) {
                                        if !messageViewModel.authorName.isEmpty  {
                                            Text(messageViewModel.authorName)
                                                .bold()
                                                .font(.system(size: 18))
                                                .foregroundColor(themeColor: .textPrimary)
                                        }
                                        Text(messageViewModel.authorId)
                                            .font(.spaceMono(size: 16))
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
                        .padding(
                            EdgeInsets(
                                top: 24,
                                leading: 24,
                                bottom: 24,
                                trailing: 24
                            )
                        )
                    }
                    .frame(maxHeight: .infinity)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(
                        EdgeInsets(
                            top: 4,
                            leading: 30,
                            bottom: 4,
                            trailing: 30
                        )
                    )

                    // Actions
                    if !actions.isEmpty {
                        ZStack {
                            RoundedRectangle(cornerRadius: 17)
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
                                    HStack(spacing: 24) {
                                        Image(uiImage: actions[index].icon!.withRenderingMode(.alwaysTemplate))
                                            .resizable()
                                            .scaledToFit()
                                            .foregroundColor(themeColor: tintColor)
                                            .frame(width: 26, height: 26)
                                        Text(actions[index].title)
                                            .bold()
                                            .font(.system(size: 18))
                                            .foregroundColor(themeColor: tintColor)
                                    }
                                    .frame(width: .infinity, height: 60)
                                    .onTapGesture {
                                        actions[index].work()
                                    }
                                    
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
                            .padding(
                                EdgeInsets(
                                    top: 0,
                                    leading: 24,
                                    bottom: 0,
                                    trailing: 24
                                )
                            )
                        }
                        .frame(maxHeight: .infinity)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(
                            EdgeInsets(
                                top: 4,
                                leading: 30,
                                bottom: 4,
                                trailing: 30
                            )
                        )
                    }
                }
            }
        }
    }
}

struct InfoBlock<Content>: View where Content: View {
    let title: String
    let content: () -> Content
    
    var body: some View {
        VStack(
            alignment: .leading,
            spacing: 4
        ) {
            Text(self.title)
                .bold()
                .font(.system(size: 18))
                .foregroundColor(themeColor: .textPrimary)
            self.content()
        }
        .frame(
            minWidth: 100,
            alignment: .leading
        )
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
            .reply(messageViewModel, nil),
            .retry(messageViewModel, nil),
            .delete(messageViewModel, nil)
        ]
    }
    
    static var previews: some View {
        MessageInfoView(
            actions: actions,
            messageViewModel: messageViewModel
        )
    }
}
