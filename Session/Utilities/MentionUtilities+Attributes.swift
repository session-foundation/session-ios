// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit
import SessionUtilitiesKit


public extension MentionUtilities {
    static func highlightMentions(
        in string: String,
        currentUserSessionIds: Set<String>,
        location: MentionLocation,
        textColor: ThemeValue,
        attributes: [NSAttributedString.Key: Any],
        displayNameRetriever: (String, Bool) -> String?,
        using dependencies: Dependencies
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
                ).toImage(using: dependencies)

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

public extension HighlightMentionView {
    func toImage(using dependencies: Dependencies) -> UIImage {
        let themePrimaryColor: Theme.PrimaryColor = dependencies
            .mutate(cache: .libSession) { $0.get(.themePrimaryColor) }
            .defaulting(to: .defaultPrimaryColor)
        let cacheKey: String = "Mention.CurrentUser.\(themePrimaryColor)" // stringlint:ignore
        
        if let cachedImage = dependencies[cache: .generalUI].get(for: cacheKey) {
            return cachedImage
        }
        
        let renderedImage = self.toImage(isOpaque: self.isOpaque, scale: UIScreen.main.scale)
        dependencies.mutate(cache: .generalUI) { $0.cache(renderedImage, for: cacheKey) }
        return renderedImage
    }
}
