// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUIKit
import SessionUtilitiesKit

struct AppReviewPromptModel {
    let title: String
    let message: String
    
    var primaryButtonTitle: String?
    var primaryButtonColor: ThemeValue?
    var primaryButtonAccessibilityIdentifier: String?
    
    var secondaryButtonTitle: String?
    var secondaryButtonColor: ThemeValue?
    var secondaryButtonAccessibilityIdentifier: String?
}

extension AppReviewPromptModel {
    // Base version where app review prompt became available
    static private let reviewPromptAvailabilityVersion = "2.14.2" // stringlint:ignore
    
    /// Determines the initial state of the app review prompt.
    static func loadInitialAppReviewPromptState(using dependencies: Dependencies) -> AppReviewPromptState?  {
        var promptState: AppReviewPromptState?
        
        if checkAndRefreshAppReviewState(using: dependencies) {
            promptState = .rateSession
            
        } else if dependencies[defaults: .standard, key: .didShowAppReviewPrompt] && !dependencies[defaults: .standard, key: .didActionAppReviewPrompt] {
            dependencies[defaults: .standard, key: .didShowAppReviewPrompt] = false
            
            promptState = .enjoyingSession
        }
        
        return promptState
    }
    
    static func checkAndRefreshAppReviewState(using dependencies: Dependencies) -> Bool {
        /// Check if incomplete app review can be shown again to user on next app launch
        let retryCount = dependencies[defaults: .standard, key: .rateAppRetryAttemptCount]

        // A buffer of 1 hour
        let buffer: TimeInterval = 60 * 60
        
        if retryCount == 0, let retryDate = dependencies[defaults: .standard, key: .rateAppRetryDate], dependencies.dateNow.timeIntervalSince(retryDate) >= -buffer {
            // This block will execute if the current time is within 1 hour of the retryDate
            // or if the current time is past the retryDate.
            dependencies[defaults: .standard, key: .rateAppRetryDate] = nil
            dependencies[defaults: .standard, key: .rateAppRetryAttemptCount] = 1
            dependencies[defaults: .standard, key: .didShowAppReviewPrompt] = false
            
            return true
        }
        
        return false
    }
    
    /// Checks if version was from install or from update
    static func checkIfAppWasInstalledPriorToAppReviewRelease(using dependencies: Dependencies) -> Bool {
        guard let firstAppVersion = dependencies[cache: .appVersion].firstAppVersion else {
            return false
        }
        
        let comparisonResult = firstAppVersion.compare(
            reviewPromptAvailabilityVersion,
            options: .numeric
        )
        
        // App was updated to the latest version with app review prompt
        return comparisonResult == .orderedAscending
    }
}

enum AppReviewPromptState {
    case enjoyingSession
    case rateSession
    case feedback
    case rateLimit
    
    var promptContent: AppReviewPromptModel {
        switch self {
            case .enjoyingSession:
                return AppReviewPromptModel(
                    title: "enjoyingSession"
                        .put(key: "app_name", value:  Constants.app_name)
                        .localized(),
                    message: "enjoyingSessionDescription"
                        .put(key: "app_name", value:  Constants.app_name)
                        .localized(),
                    primaryButtonTitle: "enjoyingSessionButtonNegative"
                        .put(key: "emoji", value: "😕")
                        .localized(),
                    primaryButtonColor: .textPrimary,
                    primaryButtonAccessibilityIdentifier: "enjoy-session-negative-button",
                    secondaryButtonTitle: "enjoyingSessionButtonPositive"
                        .put(key: "emoji", value: "❤️")
                        .localized(),
                    secondaryButtonColor: .sessionButton_text,
                    secondaryButtonAccessibilityIdentifier: "enjoy-session-positive-button"
                )
            
            case .rateSession:
                /// In this case the full `platformStore` value was found to be too verbose so remove the leading `Apple `
                /// to make it more succinct
                let storeVaraint: String = Constants.platform_store
                    .replacingOccurrences(of: "Apple ", with: "")   // stringlint:ignore
                
                return AppReviewPromptModel(
                    title: "rateSession"
                        .put(key: "app_name", value: Constants.app_name)
                        .localized(),
                    message: "rateSessionModalDescriptionUpdated"
                        .put(key: "app_name", value: Constants.app_name)
                        .put(key: "storevariant", value: storeVaraint)
                        .localized(),
                    primaryButtonTitle: "rateUs".localized(),
                    primaryButtonColor: .sessionButton_text,
                    primaryButtonAccessibilityIdentifier: "rate-app-button",
                    secondaryButtonTitle: nil,
                    secondaryButtonColor: nil,
                    secondaryButtonAccessibilityIdentifier: nil
                )
            
            case .feedback:
                return AppReviewPromptModel(
                    title: "giveFeedback".localized(),
                    message: "giveFeedbackDescription"
                        .put(key: "app_name", value: Constants.app_name)
                        .localized(),
                    primaryButtonTitle: "openSurvey".localized(),
                    primaryButtonColor: .sessionButton_text,
                    primaryButtonAccessibilityIdentifier: "open-survey-button",
                    secondaryButtonTitle: "notNow".localized(),
                    secondaryButtonColor: .textPrimary,
                    secondaryButtonAccessibilityIdentifier: "not-now-button"
                )
            
            case .rateLimit:
                return AppReviewPromptModel(
                    title: "reviewLimit".localized(),
                    message: "reviewLimitDescription"
                        .put(key: "app_name", value: Constants.app_name)
                        .localized()
                )
        }
    }
}
