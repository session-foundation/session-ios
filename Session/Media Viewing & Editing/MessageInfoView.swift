// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import SessionUIKit
import SessionSnodeKit

struct MessageInfoView: View {
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
                        ZStack {
                            RoundedRectangle(cornerRadius: 18)
                                .fill(Color(red: 49.0/255, green: 241.0/255, blue: 150.0/255))
                            
                            Text(body)
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
                                    .foregroundColor(.red)
                                    .frame(width: 13, height: 12)
                            }
                            
                            if let statusText: String = statusText {
                                Text(statusText)
                                    .font(.system(size: 11))
                                    .foregroundColor(.red)
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
                    
                    // TODO: Attachment carousel view
                    if let attachments = messageViewModel.attachments, !attachments.isEmpty {
                        SessionCarouselView_SwiftUI(contentInfos: [.orange, .gray, .blue, .yellow])
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
                    }
                    
                    
                    // Attachment Info
                    if (messageViewModel.attachments?.isEmpty != false) {
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
                                        .foregroundColor(.white)
                                }
                                
                                HStack(
                                    alignment: .center
                                ) {
                                    InfoBlock(title: "ATTACHMENT_INFO_FILE_TYPE".localized() + ":") {
                                        Text(".PNG")
                                            .font(.system(size: 16))
                                            .foregroundColor(.white)
                                    }
                                    
                                    Spacer()
                                    
                                    InfoBlock(title: "ATTACHMENT_INFO_FILE_SIZE".localized() + ":") {
                                        Text("6mb")
                                            .font(.system(size: 16))
                                            .foregroundColor(.white)
                                    }
                                    
                                    Spacer()
                                }

                                HStack(
                                    alignment: .center
                                ) {
                                    InfoBlock(title: "ATTACHMENT_INFO_RESOLUTION".localized() + ":") {
                                        Text("550×550")
                                            .font(.system(size: 16))
                                            .foregroundColor(.white)
                                    }
                                    
                                    Spacer()
                                    
                                    InfoBlock(title: "ATTACHMENT_INFO_DURATION".localized() + ":") {
                                        Text("N/A")
                                            .font(.system(size: 16))
                                            .foregroundColor(.white)
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
                            .fill(Color(red: 27.0/255, green: 27.0/255, blue: 27.0/255))
                            
                        VStack(
                            alignment: .leading,
                            spacing: 16
                        ) {
                            InfoBlock(title: "Sent:") {
                                Text(messageViewModel.dateForUI.fromattedForMessageInfo)
                                    .font(.system(size: 16))
                                    .foregroundColor(.white)
                            }
                            
                            InfoBlock(title: "Received:") {
                                Text(messageViewModel.receivedDateForUI.fromattedForMessageInfo)
                                    .font(.system(size: 16))
                                    .foregroundColor(.white)
                            }
                            
                            if isMessageFailed {
                                let failureText: String = messageViewModel.mostRecentFailureText ?? "Message failed to send"
                                InfoBlock(title: "Error:") {
                                    Text(failureText)
                                        .font(.system(size: 16))
                                        .foregroundColor(.red)
                                }
                            }
                            
                            InfoBlock(title: "From:") {
                                HStack(
                                    spacing: 10
                                ) {
                                    Circle()
                                        .frame(
                                            width: 46,
                                            height: 46,
                                            alignment: .topLeading
                                        )
                                        .foregroundColor(Color(red: 49.0/255, green: 241.0/255, blue: 150.0/255))
    //                                ProfilePictureSwiftUI(size: .message)
                                        
                                        
                                    VStack(
                                        alignment: .leading,
                                        spacing: 4
                                    ) {
                                        Text(messageViewModel.senderName ?? "Tester")
                                            .bold()
                                            .font(.system(size: 18))
                                            .foregroundColor(.white)
                                        Text(messageViewModel.authorId)
                                            .font(.system(size: 16))
                                            .foregroundColor(.white)
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
                                .fill(Color(red: 27.0/255, green: 27.0/255, blue: 27.0/255))
                            
                            VStack(
                                alignment: .leading,
                                spacing: 0
                            ) {
                                ForEach(
                                    0...(actions.count - 1),
                                    id: \.self
                                ) { index in
                                    let tintColor: Color = actions[index].isDestructive ? .red : .white
                                    HStack(spacing: 24) {
                                        Image(uiImage: actions[index].icon!.withRenderingMode(.alwaysTemplate))
                                            .resizable()
                                            .scaledToFit()
                                            .foregroundColor(tintColor)
                                            .frame(width: 26, height: 26)
                                        Text(actions[index].title)
                                            .bold()
                                            .font(.system(size: 18))
                                            .foregroundColor(tintColor)
                                    }
                                    .frame(width: .infinity, height: 60)
                                    
                                    if index < (actions.count - 1) {
                                        Divider()
                                            .foregroundColor(.gray)
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
                .foregroundColor(.white)
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
