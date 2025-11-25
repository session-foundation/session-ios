// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import UniformTypeIdentifiers

public struct QuoteViewModel: Sendable, Equatable, Hashable {
    public enum Mode: Sendable, Equatable, Hashable { case regular, draft }
    public enum Direction: Sendable, Equatable, Hashable { case incoming, outgoing }
    
    public struct QuotedInfo: Sendable, Equatable, Hashable {
        public let interactionId: Int64
        public let authorId: String
        public let authorName: String
        public let timestampMs: Int64
        public let body: String?
        public let attachmentInfo: AttachmentInfo?
        
        public init(
            interactionId: Int64,
            authorId: String,
            authorName: String,
            timestampMs: Int64,
            body: String?,
            attachmentInfo: AttachmentInfo?
        ) {
            self.interactionId = interactionId
            self.authorId = authorId
            self.authorName = authorName
            self.timestampMs = timestampMs
            self.body = body
            self.attachmentInfo = attachmentInfo
        }
    }
    
    public struct AttachmentInfo: Sendable, Equatable, Hashable {
        public let id: String
        public let utType: UTType
        public let isVoiceMessage: Bool
        public let downloadUrl: String?
        public let sourceFilename: String?
        public let thumbnailSource: ImageDataManager.DataSource?
        
        public init(
            id: String,
            utType: UTType,
            isVoiceMessage: Bool,
            downloadUrl: String?,
            sourceFilename: String?,
            thumbnailSource: ImageDataManager.DataSource?
        ) {
            self.id = id
            self.utType = utType
            self.isVoiceMessage = isVoiceMessage
            self.downloadUrl = downloadUrl
            self.sourceFilename = sourceFilename
            self.thumbnailSource = thumbnailSource
        }
    }
    
    public static let emptyDraft: QuoteViewModel = QuoteViewModel(
        mode: .draft,
        direction: .outgoing,
        quotedInfo: nil,
        showProBadge: false,
        currentUserSessionIds: [],
        displayNameRetriever: { _, _ in nil }
    )
    
    public let mode: Mode
    public let direction: Direction
    public let targetThemeColor: ThemeValue
    public let quotedInfo: QuotedInfo?
    public let showProBadge: Bool
    public let attributedText: ThemedAttributedString

    // MARK: - Computed Properties
    
    var hasAttachment: Bool { quotedInfo?.attachmentInfo != nil }
    
    var fallbackImage: UIImage? {
        guard let utType: UTType = quotedInfo?.attachmentInfo?.utType else { return nil }
        
        let fallbackImageName: String = (utType.conforms(to: .audio) ? "attachment_audio" : "actionsheet_document_black")
            
        guard let image = UIImage(named: fallbackImageName)?.withRenderingMode(.alwaysTemplate) else {
            return nil
        }
        
        return image
    }
    
    var proBadgeThemeColor: ThemeValue {
        switch mode {
            case .draft: return .primary
            case .regular:
                return (direction == .outgoing ?
                    .white :
                    .primary
                )
        }
    }
    
    var lineColor: ThemeValue {
        switch mode {
            case .draft: return .primary
            case .regular:
                return (direction == .outgoing ?
                    .messageBubble_outgoingText :
                    .primary
                )
            
        }
    }
    
    // MARK: - Initialization
    
    public init(
        mode: Mode,
        direction: Direction,
        quotedInfo: QuotedInfo?,
        showProBadge: Bool,
        currentUserSessionIds: Set<String>,
        displayNameRetriever: @escaping DisplayNameRetriever
    ) {
        self.mode = mode
        self.direction = direction
        self.quotedInfo = quotedInfo
        self.showProBadge = showProBadge
        self.targetThemeColor = {
            switch mode {
                case .draft: return .textPrimary
                case .regular:
                    return (direction == .outgoing ?
                        .messageBubble_outgoingText :
                        .messageBubble_incomingText
                    )
            }
        }()
        
        let text: String = {
            switch (quotedInfo?.body, quotedInfo?.attachmentInfo) {
                case (.some(let text), _) where !text.isEmpty: return text
                case (_, .some(let info)):
                    return info.utType.shortDescription(isVoiceMessage: info.isVoiceMessage)
                
                case (.some, .none), (.none, .none): return "messageErrorOriginal".localized()
            }
        }()
        
        self.attributedText = MentionUtilities.highlightMentions(
            in: text,
            currentUserSessionIds: currentUserSessionIds,
            location: {
                switch (mode, direction) {
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
            displayNameRetriever: displayNameRetriever
        )
    }
    
    public init(previewBody: String) {
        self.quotedInfo = QuotedInfo(
            interactionId: 0,
            authorId: "",
            authorName: "",
            timestampMs: 0,
            body: previewBody,
            attachmentInfo: nil
        )
        
        /// This is an preview version so none of these values matter
        self.mode = .regular
        self.direction = .incoming
        self.targetThemeColor = .messageBubble_incomingText
        self.showProBadge = false
        self.attributedText = ThemedAttributedString(string: previewBody)
    }
    
    // MARK: - Conformance
    
    public static func == (lhs: QuoteViewModel, rhs: QuoteViewModel) -> Bool {
        return (
            lhs.mode == rhs.mode &&
            lhs.direction == rhs.direction &&
            lhs.quotedInfo == rhs.quotedInfo &&
            lhs.attributedText == rhs.attributedText
        )
    }
    
    public func hash(into hasher: inout Hasher) {
        mode.hash(into: &hasher)
        direction.hash(into: &hasher)
        quotedInfo.hash(into: &hasher)
        attributedText.hash(into: &hasher)
    }
}

// MARK: - QuoteView

public struct QuoteView_SwiftUI: View {
    private static let thumbnailSize: CGFloat = 48
    private static let iconSize: CGFloat = 24
    private static let labelStackViewSpacing: CGFloat = 2
    private static let labelStackViewVMargin: CGFloat = 4
    private static let cancelButtonSize: CGFloat = 33
    private static let cornerRadius: CGFloat = 4
    
    private var viewModel: QuoteViewModel
    private var dataManager: ImageDataManagerType
    private var onCancel: (() -> Void)?
    
    public init(
        viewModel: QuoteViewModel,
        dataManager: ImageDataManagerType,
        onCancel: (() -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.dataManager = dataManager
        self.onCancel = onCancel
    }
    
    public var body: some View {
        HStack(
            alignment: .center,
            spacing: Values.smallSpacing
        ) {
            if viewModel.hasAttachment {
                ZStack() {
                    RoundedRectangle(cornerRadius: Self.cornerRadius)
                    .fill(themeColor: .messageBubble_overlay)
                    .frame(
                        width: Self.thumbnailSize,
                        height: Self.thumbnailSize
                    )
                    
                    if let source: ImageDataManager.DataSource = viewModel.quotedInfo?.attachmentInfo?.thumbnailSource {
                        SessionAsyncImage(
                            source: source,
                            dataManager: dataManager
                        ) { image in
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } placeholder: {
                            if let image: UIImage = viewModel.fallbackImage {
                                Image(uiImage: image)
                                    .foregroundColor(themeColor: viewModel.targetThemeColor)
                            }
                            
                            Color.clear
                        }
                        .frame(
                            width: Self.iconSize,
                            height: Self.iconSize,
                            alignment: .center
                        )
                    }
                    else {
                        if let image: UIImage = viewModel.fallbackImage {
                            Image(uiImage: image)
                                .foregroundColor(themeColor: viewModel.targetThemeColor)
                                .frame(
                                    width: Self.iconSize,
                                    height: Self.iconSize,
                                    alignment: .center
                                )
                        }
                        
                        Color.clear
                            .frame(
                                width: Self.iconSize,
                                height: Self.iconSize,
                                alignment: .center
                            )
                    }
                }
            } else {
                // Line view
                Rectangle()
                    .foregroundColor(themeColor: viewModel.lineColor)
                    .frame(width: Values.accentLineThickness)
            }
            
            // Quoted text and author
            VStack(
                alignment: .leading,
                spacing: Self.labelStackViewSpacing
            ) {
                if let authorName: String = viewModel.quotedInfo?.authorName {
                    Text(authorName)
                        .bold()
                        .font(.system(size: Values.smallFontSize))
                        .foregroundColor(themeColor: viewModel.targetThemeColor)
                }
                
                if viewModel.quotedInfo != nil {
                    AttributedText(viewModel.attributedText)
                        .lineLimit(2)
                } else {
                    Text("messageErrorOriginal".localized())
                        .font(.system(size: Values.smallFontSize))
                        .foregroundColor(themeColor: viewModel.targetThemeColor)
                }
            }
            .padding(.vertical, Self.labelStackViewVMargin)
            
            if viewModel.mode == .draft {
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
                ZStack {
                    ThemeColor(.messageBubble_incomingBackground).ignoresSafeArea()
                    QuoteView_SwiftUI(
                        viewModel: QuoteViewModel(
                            mode: .draft,
                            direction: .outgoing,
                            quotedInfo: QuoteViewModel.QuotedInfo(
                                interactionId: 0,
                                authorId: "05123",
                                authorName: "Test User",
                                timestampMs: 0,
                                body: nil,
                                attachmentInfo: nil
                            ),
                            showProBadge: true,
                            currentUserSessionIds: ["05123"],
                            displayNameRetriever: { _, _ in nil }
                        ),
                        dataManager: ImageDataManager()
                    )
                    .frame(height: 40)
                }
                .frame(
                    width: 300,
                    height: 80
                )
                .cornerRadius(10)
                
                ZStack {
                    ThemeColor(.messageBubble_incomingBackground).ignoresSafeArea()
                    QuoteView_SwiftUI(
                        viewModel: QuoteViewModel(
                            mode: .draft,
                            direction: .outgoing,
                            quotedInfo: QuoteViewModel.QuotedInfo(
                                interactionId: 0,
                                authorId: "05123",
                                authorName: "0512...1234",
                                timestampMs: 0,
                                body: "This was a message",
                                attachmentInfo: nil
                            ),
                            showProBadge: false,
                            currentUserSessionIds: [],
                            displayNameRetriever: { _, _ in "Some User" }
                        ),
                        dataManager: ImageDataManager()
                    )
                    .frame(height: 40)
                }
                .frame(
                    width: 300,
                    height: 80
                )
                .cornerRadius(10)
                
                ZStack {
                    ThemeColor(.messageBubble_incomingBackground).ignoresSafeArea()
                    QuoteView_SwiftUI(
                        viewModel: QuoteViewModel(
                            mode: .regular,
                            direction: .incoming,
                            quotedInfo: QuoteViewModel.QuotedInfo(
                                interactionId: 0,
                                authorId: "05123",
                                authorName: "Name",
                                timestampMs: 0,
                                body: nil,
                                attachmentInfo: QuoteViewModel.AttachmentInfo(
                                    id: "",
                                    utType: .wav,
                                    isVoiceMessage: false,
                                    downloadUrl: nil,
                                    sourceFilename: nil,
                                    thumbnailSource: nil
                                )
                            ),
                            showProBadge: false,
                            currentUserSessionIds: [],
                            displayNameRetriever: { _, _ in nil }
                        ),
                        dataManager: ImageDataManager()
                    )
                    .previewLayout(.sizeThatFits)
                }
                .frame(
                    width: 300,
                    height: 80
                )
                .cornerRadius(10)
            }
        }
    }
}
