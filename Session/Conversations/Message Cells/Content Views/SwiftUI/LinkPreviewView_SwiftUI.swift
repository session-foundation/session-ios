// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import Lucide
import SessionUIKit
import SessionMessagingKit

public struct LinkPreviewView_SwiftUI: View {
    private var viewModel: LinkPreviewViewModel
    private var dataManager: ImageDataManagerType
    private var isOutgoing: Bool
    private let maxWidth: CGFloat
    private var messageViewModel: MessageViewModel?
    private var bodyLabelTextColor: ThemeValue?
    private var lastSearchText: String?
    private let onCancel: (() -> ())?
    
    private static let loaderSize: CGFloat = 24
    private static let cancelButtonSize: CGFloat = 45
    
    init(
        viewModel: LinkPreviewViewModel,
        dataManager: ImageDataManagerType,
        isOutgoing: Bool,
        maxWidth: CGFloat = .infinity,
        messageViewModel: MessageViewModel? = nil,
        bodyLabelTextColor: ThemeValue? = nil,
        lastSearchText: String? = nil,
        onCancel: (() -> ())? = nil
    ) {
        self.viewModel = viewModel
        self.dataManager = dataManager
        self.isOutgoing = isOutgoing
        self.maxWidth = maxWidth
        self.messageViewModel = messageViewModel
        self.bodyLabelTextColor = bodyLabelTextColor
        self.lastSearchText = lastSearchText
        self.onCancel = onCancel
    }
    
    public var body: some View {
        ZStack(
            alignment: .leading
        ) {
            if viewModel.state == .sent {
                ThemeColor(.messageBubble_overlay).ignoresSafeArea()
            }
            
            HStack(
                alignment: .center,
                spacing: Values.mediumSpacing
            ) {
                // Link preview image
                let imageSize: CGFloat = (viewModel.state == .sent ? 100 : 80)
                if let linkPreviewImageSource: ImageDataManager.DataSource = viewModel.imageSource {
                    SessionAsyncImage(
                        source: linkPreviewImageSource,
                        dataManager: dataManager,
                        content: { image in
                            image
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
                                .cornerRadius(viewModel.state == .sent ? 0 : 8)
                        },
                        placeholder: {
                            ThemeColor(.alert_background)
                                .frame(
                                    width: imageSize,
                                    height: imageSize
                                )
                                .cornerRadius(viewModel.state == .sent ? 0 : 8)
                        }
                    )
                } else if viewModel.state == .draft || viewModel.state == .sent {
                    LucideIcon(.link, size: IconSize.medium.size)
                        .foregroundColor(
                            themeColor: isOutgoing ?
                                .messageBubble_outgoingText :
                                .messageBubble_incomingText
                        )
                        .frame(
                            width: imageSize,
                            height: imageSize
                        )
                        .backgroundColor(themeColor: .messageBubble_overlay)
                        .cornerRadius(viewModel.state == .sent ? 0 : 8)
                } else {
                    ActivityIndicator(themeColor: .borderSeparator, width: 2)
                        .frame(
                            width: Self.loaderSize,
                            height: Self.loaderSize
                        )
                }
                
                // Link preview title
                if let title: String = viewModel.title {
                    Text(title)
                        .bold()
                        .font(.system(size: Values.smallFontSize))
                        .multilineTextAlignment(.leading)
                        .foregroundColor(
                            themeColor: isOutgoing ?
                                .messageBubble_outgoingText :
                                .messageBubble_incomingText
                        )
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.trailing, Values.mediumSpacing)
                }
                
                // Cancel button
                if viewModel.state == .draft {
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

struct LinkPreview_SwiftUI_Previews: PreviewProvider {
    static var previews: some View {
        VStack {
            LinkPreviewView_SwiftUI(
                viewModel: LinkPreviewViewModel(
                    state: .draft,
                    urlString: "https://github.com/session-foundation",
                    title: "Github - session-foundation/session-ios: A private messenger for iOS.",
                    imageSource: .image("AppIcon", UIImage(named: "AppIcon"))
                ),
                dataManager: ImageDataManager(),
                isOutgoing: true
            )
            .padding(.horizontal, Values.mediumSpacing)
            
            LinkPreviewView_SwiftUI(
                viewModel: LinkPreviewViewModel(
                    state: .loading,
                    urlString: "https://github.com/session-foundation"
                ),
                dataManager: ImageDataManager(),
                isOutgoing: true
            )
            .frame(
                width: .infinity,
                height: 80
            )
            .padding(.horizontal, Values.mediumSpacing)
        }
    }
}
