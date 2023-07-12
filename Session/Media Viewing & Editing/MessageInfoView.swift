// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI

struct MessageInfoView: View {
    var actions: [ContextMenuVC.Action]
    var messageViewModel: MessageViewModel
    
    var body: some View {
        VStack(
            alignment: .center,
            spacing: 10
        ) {
            // Message bubble snapshot
            Image("snapshot")
            
            // TODO: Attachment carousel view
            
            // Message Info
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                VStack(
                    alignment: .leading,
                    spacing: 10
                ) {
                    VStack(
                        alignment: .leading
                    ) {
                        Text("Sent:")
                            .bold()
                        Text()
                    }
                    
                    VStack(
                        alignment: .leading
                    ) {
                        Text("Received:")
                            .bold()
                        Text("")
                    }
                    
                    VStack(
                        alignment: .leading
                    ) {
                        Text("From:")
                            .bold()
                        HStack(
                            spacing: 5
                        ) {
                            Image("avatar")
                            VStack(
                                alignment: .leading
                            ) {
                                Text("Name")
                                    .bold()
                                Text("session id")
                            }
                        }
                    }
                }
            }
            
            // Actions
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                VStack {
                    ForEach(
                        0...(actions.count - 1),
                        id: \.self
                    ) { index in
                        HStack {
                            Image(uiImage: actions[index].icon!)
                            Text(actions[index].title)
                        }
                    }
                }
            }
        }
    }
}

struct MessageInfoView_Previews: PreviewProvider {
    static var previews: some View {
        MessageInfoView(
            actions: [],
            messageViewModel: nil)
    }
}
