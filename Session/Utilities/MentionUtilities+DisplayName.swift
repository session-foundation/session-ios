// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import GRDB
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit

public extension MentionUtilities {
    static func highlightMentionsNoAttributes(
        in string: String,
        threadVariant: SessionThread.Variant,
        currentUserSessionIds: Set<String>,
        using dependencies: Dependencies
    ) -> String {
        return MentionUtilities.highlightMentionsNoAttributes(
            in: string,
            currentUserSessionIds: currentUserSessionIds,
            displayNameRetriever: { sessionId, _ in
                // FIXME: This does a database query and is happening when populating UI - should try to refactor it somehow (ideally resolve a set of mentioned profiles as part of the database query)
                return Profile.displayNameNoFallback(
                    id: sessionId,
                    threadVariant: threadVariant,
                    using: dependencies
                )
            }
        )
    }
        
    static func highlightMentions(
        in string: String,
        threadVariant: SessionThread.Variant,
        currentUserSessionIds: Set<String>,
        location: MentionLocation,
        textColor: ThemeValue,
        attributes: [NSAttributedString.Key: Any],
        using dependencies: Dependencies
    ) -> ThemedAttributedString {
        return MentionUtilities.highlightMentions(
            in: string,
            currentUserSessionIds: currentUserSessionIds,
            location: location,
            textColor: textColor,
            attributes: attributes,
            displayNameRetriever: { sessionId, _ in
                // FIXME: This does a database query and is happening when populating UI - should try to refactor it somehow (ideally resolve a set of mentioned profiles as part of the database query)
                return Profile.displayNameNoFallback(
                    id: sessionId,
                    threadVariant: threadVariant,
                    using: dependencies
                )
            },
            using: dependencies
        )
    }
}
