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
        let (string, _) = getMentions(
            in: string,
            currentUserSessionIds: currentUserSessionIds,
            displayNameRetriever: displayNameRetriever
        )
        
        return string
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
