// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import SessionUIKit
import SessionMessagingKit

struct DocumentView_SwiftUI: View {
    static private let inset: CGFloat = 12
    
    private let attachment: Attachment
    private let textColor: ThemeValue
    
    public init(attachment: Attachment, textColor: ThemeValue) {
        self.attachment = attachment
        self.textColor = textColor
    }
    
    var body: some View {
        HStack(
            alignment: .center,
            spacing: 0
        ) {
            ZStack {
                Rectangle()
                    .foregroundColor(themeColor: .messageBubble_overlay)
                
                Image(systemName: "doc")
                    .font(.system(size: Values.largeFontSize))
                    .foregroundColor(themeColor: textColor)

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
            .frame(
                width: 24 + Values.mediumSpacing * 2,
                height: 32 + Values.smallSpacing * 2
            )
            
            Spacer(minLength: 0)

            VStack(
                alignment: .leading
            ) {
                Text(attachment.documentFileName)
                    .lineLimit(1)
                    .font(.system(size: Values.mediumFontSize))
                    .foregroundColor(themeColor: textColor)
                
                Text(attachment.documentFileInfo)
                    .font(.system(size: Values.verySmallFontSize))
                    .foregroundColor(themeColor: textColor)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Values.mediumSpacing)
            
            Image(systemName: (attachment.isAudio ? "play.fill" : "arrow.down"))
                .font(.system(size: Values.mediumFontSize))
                .foregroundColor(themeColor: textColor)
                .padding(.trailing, Self.inset)
        }
    }
}

#Preview {
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
            width: 200,
            height: 58
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
            width: 200,
            height: 58
        )
    }
}
