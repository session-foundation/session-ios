// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import UniformTypeIdentifiers

public struct QuoteViewModel: Equatable, Hashable {
    public enum Mode: Equatable, Hashable { case regular, draft }
    public enum Direction: Equatable, Hashable { case incoming, outgoing }
    public struct AttachmentInfo: Equatable, Hashable {
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
    
    public let mode: Mode
    public let direction: Direction
    public let currentUserSessionIds: Set<String>
    public let rowId: Int64
    public let interactionId: Int64?
    public let authorId: String
    public let showProBadge: Bool
    public let timestampMs: Int64
    public let quotedInteractionId: Int64
    public let quotedInteractionIsDeleted: Bool
    public let quotedText: String?
    public let quotedAttachmentInfo: AttachmentInfo?
    let displayNameRetriever: (String, Bool) -> String?

    // MARK: - Computed Properties
    
    var hasAttachment: Bool { quotedAttachmentInfo != nil }
    var author: String? {
        guard authorId.isEmpty || !currentUserSessionIds.contains(authorId) else { return "you".localized() }
        guard quotedText != nil else {
            // When we can't find the quoted message we want to hide the author label
            return displayNameRetriever(authorId, false)
        }
        
        return (displayNameRetriever(authorId, false) ?? authorId.truncated())
    }
    
    var fallbackImage: UIImage? {
        guard let utType: UTType = quotedAttachmentInfo?.utType else { return nil }
        
        let fallbackImageName: String = (utType.conforms(to: .audio) ? "attachment_audio" : "actionsheet_document_black")
            
        guard let image = UIImage(named: fallbackImageName)?.withRenderingMode(.alwaysTemplate) else {
            return nil
        }
        
        return image
    }
    
    var targetThemeColor: ThemeValue {
        switch mode {
            case .draft: return .textPrimary
            case .regular:
                return (direction == .outgoing ?
                    .messageBubble_outgoingText :
                    .messageBubble_incomingText
                )
        }
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
        
    var mentionLocation: MentionUtilities.MentionLocation {
        switch (mode, direction) {
            case (.draft, _): return .quoteDraft
            case (_, .outgoing): return .outgoingQuote
            case (_, .incoming): return .incomingQuote
        }
    }
    
    var attributedText: ThemedAttributedString? {
        let text: String = {
            switch (quotedText, quotedAttachmentInfo) {
                case (.some(let text), _) where !text.isEmpty: return text
                case (_, .some(let info)):
                    return info.utType.shortDescription(isVoiceMessage: info.isVoiceMessage)
                
                case (.some, .none), (.none, .none): return "messageErrorOriginal".localized()
            }
        }()
        
        return MentionUtilities.highlightMentions(
            in: text,
            currentUserSessionIds: currentUserSessionIds,
            location: mentionLocation,
            textColor: targetThemeColor,
            attributes: [
                .themeForegroundColor: targetThemeColor,
                .font: UIFont.systemFont(ofSize: Values.smallFontSize)
            ],
            displayNameRetriever: displayNameRetriever
        )
    }
    
    // MARK: - Initialization
    
    public init(
        mode: Mode,
        direction: Direction,
        currentUserSessionIds: Set<String>,
        rowId: Int64,
        interactionId: Int64?,
        authorId: String,
        showProBadge: Bool,
        timestampMs: Int64,
        quotedInteractionId: Int64,
        quotedInteractionIsDeleted: Bool,
        quotedText: String?,
        quotedAttachmentInfo: AttachmentInfo?,
        displayNameRetriever: @escaping (String, Bool) -> String?
    ) {
        self.mode = mode
        self.direction = direction
        self.currentUserSessionIds = currentUserSessionIds
        self.rowId = rowId
        self.interactionId = interactionId
        self.authorId = authorId
        self.showProBadge = showProBadge
        self.timestampMs = timestampMs
        self.quotedInteractionId = quotedInteractionId
        self.quotedInteractionIsDeleted = quotedInteractionIsDeleted
        self.quotedText = quotedText
        self.quotedAttachmentInfo = quotedAttachmentInfo
        self.displayNameRetriever = displayNameRetriever
    }
    
    public init(previewBody: String) {
        self.quotedText = previewBody
        
        /// This is an preview version so none of these values matter
        self.mode = .regular
        self.direction = .incoming
        self.currentUserSessionIds = []
        self.rowId = -1
        self.interactionId = nil
        self.authorId = ""
        self.showProBadge = false
        self.timestampMs = 0
        self.quotedInteractionId = 0
        self.quotedInteractionIsDeleted = false
        self.quotedAttachmentInfo = nil
        self.displayNameRetriever = { _, _ in nil }
    }
    
    // MARK: - Conformance
    
    public static func == (lhs: QuoteViewModel, rhs: QuoteViewModel) -> Bool {
        return (
            lhs.mode == rhs.mode &&
            lhs.direction == rhs.direction &&
            lhs.currentUserSessionIds == rhs.currentUserSessionIds &&
            lhs.rowId == rhs.rowId &&
            lhs.interactionId == rhs.interactionId &&
            lhs.authorId == rhs.authorId &&
            lhs.timestampMs == rhs.timestampMs &&
            lhs.quotedInteractionId == rhs.quotedInteractionId &&
            lhs.quotedInteractionIsDeleted == rhs.quotedInteractionIsDeleted &&
            lhs.quotedText == rhs.quotedText &&
            lhs.quotedAttachmentInfo == rhs.quotedAttachmentInfo
        )
    }
    
    public func hash(into hasher: inout Hasher) {
        mode.hash(into: &hasher)
        direction.hash(into: &hasher)
        currentUserSessionIds.hash(into: &hasher)
        rowId.hash(into: &hasher)
        interactionId?.hash(into: &hasher)
        authorId.hash(into: &hasher)
        timestampMs.hash(into: &hasher)
        quotedInteractionId.hash(into: &hasher)
        quotedInteractionIsDeleted.hash(into: &hasher)
        quotedText.hash(into: &hasher)
        quotedAttachmentInfo.hash(into: &hasher)
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
                    
                    if let source: ImageDataManager.DataSource = viewModel.quotedAttachmentInfo?.thumbnailSource {
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
                if let author: String = viewModel.author {
                    Text(author)
                        .bold()
                        .font(.system(size: Values.smallFontSize))
                        .foregroundColor(themeColor: viewModel.targetThemeColor)
                }
                
                if let attributedText: ThemedAttributedString = viewModel.attributedText {
                    AttributedText(attributedText)
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
                            currentUserSessionIds: ["05123"],
                            rowId: 0,
                            interactionId: nil,
                            authorId: "05123",
                            showProBadge: false,
                            timestampMs: 0,
                            quotedInteractionId: 0,
                            quotedInteractionIsDeleted: false,
                            quotedText: nil,
                            quotedAttachmentInfo: nil,
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
                            currentUserSessionIds: [],
                            rowId: 0,
                            interactionId: nil,
                            authorId: "05123",
                            showProBadge: true,
                            timestampMs: 0,
                            quotedInteractionId: 0,
                            quotedInteractionIsDeleted: false,
                            quotedText: "This was a message",
                            quotedAttachmentInfo: nil,
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
                            currentUserSessionIds: [],
                            rowId: 0,
                            interactionId: nil,
                            authorId: "",
                            showProBadge: false,
                            timestampMs: 0,
                            quotedInteractionId: 0,
                            quotedInteractionIsDeleted: false,
                            quotedText: nil,
                            quotedAttachmentInfo: QuoteViewModel.AttachmentInfo(
                                id: "",
                                utType: .wav,
                                isVoiceMessage: false,
                                downloadUrl: nil,
                                sourceFilename: nil,
                                thumbnailSource: nil
                            ),
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
