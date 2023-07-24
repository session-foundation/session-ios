// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import SessionUIKit
import SessionSnodeKit

struct MessageInfoView: View {
    var actions: [ContextMenuVC.Action]
    var messageViewModel: MessageViewModel
    
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
                    
                    if [.failed, .failedToSync].contains(messageViewModel.state) {
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
                    
                    // Attachment Info
                    if (messageViewModel.attachments?.isEmpty != false) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 17)
                                .fill(Color(red: 27.0/255, green: 27.0/255, blue: 27.0/255))
                                
                            VStack(
                                alignment: .leading,
                                spacing: 16
                            ) {
                                VStack(
                                    alignment: .leading,
                                    spacing: 4
                                ) {
                                    Text("ATTACHMENT_INFO_FILE_ID".localized() + ":")
                                        .bold()
                                        .font(.system(size: 18))
                                        .foregroundColor(.white)
                                    Text("12378965485235985214")
                                        .font(.system(size: 16))
                                        .foregroundColor(.white)
                                }
                                
                                HStack(
                                    alignment: .center,
                                    spacing: 48
                                ) {
                                    VStack(
                                        alignment: .leading,
                                        spacing: 4
                                    ) {
                                        Text("ATTACHMENT_INFO_FILE_TYPE".localized() + ":")
                                            .bold()
                                            .font(.system(size: 18))
                                            .foregroundColor(.white)
                                        Text(".PNG")
                                            .font(.system(size: 16))
                                            .foregroundColor(.white)
                                    }
                                    
                                    Spacer()
                                    
                                    VStack(
                                        alignment: .leading,
                                        spacing: 4
                                    ) {
                                        Text("ATTACHMENT_INFO_FILE_SIZE".localized() + ":")
                                            .bold()
                                            .font(.system(size: 18))
                                            .foregroundColor(.white)
                                        Text("6mb")
                                            .font(.system(size: 16))
                                            .foregroundColor(.white)
                                    }
                                    
                                    Spacer()
                                }

                                HStack(
                                    alignment: .center,
                                    spacing: 48
                                ) {
                                    VStack(
                                        alignment: .leading,
                                        spacing: 4
                                    ) {
                                        Text("ATTACHMENT_INFO_RESOLUTION".localized() + ":")
                                            .bold()
                                            .font(.system(size: 18))
                                            .foregroundColor(.white)
                                        Text("550×550")
                                            .font(.system(size: 16))
                                            .foregroundColor(.white)
                                    }
                                    
                                    Spacer()
                                    
                                    VStack(
                                        alignment: .leading,
                                        spacing: 4
                                    ) {
                                        Text("ATTACHMENT_INFO_DURATION".localized() + ":")
                                            .bold()
                                            .font(.system(size: 18))
                                            .foregroundColor(.white)
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
                                    top: 16,
                                    leading: 16,
                                    bottom: 16,
                                    trailing: 16
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
                            VStack(
                                alignment: .leading,
                                spacing: 4
                            ) {
                                Text("Sent:")
                                    .bold()
                                    .font(.system(size: 18))
                                    .foregroundColor(.white)
                                Text(messageViewModel.dateForUI.fromattedForMessageInfo)
                                    .font(.system(size: 16))
                                    .foregroundColor(.white)
                            }

                            VStack(
                                alignment: .leading,
                                spacing: 4
                            ) {
                                Text("Received:")
                                    .bold()
                                    .font(.system(size: 18))
                                    .foregroundColor(.white)
                                Text(messageViewModel.receivedDateForUI.fromattedForMessageInfo)
                                    .font(.system(size: 16))
                                    .foregroundColor(.white)
                            }

                            VStack(
                                alignment: .leading,
                                spacing: 4
                            ) {
                                Text("From:")
                                    .bold()
                                    .font(.system(size: 18))
                                    .foregroundColor(.white)
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
                                top: 16,
                                leading: 16,
                                bottom: 16,
                                trailing: 16
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
        //            ZStack {
        //                RoundedRectangle(cornerRadius: 8)
        //                VStack {
        //                    ForEach(
        //                        0...(actions.count - 1),
        //                        id: \.self
        //                    ) { index in
        //                        HStack {
        //                            Image(uiImage: actions[index].icon!)
        //                            Text(actions[index].title)
        //                        }
        //                    }
        //                }
        //            }
                }
            }
        }
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
    
    static var actions: [ContextMenuVC.Action] = []
    
    static var previews: some View {
        MessageInfoView(
            actions: actions,
            messageViewModel: messageViewModel
        )
    }
}
