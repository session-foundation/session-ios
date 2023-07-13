// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import SessionUIKit
import SessionSnodeKit

struct MessageInfoView: View {
    var actions: [ContextMenuVC.Action]
    var messageViewModel: MessageViewModel
    
    var body: some View {
        ZStack {
            if #available(iOS 14.0, *) {
                Color.black.ignoresSafeArea()
            } else {
                Color.black
            }
            
            VStack(
                alignment: .center,
                spacing: 10
            ) {
                // Message bubble snapshot
                Image("snapshot")

                // TODO: Attachment carousel view

                // Message Info
                ZStack {
                    RoundedRectangle(cornerRadius: 17)
                        .fill(Color(red: 27.0/255, green: 27.0/255, blue: 27.0/255))
                        
                    VStack(
                        alignment: .leading,
                        spacing: 10
                    ) {
                        VStack(
                            alignment: .leading,
                            spacing: 4
                        ) {
                            Text("Sent:")
                                .bold()
                                .foregroundColor(.white)
                            Text(messageViewModel.dateForUI.fromattedForMessageInfo)
                                .foregroundColor(.white)
                        }

                        VStack(
                            alignment: .leading,
                            spacing: 4
                        ) {
                            Text("Received:")
                                .bold()
                                .foregroundColor(.white)
                            Text(messageViewModel.receivedDateForUI.fromattedForMessageInfo)
                                .foregroundColor(.white)
                        }

                        VStack(
                            alignment: .leading,
                            spacing: 4
                        ) {
                            Text("From:")
                                .bold()
                                .foregroundColor(.white)
                            HStack(
                                spacing: 5
                            ) {
                                VStack(
                                    alignment: .leading,
                                    spacing: 4
                                ) {
                                    Text(messageViewModel.senderName ?? "Tester")
                                        .bold()
                                        .foregroundColor(.white)
                                    Text(messageViewModel.authorId)
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
                        top: 10,
                        leading: 30,
                        bottom: 10,
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

struct MessageInfoView_Previews: PreviewProvider {
    static var previews: some View {
        MessageInfoView(
            actions: [],
            messageViewModel: MessageViewModel(
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
                isSenderOpenGroupModerator: false,
                currentUserProfile: Profile.fetchOrCreateCurrentUser(),
                quote: nil,
                quoteAttachment: nil,
                linkPreview: nil,
                linkPreviewAttachment: nil,
                attachments: nil
            )
        )
    }
}
