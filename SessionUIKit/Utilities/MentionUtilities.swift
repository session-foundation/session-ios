// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import UIKit

public typealias DisplayNameRetriever = (_ sessionId: String, _ inMessageBody: Bool) -> String?

public enum MentionUtilities {
    private static let currentUserCacheKey: String = "Mention.CurrentUser" // stringlint:ignore
    private static let pubkeyRegex: NSRegularExpression = try! NSRegularExpression(pattern: "@[0-9a-fA-F]{66}", options: [])
    private static let mentionCharacterSet: CharacterSet = CharacterSet(["@"]) // stringlint:ignore
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
            .compactMap { match in
                Range(match.range, in: string).map { range in
                    /// Need to remove the leading `@` as this should just retrieve the pubkeys
                    String(string[range]).trimmingCharacters(in: mentionCharacterSet)
                }
            })
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

        var nsString: NSString = (workingString as NSString)
        let fullRange = NSRange(location: 0, length: nsString.length)
        
        let resultString: NSMutableString = NSMutableString()
        var mentions: [(range: NSRange, profileId: String, isCurrentUser: Bool)] = []
        var lastSearchLocation: Int = 0
        
        pubkeyRegex.enumerateMatches(in: workingString, options: [], range: fullRange) { match, _, _ in
            guard let match else { return }
            
            /// Append everything before this match
            let rangeBefore: NSRange = NSRange(
                location: lastSearchLocation,
                length: (match.range.location - lastSearchLocation)
            )
            resultString.append(nsString.substring(with: rangeBefore))
            
            let sessionId: String = String(nsString.substring(with: match.range).dropFirst()) /// Drop the @
            let isCurrentUser: Bool = currentUserSessionIds.contains(sessionId)
            let displayName: String
            
            if isCurrentUser {
                displayName = "you".localized()
            }
            else if let retrievedName: String = displayNameRetriever(sessionId, true) {
                displayName = retrievedName
            } else {
                /// If we can't get a proper display name then we should just truncate the pubkey
                displayName = sessionId.truncated()
            }
            
            /// Append the resolved mame
            let replacement: String = "@\(displayName)" // stringlint:ignore
            let startLocation: Int = resultString.length
            resultString.append(replacement)
            
            /// Record the mention
            mentions.append((
                range: NSRange(location: startLocation, length: (replacement as NSString).length),
                profileId: sessionId,
                isCurrentUser: isCurrentUser
            ))
            
            lastSearchLocation = (match.range.location + match.range.length)
        }
        
        /// Append any remaining string
        if lastSearchLocation < nsString.length {
            let remainingRange = NSRange(location: lastSearchLocation, length: nsString.length - lastSearchLocation)
            resultString.append(nsString.substring(with: remainingRange))
        }
        
        /// Need to add the RTL isolate markers back if we had them
        let finalStringRaw: String = (resultString as String)
        let finalString: String = (string.containsRTL ?
            "\(LocalizationHelper.forceRTLLeading)\(finalStringRaw)\(LocalizationHelper.forceRTLTrailing)" :
            finalStringRaw
        )
        
        return (finalString, mentions)
    }
    
    // stringlint:ignore_contents
    public static func taggingMentions(
        in string: String,
        location: MentionLocation,
        currentUserSessionIds: Set<String>,
        displayNameRetriever: DisplayNameRetriever
    ) -> String {
        let (mentionReplacedString, mentions) = getMentions(
            in: string,
            currentUserSessionIds: currentUserSessionIds,
            displayNameRetriever: displayNameRetriever
        )
        
        guard !mentions.isEmpty else { return mentionReplacedString }
        
        let result: NSMutableString = NSMutableString(string: mentionReplacedString)
        
        /// Iterate in reverse so index ranges remain valid while replacing
        for mention in mentions.sorted(by: { $0.range.location > $1.range.location }) {
            let mentionText: String = (result as NSString).substring(with: mention.range)
            let tag: String = (mention.isCurrentUser && location == .incomingMessage ?
                ThemedAttributedString.HTMLTag.userMention.rawValue :   /// Only use for incoming
                ThemedAttributedString.HTMLTag.mention.rawValue
            )
            
            result.replaceCharacters(
                in: mention.range,
                with: "<\(tag)>\(mentionText)</\(tag)>"
            )
        }
        
        return (result as String)
    }
    
    public static func mentionColor(
        textColor: ThemeValue,
        location: MentionLocation
    ) -> ThemeValue {
        switch location {
            case .incomingMessage: return .dynamicForInterfaceStyle(light: textColor, dark: .primary)
            case .outgoingMessage: return .dynamicForInterfaceStyle(light: textColor, dark: .black)
            case .outgoingQuote: return .dynamicForInterfaceStyle(light: textColor, dark: .black)
            case .incomingQuote: return .dynamicForInterfaceStyle(light: textColor, dark: .primary)
            case .quoteDraft, .styleFree: return .dynamicForInterfaceStyle(light: textColor, dark: textColor)
        }
    }
    
    public static func currentUserMentionImageString(
        substring: String,
        currentUserMentionImage: UIImage?
    ) -> NSAttributedString {
        guard let currentUserMentionImage else { return NSAttributedString(string: substring) }
        
        /// Set the `accessibilityLabel` to ensure it's still visible to accessibility inspectors
        let attachment: NSTextAttachment = NSTextAttachment()
        attachment.accessibilityLabel = substring
        
        let offsetY: CGFloat = ((mentionFont.capHeight - currentUserMentionImage.size.height) / 2)
        attachment.image = currentUserMentionImage
        attachment.bounds = CGRect(
            x: 0,
            y: offsetY,
            width: currentUserMentionImage.size.width,
            height: currentUserMentionImage.size.height
        )

        return NSMutableAttributedString(attachment: attachment)
    }
}

public extension MentionUtilities {
    static func resolveMentions(
        in string: String,
        currentUserSessionIds: Set<String>,
        displayNameRetriever: DisplayNameRetriever
    ) -> String {
        return MentionUtilities.taggingMentions(
            in: string,
            location: .outgoingMessage, /// If we are replacing then we don't want to use the image
            currentUserSessionIds: currentUserSessionIds,
            displayNameRetriever: displayNameRetriever
        ).deformatted()
    }
}

public extension String {
    func replacingMentions(
        currentUserSessionIds: Set<String>,
        displayNameRetriever: DisplayNameRetriever
    ) -> String {
        return MentionUtilities.resolveMentions(
            in: self,
            currentUserSessionIds: currentUserSessionIds,
            displayNameRetriever: displayNameRetriever
        )
    }
}
