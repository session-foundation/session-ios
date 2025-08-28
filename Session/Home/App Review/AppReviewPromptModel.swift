// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUIKit

struct AppReviewPromptModel {
    let title: String
    let message: String
    
    let primaryButtonTitle: String
    let primaryButtonAccessibilityIdentifier: String
    
    let secondaryButtonTitle: String
    let secondaryButtonAccessibilityIdentifier: String
}

enum AppReviewPromptState {
    case enjoyingSession
    case rateSession
    case feedback
}

extension AppReviewPromptState {
    var promptContent: AppReviewPromptModel {
        switch self {
        case .enjoyingSession:
            return .init(
                title: "enjoyingSession"
                    .put(key: "app_name", value:  Constants.app_name)
                    .localized(),
                message: "enjoyingSessionDescription"
                    .put(key: "app_name", value:  Constants.app_name)
                    .localized(),
                primaryButtonTitle: "enjoyingSessionButtonPositive"
                    .put(key: "emoji", value: "❤️")
                    .localized(),
                primaryButtonAccessibilityIdentifier: "enjoy-session-positive-button",
                secondaryButtonTitle: "enjoyingSessionButtonNegative"
                    .put(key: "emoji", value: "😕")
                    .localized(),
                secondaryButtonAccessibilityIdentifier: "enjoy-session-negative-button"
            )
        case .rateSession:
            return .init(
                title: "rateSession"
                    .put(key: "app_name", value: Constants.app_name)
                    .localized(),
                message: "rateSessionModalDescription"
                    .put(key: "app_name", value: Constants.app_name)
                    .put(key: "storevariant", value: Constants.store_name)
                    .localized(),
                primaryButtonTitle: "rateSessionApp".localized(),
                primaryButtonAccessibilityIdentifier: "rate-app-button",
                secondaryButtonTitle: "notNow".localized(),
                secondaryButtonAccessibilityIdentifier: "not-now-button"
            )
        case .feedback:
            return .init(
                title: "giveFeedback".localized(),
                message: "giveFeedbackDescription"
                    .put(key: "app_name", value: Constants.app_name)
                    .localized(),
                primaryButtonTitle: "openSurvey".localized(),
                primaryButtonAccessibilityIdentifier: "open-survey-button",
                secondaryButtonTitle: "notNow".localized(),
                secondaryButtonAccessibilityIdentifier: "not-now-button"
            )
        }
    }
}
