// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import UIKit

public enum MentionUtilities {
    public enum MentionLocation {
        case incomingMessage
        case outgoingMessage
        case incomingQuote
        case outgoingQuote
        case quoteDraft
        case styleFree
    }
    
    public static func getMentions(
        in string: String,
        currentUserSessionIds: Set<String>,
        displayNameRetriever: (String, Bool) -> String?
    ) -> (String, [(range: NSRange, profileId: String, isCurrentUser: Bool)]) {
        guard
            let regex: NSRegularExpression = try? NSRegularExpression(pattern: "@[0-9a-fA-F]{66}", options: [])
        else { return (string, []) }
        
        var string = string
        var lastMatchEnd: Int = 0
        var mentions: [(range: NSRange, profileId: String, isCurrentUser: Bool)] = []
        
        while let match: NSTextCheckingResult = regex.firstMatch(
            in: string,
            options: .withoutAnchoringBounds,
            range: NSRange(location: lastMatchEnd, length: string.utf16.count - lastMatchEnd)
        ) {
            guard let range: Range = Range(match.range, in: string) else { break }
            
            let sessionId: String = String(string[range].dropFirst()) // Drop the @
            let isCurrentUser: Bool = currentUserSessionIds.contains(sessionId)
            let maybeTargetString: String? = {
                guard !isCurrentUser else { return "you".localized() }
                guard let displayName: String = displayNameRetriever(sessionId, true) else {
                    lastMatchEnd = (match.range.location + match.range.length)
                    return nil
                }
                
                return displayName
            }()
            
            guard let targetString: String = maybeTargetString else { continue }
            
            string = string.replacingCharacters(in: range, with: "@\(targetString)")    // stringlint:ignore
            lastMatchEnd = (match.range.location + targetString.utf16.count)
            
            mentions.append((
                // + 1 to include the @
                range: NSRange(location: match.range.location, length: targetString.utf16.count + 1),
                profileId: sessionId,
                isCurrentUser: isCurrentUser
            ))
        }
        
        return (string, mentions)
    }
    
    public static func highlightMentionsNoAttributes(
        in string: String,
        currentUserSessionIds: Set<String>,
        displayNameRetriever: (String, Bool) -> String?
    ) -> String {
        /// **Note:** We are returning the string here so the 'textColor' and 'primaryColor' values are irrelevant
        return highlightMentions(
            in: string,
            currentUserSessionIds: currentUserSessionIds,
            location: .styleFree,
            textColor: .black,
            attributes: [:],
            displayNameRetriever: displayNameRetriever
        )
        .string
        .deformatted()
    }

    public static func highlightMentions(
        in string: String,
        currentUserSessionIds: Set<String>,
        location: MentionLocation,
        textColor: ThemeValue,
        attributes: [NSAttributedString.Key: Any],
        displayNameRetriever: (String, Bool) -> String?
    ) -> ThemedAttributedString {
        let (string, mentions) = getMentions(
            in: string,
            currentUserSessionIds: currentUserSessionIds,
            displayNameRetriever: displayNameRetriever
        )
        
        let sizeDiff: CGFloat = (Values.smallFontSize / Values.mediumFontSize)
        let result = ThemedAttributedString(string: string, attributes: attributes)
        let mentionFont = UIFont.boldSystemFont(ofSize: Values.smallFontSize)
        // Iterate in reverse so index ranges remain valid while replacing
        for mention in mentions.sorted(by: { $0.range.location > $1.range.location }) {
            if mention.isCurrentUser && location == .incomingMessage {
                // Build the rendered chip image
                let image = HighlightMentionView(
                    mentionText: (result.string as NSString).substring(with: mention.range),
                    font: mentionFont,
                    themeTextColor: .dynamicForInterfaceStyle(light: textColor, dark: .black),
                    themeBackgroundColor: .primary,
                    backgroundCornerRadius: (8 * sizeDiff),
                    backgroundPadding: (3 * sizeDiff)
                ).toImage()

                let attachment = NSTextAttachment()
                let offsetY = (mentionFont.capHeight - image.size.height) / 2
                attachment.image = image
                attachment.bounds = CGRect(
                    x: 0,
                    y: offsetY,
                    width: image.size.width,
                    height: image.size.height
                )

                let attachmentString = NSMutableAttributedString(attachment: attachment)

                // Replace the mention text with the image attachment
                result.replaceCharacters(in: mention.range, with: attachmentString)

                let insertIndex = mention.range.location + attachmentString.length
                if insertIndex < result.length {
                    result.addAttribute(.kern, value: (3 * sizeDiff), range: NSRange(location: insertIndex, length: 1))
                }
                continue
            }
            
            result.addAttribute(.font, value: mentionFont, range: mention.range)

            var targetColor: ThemeValue = textColor
            switch location {
                case .incomingMessage:
                    targetColor = .dynamicForInterfaceStyle(light: textColor, dark: .primary)
                case .outgoingMessage:
                    targetColor = .dynamicForInterfaceStyle(light: textColor, dark: .black)
                case .outgoingQuote:
                    targetColor = .dynamicForInterfaceStyle(light: textColor, dark: .black)
                case .incomingQuote:
                    targetColor = .dynamicForInterfaceStyle(light: textColor, dark: .primary)
                case .quoteDraft, .styleFree:
                    targetColor = .dynamicForInterfaceStyle(light: textColor, dark: textColor)
            }
            
            result.addAttribute(.themeForegroundColor, value: targetColor, range: mention.range)
        }
        
        return result
    }
}

public extension String {
    func replacingMentions(
        currentUserSessionIds: Set<String>,
        displayNameRetriever: (String, Bool) -> String?
    ) -> String {
        return MentionUtilities.highlightMentionsNoAttributes(
            in: self,
            currentUserSessionIds: currentUserSessionIds,
            displayNameRetriever: displayNameRetriever
        )
    }
}
