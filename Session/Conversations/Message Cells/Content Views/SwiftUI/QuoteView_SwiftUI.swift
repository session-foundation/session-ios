// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit

struct QuoteView_SwiftUI: View {
    public enum Mode { case regular, draft }
    public enum Direction { case incoming, outgoing }
    public struct Info {
        var mode: Mode
        var authorName: String
        var authorHasProBadge: Bool
        var quotedText: String?
        var threadVariant: SessionThread.Variant
        var currentUserSessionIds: Set<String>
        var direction: Direction
        var attachment: Attachment?
    }
    
    private static let thumbnailSize: CGFloat = 48
    private static let iconSize: CGFloat = 24
    private static let labelStackViewSpacing: CGFloat = 2
    private static let labelStackViewVMargin: CGFloat = 4
    private static let cancelButtonSize: CGFloat = 33
    private static let cornerRadius: CGFloat = 4
    
    private let dependencies: Dependencies
    private var info: Info
    private var onCancel: (() -> ())?
    
    private var quotedText: String? {
        if let quotedText = info.quotedText, !quotedText.isEmpty {
            return quotedText
        }
        
        if let attachment = info.attachment {
            return attachment.shortDescription
        }
        
        return nil
    }
    
    public init(info: Info, using dependencies: Dependencies, onCancel: (() -> ())? = nil) {
        self.dependencies = dependencies
        self.info = info
        self.onCancel = onCancel
    }
    
    var body: some View {
        HStack(
            alignment: .center,
            spacing: Values.smallSpacing
        ) {
            if let attachment: Attachment = info.attachment {
                ZStack() {
                    RoundedRectangle(
                        cornerRadius: Self.cornerRadius
                    )
                    .fill(themeColor: .messageBubble_overlay)
                    .frame(
                        width: Self.thumbnailSize,
                        height: Self.thumbnailSize
                    )
                    
                    SessionAsyncImage(
                        attachment: attachment,
                        thumbnailSize: .small,
                        using: dependencies
                    ) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } placeholder: {
                        let fallbackImageName: String = (attachment.isAudio ? "attachment_audio" : "actionsheet_document_black")
                        
                        if let image = UIImage(named: fallbackImageName)?.withRenderingMode(.alwaysTemplate) {
                            Image(uiImage: image)
                                .foregroundColor(themeColor: {
                                    switch info.mode {
                                        case .regular: return (info.direction == .outgoing ?
                                            .messageBubble_outgoingText :
                                                .messageBubble_incomingText
                                        )
                                        case .draft: return .textPrimary
                                    }
                                }())
                        }
                        else {
                            Color.clear
                        }
                    }
                    .frame(
                        width: Self.iconSize,
                        height: Self.iconSize,
                        alignment: .center
                    )
                }
            } else {
                // Line view
                let lineColor: ThemeValue = {
                    switch info.mode {
                        case .regular: return (info.direction == .outgoing ? .messageBubble_outgoingText : .primary)
                        case .draft: return .primary
                    }
                }()
                
                Rectangle()
                    .foregroundColor(themeColor: lineColor)
                    .frame(width: Values.accentLineThickness)
            }
            
            // Quoted text and author
            VStack(
                alignment: .leading,
                spacing: Self.labelStackViewSpacing
            ) {
                let targetThemeColor: ThemeValue = {
                    switch info.mode {
                        case .regular: return (info.direction == .outgoing ?
                            .messageBubble_outgoingText :
                            .messageBubble_incomingText
                        )
                        case .draft: return .textPrimary
                    }
                }()
                
                if let quotedText = self.quotedText {
                    Text(info.authorName)
                        .bold()
                        .font(.system(size: Values.smallFontSize))
                        .foregroundColor(themeColor: targetThemeColor)
                    
                    AttributedText(
                        MentionUtilities.highlightMentions(
                            in: quotedText,
                            threadVariant: info.threadVariant,
                            currentUserSessionIds: info.currentUserSessionIds,
                            location: {
                                switch (info.mode, info.direction) {
                                    case (.draft, _): return .quoteDraft
                                    case (_, .outgoing): return .outgoingQuote
                                    case (_, .incoming): return .incomingQuote
                                }
                            }(),
                            textColor: targetThemeColor,
                            attributes: [
                                .themeForegroundColor: targetThemeColor,
                                .font: UIFont.systemFont(ofSize: Values.smallFontSize)
                            ],
                            using: dependencies
                        )
                    )
                    .lineLimit(2)
                } else {
                    Text("messageErrorOriginal".localized())
                        .font(.system(size: Values.smallFontSize))
                        .foregroundColor(themeColor: targetThemeColor)
                }
            }
            .padding(.vertical, Self.labelStackViewVMargin)
            
            if info.mode == .draft {
                // Cancel button
                Button(
                    action: {
                        onCancel?()
                    },
                    label: {
                        if let image = UIImage(named: "X")?.withRenderingMode(.alwaysTemplate) {
                            Image(uiImage: image)
                                .foregroundColor(themeColor: .textPrimary)
                                .frame(
                                    width: Self.cancelButtonSize,
                                    height: Self.cancelButtonSize,
                                    alignment: .center
                                )
                        }
                    }
                )
            }
        }
        .padding(.trailing, Values.smallSpacing)
    }
}

struct QuoteView_SwiftUI_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            ThemeColor(.backgroundPrimary).ignoresSafeArea()
            VStack(spacing: 20) {
                QuoteView_SwiftUI(
                    info: QuoteView_SwiftUI.Info(
                        mode: .draft,
                        authorName: "",
                        authorHasProBadge: false,
                        threadVariant: .contact,
                        currentUserSessionIds: [],
                        direction: .outgoing
                    ),
                    using: Dependencies.createEmpty()
                )
                .frame(height: 40)
                
                QuoteView_SwiftUI(
                    info: QuoteView_SwiftUI.Info(
                        mode: .regular,
                        authorName: "",
                        authorHasProBadge: false,
                        threadVariant: .contact,
                        currentUserSessionIds: [],
                        direction: .incoming,
                        attachment: Attachment(
                            variant: .standard,
                            state: .downloaded,
                            contentType: "audio/wav",
                            byteCount: 0
                        )
                    ),
                    using: Dependencies.createEmpty()
                )
                .previewLayout(.sizeThatFits)
            }
        }
    }
}
