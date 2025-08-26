// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUIKit

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
                secondaryButtonTitle: "enjoyingSessionButtonNegative"
                    .put(key: "emoji", value: "😕")
                    .localized()
            )
        case .rateSession:
            return .init(
                title: "rateSession"
                    .put(key: "app_name", value: Constants.app_name)
                    .localized(),
                message: "rateSessionModalDescription"
                    .put(key: "app_name", value: Constants.app_name)
                    .put(key: "storevariant", value: "App Store")
                    .localized(),
                primaryButtonTitle: "rateSessionApp".localized(),
                secondaryButtonTitle: "notNow".localized()
            )
        case .feedback:
            return .init(
                title: "giveFeedback".localized(),
                message: "giveFeedbackDescription"
                    .put(key: "app_name", value: Constants.app_name)
                    .localized(),
                primaryButtonTitle: "openSurvey".localized(),
                secondaryButtonTitle: "notNow".localized()
            )
        }
    }
}
