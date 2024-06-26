// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import GRDB
import DifferenceKit
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit
import SignalUtilitiesKit

struct ConversationList: View {
    @Binding private var viewModel: HomeViewModel
    
    private static let mutePrefix: String = "\u{e067}  " // stringlint:disable
    private static let unreadCountViewSize: CGFloat = 20
    private static let statusIndicatorSize: CGFloat = 14
    
    public init(viewModel: Binding<HomeViewModel>) {
        self._viewModel = viewModel
    }

    var body: some View {
        List(viewModel.threadData) { sectionModel in
            switch sectionModel.model {
                case .messageRequests:
                    Section {
                        ForEach(sectionModel.elements) { threadViewModel in
                            HStack(
                                alignment: .center,
                                content: {
                                    Image("icon_msg_req")
                                        .renderingMode(.template)
                                        .resizable()
                                        .foregroundColor(themeColor: .conversationButton_unreadBubbleText)
                                        .background(
                                            Circle()
                                                .fill(themeColor: .conversationButton_unreadBubbleBackground)
                                                .frame(
                                                    width: ProfilePictureView.Size.list.viewSize,
                                                    height: ProfilePictureView.Size.list.viewSize
                                                )
                                        )
                                    
                                    Text("sessionMessageRequests".localized())
                                        .bold()
                                        .font(.system(size: Values.mediumFontSize))
                                        .foregroundColor(themeColor: .textPrimary)
                                        .padding(.leading, Values.mediumSpacing)
                                        .padding(.trailing, Values.verySmallSpacing)
                                    
                                    Text("\(threadViewModel.threadUnreadCount ?? 0)")
                                        .bold()
                                        .font(.system(size: Values.veryLargeFontSize))
                                        .foregroundColor(themeColor: .conversationButton_unreadBubbleText)
                                        .background(
                                            Circle()
                                                .fill(themeColor: .conversationButton_unreadBubbleBackground)
                                                .frame(
                                                    width: ConversationList.unreadCountViewSize,
                                                    height: ConversationList.unreadCountViewSize
                                                )
                                        )
                                }
                            )
                            .backgroundColor(themeColor: .conversationButton_unreadBackground)
                            .frame(
                                width: .infinity,
                                height: 68
                            )
                        }
                    }
                case .threads:
                    Section {
                        ForEach(sectionModel.elements) { threadViewModel in
                            let info: Info = Info(threadViewModel: threadViewModel)
                            
                            HStack(
                                alignment: .center,
                                content: {
                                    if info.isBlocked {
                                        Rectangle()
                                            .fill(themeColor: .danger)
                                            .frame(
                                                width: Values.accentLineThickness,
                                                height: .infinity
                                            )
                                    } else if info.unreadCount > 0 {
                                        Rectangle()
                                            .fill(themeColor: .conversationButton_unreadStripBackground)
                                            .frame(
                                                width: Values.accentLineThickness,
                                                height: .infinity
                                            )
                                    }
                                    
                                    ProfilePictureSwiftUI(
                                        size: .list,
                                        publicKey: threadViewModel.threadId,
                                        threadVariant: threadViewModel.threadVariant,
                                        customImageData: threadViewModel.openGroupProfilePictureData,
                                        profile: threadViewModel.profile,
                                        additionalProfile: threadViewModel.additionalProfile
                                    )
                                    
                                    VStack(
                                        alignment: .leading,
                                        spacing: Values.verySmallSpacing,
                                        content: {
                                            HStack(
                                                spacing: Values.verySmallSpacing,
                                                content: {
                                                    // Display name
                                                    Text(info.displayName)
                                                        .bold()
                                                        .font(.system(size: Values.mediumFontSize))
                                                        .foregroundColor(themeColor: .textPrimary)
                                                    
                                                    if info.isPinned {
                                                        Image("Pin")
                                                            .resizable()
                                                            .renderingMode(.template)
                                                            .foregroundColor(themeColor: .textSecondary)
                                                            .scaledToFit()
                                                            .frame(
                                                                width: ConversationList.unreadCountViewSize,
                                                                height: ConversationList.unreadCountViewSize
                                                            )
                                                    }
                                                    
                                                    // Unread count
                                                    if info.shouldShowUnreadCount {
                                                        Text(info.unreadCountString)
                                                            .bold()
                                                            .font(.system(size: info.unreadCountFontSize))
                                                            .foregroundColor(themeColor: .conversationButton_unreadBubbleText)
                                                            .background(
                                                                Capsule()
                                                                    .fill(themeColor: .conversationButton_unreadBubbleBackground)
                                                                    .frame(minWidth: ConversationList.unreadCountViewSize)
                                                                    .frame(height: ConversationList.unreadCountViewSize)
                                                            )
                                                    }
                                                    
                                                    // Unread icon
                                                    if info.shouldShowUnreadIcon {
                                                        ZStack(
                                                            alignment: .topTrailing,
                                                            content: {
                                                                Image(systemName: "envelope")
                                                                    .font(.system(size: Values.verySmallFontSize))
                                                                    .foregroundColor(themeColor: .textPrimary)
                                                                    .padding(.top, 2)
                                                                
                                                                Circle()
                                                                    .fill(themeColor: .conversationButton_unreadBackground)
                                                                    .frame(
                                                                        width: 6,
                                                                        height: 6
                                                                    )
                                                                    .padding(.top, 1)
                                                                    .padding(.trailing, 1)
                                                            }
                                                        )
                                                    }
                                                    
                                                    // Mention icon
                                                    if info.shouldShowMentionIcon {
                                                        Text("@") // stringlint:disable
                                                            .bold()
                                                            .font(.system(size: Values.verySmallFontSize))
                                                            .foregroundColor(themeColor: .conversationButton_unreadBubbleText)
                                                            .background(
                                                                Circle()
                                                                    .fill(themeColor: .conversationButton_unreadBubbleBackground)
                                                                    .frame(
                                                                        width: ConversationList.unreadCountViewSize,
                                                                        height: ConversationList.unreadCountViewSize
                                                                    )
                                                            )
                                                    }
                                                    
                                                    Spacer()
                                                    
                                                    // Interaction time
                                                    Text(info.timeString)
                                                        .font(.system(size: Values.smallFontSize))
                                                        .foregroundColor(themeColor: .textSecondary)
                                                        .opacity(Values.lowOpacity)
                                                }
                                            )
                                            
                                            HStack(
                                                spacing: Values.verySmallSpacing,
                                                content: {
                                                    if info.shouldShowTypingIndicator {
                                                        
                                                    } else {
                                                        AttributedText(info.snippet)
                                                    }
                                                    
                                                    Spacer()
                                                    
                                                    
                                                }
                                            )
                                        }
                                    )
                                }
                            )
                            .backgroundColor(themeColor: info.themeBackgroundColor)
                            .frame(
                                width: .infinity,
                                height: 68
                            )
                        }
                    }
                default: preconditionFailure("Other sections should have no content")
            }
        }
        .transparentListBackground()
    }
}

// MARK: Conversation list row info

struct Info {
    let displayName: String
    let unreadCount: UInt
    let threadIsUnread: Bool
    let themeBackgroundColor: ThemeValue
    let isBlocked: Bool
    let isPinned: Bool
    let shouldShowUnreadCount: Bool
    let unreadCountString: String
    let unreadCountFontSize: CGFloat
    let shouldShowUnreadIcon: Bool
    let shouldShowMentionIcon: Bool
    let timeString: String
    let shouldShowTypingIndicator: Bool
    let snippet: NSAttributedString
    
    init(threadViewModel: SessionThreadViewModel) {
        self.displayName = threadViewModel.displayName
        self.unreadCount = (threadViewModel.threadUnreadCount ?? 0)
        self.threadIsUnread = (
            self.unreadCount > 0 ||
            threadViewModel.threadWasMarkedUnread == true
        )
        self.themeBackgroundColor = (self.threadIsUnread ?
            .conversationButton_unreadBackground :
            .conversationButton_background
        )
        self.isBlocked = (threadViewModel.threadIsBlocked == true)
        self.isPinned = threadViewModel.threadPinnedPriority > 0
        self.shouldShowUnreadCount = (threadIsUnread && unreadCount > 0)
        self.unreadCountString = (unreadCount < 10000 ? "\(unreadCount)" : "9999+")
        self.unreadCountFontSize = (unreadCount < 10000 ? Values.verySmallFontSize : 8)
        self.shouldShowUnreadIcon = (threadIsUnread && !self.shouldShowUnreadCount)
        self.shouldShowMentionIcon = (
            (threadViewModel.threadUnreadMentionCount ?? 0) > 0 &&
            threadViewModel.threadVariant != .contact
        )
        self.timeString = threadViewModel.lastInteractionDate.formattedForDisplay
        self.shouldShowTypingIndicator = (threadViewModel.threadContactIsTyping == true)
        let textColor: UIColor
        self.snippet = Self.getSnippet(threadViewModel: threadViewModel)
    }
    
    private static func getSnippet(threadViewModel: SessionThreadViewModel) -> NSMutableAttributedString {
        // If we don't have an interaction then do nothing
        guard threadViewModel.interactionId != nil else { return NSMutableAttributedString() }
        
        var maybeTextColor: UIColor? {
            switch threadViewModel.interactionVariant {
                case .infoClosedGroupCurrentUserErrorLeaving:
                    return ThemeManager.currentTheme.color(for: .danger)
                case .infoClosedGroupCurrentUserLeaving:
                    return ThemeManager.currentTheme.color(for: .textSecondary)
                default:
                    return ThemeManager.currentTheme.color(for: .textPrimary)
            }
        }
        
        guard let textColor = maybeTextColor else {  return NSMutableAttributedString() }
        
        let result = NSMutableAttributedString()
        
        if Date().timeIntervalSince1970 < (threadViewModel.threadMutedUntilTimestamp ?? 0) {
            result.append(NSAttributedString(
                string: FullConversationCell.mutePrefix,
                attributes: [
                    .font: UIFont(name: "ElegantIcons", size: 10) as Any,
                    .foregroundColor: textColor
                ]
            ))
        }
        else if threadViewModel.threadOnlyNotifyForMentions == true {
            let imageAttachment = NSTextAttachment()
            imageAttachment.image = UIImage(named: "NotifyMentions.png")?.withTint(textColor)
            imageAttachment.bounds = CGRect(x: 0, y: -2, width: Values.smallFontSize, height: Values.smallFontSize)
            
            let imageString = NSAttributedString(attachment: imageAttachment)
            result.append(imageString)
            result.append(NSAttributedString(
                string: "  ",
                attributes: [
                    .font: UIFont(name: "ElegantIcons", size: 10) as Any,
                    .foregroundColor: textColor
                ]
            ))
        }
        
        if
            (threadViewModel.threadVariant == .legacyGroup || threadViewModel.threadVariant == .group || threadViewModel.threadVariant == .community) &&
            (threadViewModel.interactionVariant?.isGroupControlMessage == false)
        {
            let authorName: String = threadViewModel.authorName(for: threadViewModel.threadVariant)
            
            result.append(NSAttributedString(
                string: "\(authorName): ", // stringlint:disable
                attributes: [ .foregroundColor: textColor ]
            ))
        }
        
        let previewText: String = {
            if threadViewModel.interactionVariant == .infoClosedGroupCurrentUserErrorLeaving {
                return "groupLeaveErrorFailed"
                    .put(key: "group_name", value: threadViewModel.displayName)
                    .localized()
            }
            return Interaction.previewText(
                variant: (threadViewModel.interactionVariant ?? .standardIncoming),
                body: threadViewModel.interactionBody,
                threadContactDisplayName: threadViewModel.threadContactName(),
                authorDisplayName: threadViewModel.authorName(for: threadViewModel.threadVariant),
                attachmentDescriptionInfo: threadViewModel.interactionAttachmentDescriptionInfo,
                attachmentCount: threadViewModel.interactionAttachmentCount,
                isOpenGroupInvitation: (threadViewModel.interactionIsOpenGroupInvitation == true)
            )
        }()
        
        result.append(NSAttributedString(
            string: MentionUtilities.highlightMentionsNoAttributes(
                in: previewText,
                threadVariant: threadViewModel.threadVariant,
                currentUserPublicKey: threadViewModel.currentUserPublicKey,
                currentUserBlinded15PublicKey: threadViewModel.currentUserBlinded15PublicKey,
                currentUserBlinded25PublicKey: threadViewModel.currentUserBlinded25PublicKey
            ),
            attributes: [ .foregroundColor: textColor ]
        ))
            
        return result
    }
}

struct ConversationList_Previews: PreviewProvider {
    @State static var viewModel: HomeViewModel = HomeViewModel()
    
    static var previews: some View {
        ConversationList(viewModel: $viewModel)
    }
}
