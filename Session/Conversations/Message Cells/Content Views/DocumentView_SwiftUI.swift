// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import SessionUIKit
import SessionMessagingKit

struct DocumentView_SwiftUI: View {
    private let attachment: Attachment
    private let textColor: ThemeValue
    
    public init(attachment: Attachment, textColor: ThemeValue) {
        self.attachment = attachment
        self.textColor = textColor
    }
    
    var body: some View {
        HStack(
            alignment: .center,
            spacing: Values.mediumSpacing
        ) {
            ZStack {
                Rectangle()
                    .foregroundColor(themeColor: .messageBubble_overlay)
                    .frame(
                        width: <#T##CGFloat?#>
                    )
                
                Image(systemName: "doc")
                    .resizable()
                    .renderingMode(.template)
                    .foregroundColor(themeColor: textColor)
                    .scaledToFit()
                    .frame(
                        width: 24,
                        height: 32
                    )
                
                if attachment.isAudio {
                    Image(systemName: "music.note")
                        .resizable()
                        .renderingMode(.template)
                        .foregroundColor(themeColor: textColor)
                        .scaledToFit()
                        .frame(
                            width: 7,
                            height: 20,
                            alignment: .bottom
                        )
                }
            }
            
            Spacer(minLength: 0)

            VStack(
                alignment: .leading
            ) {
                Text(attachment.documentFileName)
                    .font(.system(size: Values.mediumFontSize))
                    .foregroundColor(themeColor: textColor)
                
                Text(attachment.documentFileInfo)
                    .font(.system(size: Values.verySmallFontSize))
                    .foregroundColor(themeColor: textColor)
            }
            
            Image(systemName: (attachment.isAudio ? "play.fill" : "arrow.down"))
                .resizable()
                .renderingMode(.template)
                .foregroundColor(themeColor: textColor)
                .scaledToFit()
                .frame(
                    width:24,
                    height: 24
                )
            
        }
    }
}

struct DocumentView_SwiftUI_Previews: PreviewProvider {
    static var previews: some View {
        VStack {
            DocumentView_SwiftUI(
                attachment: Attachment(
                    variant: .standard,
                    contentType: "audio/mp4",
                    byteCount: 100
                ),
                textColor: .messageBubble_outgoingText
            )
            .frame(
                width: 300,
                height: 100
            )
            
            DocumentView_SwiftUI(
                attachment: Attachment(
                    variant: .standard,
                    contentType: "txt",
                    byteCount: 1000
                ),
                textColor: .messageBubble_outgoingText
            )
            .frame(
                width: 300,
                height: 100
            )
        }
    }
}
