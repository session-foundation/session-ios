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
            displayNameRetriever: Profile.defaultDisplayNameRetriever(
                threadVariant: threadVariant,
                using: dependencies
            )
        )
    }
}
