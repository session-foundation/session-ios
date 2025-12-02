// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import UIKit

public typealias DisplayNameRetriever = (_ sessionId: String, _ inMessageBody: Bool) -> String?

public enum MentionUtilities {
    private static let currentUserCacheKey: String = "Mention.CurrentUser" // stringlint:ignore
    private static let pubkeyRegex: NSRegularExpression = try! NSRegularExpression(pattern: "@[0-9a-fA-F]{66}", options: [])
    private static let mentionFont: UIFont = .boldSystemFont(ofSize: Values.smallFontSize)
    private static let currentUserMentionImageSizeDiff: CGFloat = (Values.smallFontSize / Values.mediumFontSize)
    
    public enum MentionLocation {
        case incomingMessage
        case outgoingMessage
        case incomingQuote
        case outgoingQuote
        case quoteDraft
        case styleFree
    }
    
    public static func allPubkeys(in string: String) -> Set<String> {
        guard !string.isEmpty else { return [] }
        
        return Set(pubkeyRegex
            .matches(in: string, range: NSRange(string.startIndex..., in: string))
            .compactMap { match in Range(match.range, in: string).map { String(string[$0]) } })
    }
    
    @MainActor public static func generateCurrentUserMentionImage(textColor: ThemeValue) -> UIImage {
        return UIView.image(
            for: .themedKey(
                MentionUtilities.currentUserCacheKey,
                themeBackgroundColor: .primary
            ),
            generator: {
                HighlightMentionView(
                    mentionText: "@\("you".localized())",    // stringlint:ignore
                    font: mentionFont,
                    themeTextColor: .dynamicForInterfaceStyle(light: textColor, dark: .black),
                    themeBackgroundColor: .primary,
                    backgroundCornerRadius: (8 * currentUserMentionImageSizeDiff),
                    backgroundPadding: (3 * currentUserMentionImageSizeDiff)
                )
            }
        )
    }
    
    public static func getMentions(
        in string: String,
        currentUserSessionIds: Set<String>,
        displayNameRetriever: DisplayNameRetriever
    ) -> (String, [(range: NSRange, profileId: String, isCurrentUser: Bool)]) {
        /// In `Localization` we manually insert RTL isolate markers to ensure mixked RTL/LTR strings
        var workingString: String = string
        let hasRLIPrefix: Bool = workingString.hasPrefix("\u{2067}")
        let hasPDISuffix: Bool = workingString.hasSuffix("\u{2069}")
            
        if hasRLIPrefix {
            workingString = String(workingString.dropFirst())
        }
        
        if hasPDISuffix {
            workingString = String(workingString.dropLast())
        }

        var string: String = workingString
        var lastMatchEnd: Int = 0
        var mentions: [(range: NSRange, profileId: String, isCurrentUser: Bool)] = []
        
        while let match: NSTextCheckingResult = pubkeyRegex.firstMatch(
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
        
        /// Need to add the RTL isolate markers back if we had them
        let finalString: String = (string.containsRTL ?
            "\(LocalizationHelper.forceRTLLeading)\(string)\(LocalizationHelper.forceRTLTrailing)" :
            string
        )
        
        return (finalString, mentions)
    }
    
    public static func highlightMentionsNoAttributes(
        in string: String,
        currentUserSessionIds: Set<String>,
        displayNameRetriever: DisplayNameRetriever
    ) -> String {
        let (string, _) = getMentions(
            in: string,
            currentUserSessionIds: currentUserSessionIds,
            displayNameRetriever: displayNameRetriever
        )
        
        return string
    }
    
    public static func highlightMentions(
        in string: String,
        currentUserSessionIds: Set<String>,
        location: MentionLocation,
        textColor: ThemeValue,
        attributes: [NSAttributedString.Key: Any],
        displayNameRetriever: DisplayNameRetriever,
        currentUserMentionImage: UIImage?
    ) -> ThemedAttributedString {
        let (string, mentions) = getMentions(
            in: string,
            currentUserSessionIds: currentUserSessionIds,
            displayNameRetriever: displayNameRetriever
        )
        
        let result = ThemedAttributedString(string: string, attributes: attributes)
        
        // Iterate in reverse so index ranges remain valid while replacing
        for mention in mentions.sorted(by: { $0.range.location > $1.range.location }) {
            if mention.isCurrentUser && location == .incomingMessage, let currentUserMentionImage {
                /// Set the `accessibilityLabel` to ensure it's still visible to accessibility inspectors
                let attachment: NSTextAttachment = NSTextAttachment()
                attachment.accessibilityLabel = (result.attributedString.string as NSString).substring(with: mention.range)
                
                let offsetY: CGFloat = (mentionFont.capHeight - currentUserMentionImage.size.height) / 2
                attachment.image = currentUserMentionImage
                attachment.bounds = CGRect(
                    x: 0,
                    y: offsetY,
                    width: currentUserMentionImage.size.width,
                    height: currentUserMentionImage.size.height
                )

                let attachmentString = NSMutableAttributedString(attachment: attachment)

                // Replace the mention text with the image attachment
                result.replaceCharacters(in: mention.range, with: attachmentString)

                let insertIndex = mention.range.location + attachmentString.length
                if insertIndex < result.attributedString.length {
                    result.addAttribute(.kern, value: (3 * currentUserMentionImageSizeDiff), range: NSRange(location: insertIndex, length: 1))
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
        displayNameRetriever: DisplayNameRetriever
    ) -> String {
        return MentionUtilities.highlightMentionsNoAttributes(
            in: self,
            currentUserSessionIds: currentUserSessionIds,
            displayNameRetriever: displayNameRetriever
        )
    }
}
