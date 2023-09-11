// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import NVActivityIndicatorView // TODO: Loading view
import SessionUIKit
import SessionMessagingKit

public struct LinkPreviewView_SwiftUI: View {
    private var state: LinkPreviewState
    private var isOutgoing: Bool
    private let maxWidth: CGFloat
    private var messageViewModel: MessageViewModel?
    private var bodyLabelTextColor: ThemeValue?
    private var lastSearchText: String?
    private let onCancel: (() -> ())?
    
    private static let loaderSize: CGFloat = 24
    private static let cancelButtonSize: CGFloat = 45
    
    init(
        state: LinkPreviewState,
        isOutgoing: Bool,
        maxWidth: CGFloat = .infinity,
        messageViewModel: MessageViewModel? = nil,
        bodyLabelTextColor: ThemeValue? = nil,
        lastSearchText: String? = nil,
        onCancel: (() -> ())? = nil
    ) {
        self.state = state
        self.isOutgoing = isOutgoing
        self.maxWidth = maxWidth
        self.messageViewModel = messageViewModel
        self.bodyLabelTextColor = bodyLabelTextColor
        self.lastSearchText = lastSearchText
        self.onCancel = onCancel
    }
    
    public var body: some View {
        VStack(
            alignment: .leading,
            spacing: Values.mediumSpacing
        ) {
            HStack(
                alignment: .center,
                spacing: Values.mediumSpacing
            ) {
                // Link preview image
                let imageSize: CGFloat = state is LinkPreview.SentState ? 100 : 80
                if let linkPreviewImage: UIImage = state.image {
                    Image(uiImage: linkPreviewImage)
                        .resizable()
                        .scaledToFill()
                        .foregroundColor(
                            themeColor: isOutgoing ?
                                .messageBubble_outgoingText :
                                .messageBubble_incomingText
                        )
                        .frame(
                            width: imageSize,
                            height: imageSize
                        )
                        .cornerRadius(state is LinkPreview.SentState ? 0 : 8)
                } else {
                    if
                        state is LinkPreview.DraftState || state is LinkPreview.SentState,
                        let defaultImage: UIImage = UIImage(named: "Link")?.withRenderingMode(.alwaysTemplate)
                    {
                        Image(uiImage: defaultImage)
                            .foregroundColor(
                                themeColor: isOutgoing ?
                                    .messageBubble_outgoingText :
                                    .messageBubble_incomingText
                            )
                            .frame(
                                width: imageSize,
                                height: imageSize
                            )
                            .cornerRadius(state is LinkPreview.SentState ? 0 : 8)
                    }
                }
                
                // Link preview title
                if let title: String = state.title {
                    Text(title)
                        .bold()
                        .font(.system(size: Values.smallFontSize))
                        .multilineTextAlignment(.leading)
                        .foregroundColor(
                            themeColor: isOutgoing ?
                                .messageBubble_outgoingText :
                                .messageBubble_incomingText
                        )
                }
                
                // Cancel button
                if state is LinkPreview.DraftState {
                    Spacer(minLength: 0)
                    
                    Button(action: {
                        onCancel?()
                    }, label: {
                        if let image: UIImage = UIImage(named: "X")?.withRenderingMode(.alwaysTemplate) {
                            Image(uiImage: image)
                                .foregroundColor(themeColor: .textPrimary)
                        }
                    })
                    .frame(
                        width: Self.cancelButtonSize,
                        height: Self.cancelButtonSize
                    )
                }
            }
        }
    }
}

struct LinkPreviewView_SwiftUI_Previews: PreviewProvider {
    static var previews: some View {
        LinkPreviewView_SwiftUI(
            state: LinkPreview.DraftState(
                linkPreviewDraft: .init(
                    urlString: "https://github.com/oxen-io",
                    title: "Github - oxen-io/session-ios: A private messenger for iOS.",
                    jpegImageData: UIImage(named: "AppIcon")?.jpegData(compressionQuality: 1)
                )
            ),
            isOutgoing: true
        )
        .padding(.horizontal, Values.mediumSpacing)
    }
}
