// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation

struct AppReviewPromptModel {
    let title: String
    let message: String
    
    let primaryButtonTitle: String
    let secondaryButtonTitle: String
}

enum AppReviewPromptState {
    case enjoyingSession
    case rateSession
    case feedback
    case none
}

extension AppReviewPromptState {
    var promptContent: AppReviewPromptModel {
        switch self {
        case .enjoyingSession:
            return .init(
                title: NSLocalizedString("Enjoying Session?", comment: "Title for the app review prompt dialog"),
                message: "You've been using Session for a little while, how’s it going? We’d really appreciate hearing your thoughts.",
                primaryButtonTitle: "It's Great ❤️",
                secondaryButtonTitle: "Needs Work 😕"
            )
        case .rateSession:
            return .init(
                title: "Rate Session?",
                message: "We're glad you're enjoying Session, if you have a moment, rating us in the App Store helps others discover private, secure messaging!",
                primaryButtonTitle: "Rate App",
                secondaryButtonTitle: "Not now"
            )
        case .feedback:
            return .init(
                title: "Give Feedback?",
                message: "Sorry to hear your Session experience hasn’t been ideal. We'd be grateful if you could take a moment to share your thoughts in a brief survey",
                primaryButtonTitle: "Open Survey",
                secondaryButtonTitle: "Not now"
            )
        case .none:
            return .init(title: "", message: "", primaryButtonTitle: "", secondaryButtonTitle: "")
        }
    }
}
