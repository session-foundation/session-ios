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
        let result: ThemedAttributedString = ThemedAttributedString(string: string, attributes: attributes)
        mentions.forEach { mention in
            result.addAttribute(.font, value: UIFont.boldSystemFont(ofSize: Values.smallFontSize), range: mention.range)
            
            if mention.isCurrentUser && location == .incomingMessage {
                // Note: The designs don't match with the dynamic sizing so these values need to be calculated
                // to maintain a "rounded rect" effect rather than a "pill" effect
                result.addAttribute(.currentUserMentionBackgroundCornerRadius, value: (8 * sizeDiff), range: mention.range)
                result.addAttribute(.currentUserMentionBackgroundPadding, value: (3 * sizeDiff), range: mention.range)
                result.addAttribute(.currentUserMentionBackgroundColor, value: ThemeValue.primary, range: mention.range)
                
                // Only add the additional kern if the mention isn't at the end of the string (otherwise this
                // would crash due to an index out of bounds exception)
                if mention.range.upperBound < result.length {
                    result.addAttribute(.kern, value: (3 * sizeDiff), range: NSRange(location: mention.range.upperBound, length: 1))
                }
            }
            
            var targetColor: ThemeValue = textColor
            
            switch (location, mention.isCurrentUser) {
                // 1 - Incoming messages where the mention is for the current user
                case (.incomingMessage, true):
                    targetColor = .dynamicForInterfaceStyle(light: textColor, dark: .black)
                
                // 2 - Incoming messages where the mention is for another user
                case (.incomingMessage, false):
                    targetColor = .dynamicForInterfaceStyle(light: textColor, dark: .primary)
                    
                // 3 - Outgoing messages
                case (.outgoingMessage, _):
                    targetColor = .dynamicForInterfaceStyle(light: textColor, dark: .black)
                
                // 4 - Mentions in quotes
                case (.outgoingQuote, _):
                    targetColor = .dynamicForInterfaceStyle(light: textColor, dark: .black)
                case (.incomingQuote, _):
                    targetColor = .dynamicForInterfaceStyle(light: textColor, dark: .primary)
                    
                // 5 - Mentions in quote drafts
                case (.quoteDraft, _), (.styleFree, _):
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
