// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUtilitiesKit
import StoreKit

public extension Singleton {
    static let appReviewManager: SingletonConfig<AppReviewManager> = Dependencies.create(
        identifier: "appReviewManager",
        createInstance: { dependencies in AppReviewManager(using: dependencies) }
    )
}

public enum AppReviewTrigger {
    case pathScreenVisit
    case donateButtonPress
    case themeChange
}

// MARK: - AppReviewManager
public class AppReviewManager: NSObject, ObservableObject {
    private let dependencies: Dependencies
    
    @Published var currentPrompToShow: AppReviewPromptState = .none
    
    private var pendingPrompt: AppReviewPromptState? = nil
    private var shouldTriggerReview: Bool = false
    
    // MARK: - Initialization
    fileprivate init(using dependencies: Dependencies) {
        self.dependencies = dependencies
        
        super.init()
    }
    
    func checkIfCanRetryAppReview() {
        let retryCount = dependencies[defaults: .standard, key: .rateAppRetryAttemptCount]
        
        if retryCount == 0, let retryDate = dependencies[defaults: .standard, key: .rateAppRetryDate], Date() >= retryDate {
            pendingPrompt = .rateSession
            shouldTriggerReview = true
            
            dependencies[defaults: .standard, key: .rateAppRetryDate] = nil
            dependencies[defaults: .standard, key: .rateAppRetryAttemptCount] = 1
        }
    }
    
    func triggerReview(for trigger: AppReviewTrigger) {
        currentPrompToShow = .none
        shouldTriggerReview = false
        
        let didShowAppReviewPrompt = dependencies[defaults: .standard, key: .didShowAppReviewPrompt]
        
        guard didShowAppReviewPrompt == false else {
            // Skip triggers since it was already shown
            return
        }
        
        switch trigger {
        case .pathScreenVisit:
            let hasVisitedPathScreen = dependencies[defaults: .standard, key: .hasVisitedPathScreen]
       
            if !hasVisitedPathScreen {
                dependencies[defaults: .standard, key: .hasVisitedPathScreen] = true
                
                shouldTriggerReview = true
            }
        case .donateButtonPress:
            let hasPressedDonate = dependencies[defaults: .standard, key: .hasDonated]
       
            if !hasPressedDonate {
                dependencies[defaults: .standard, key: .hasDonated] = true
                
                shouldTriggerReview = true
            }
        case .themeChange:
            let hasChangedTheme = dependencies[defaults: .standard, key: .hasChangedTheme]
       
            if !hasChangedTheme {
                dependencies[defaults: .standard, key: .hasChangedTheme] = true
                
                shouldTriggerReview = true
            }
        }
    }
    
    func shouldShowReviewModalNextTime() {
        guard shouldTriggerReview else { return }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self, dependencies] in
            self?.currentPrompToShow = self?.pendingPrompt ?? .enjoyingSession
            self?.shouldTriggerReview = false
            
            dependencies[defaults: .standard, key: .didShowAppReviewPrompt] = true
            self?.pendingPrompt = nil
        }
    }

    func willSubmitAppReview() {
        dependencies[defaults: .standard, key: .rateAppRetryDate] = nil
        dependencies[defaults: .standard, key: .rateAppRetryAttemptCount] = 0
        
        if let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene {
            SKStoreReviewController.requestReview(in: scene)
        }
    }
    
    func scheduleAppReviewRetry() {
        guard let retryDate = Calendar.current.date(byAdding: .weekOfYear, value: 2, to: Date()) else {
            return
        }
        
        dependencies[defaults: .standard, key: .rateAppRetryDate] = retryDate
    }
    
    // For testing purposes
    func clearFlags() {
        dependencies[defaults: .standard, key: .didShowAppReviewPrompt] = false
        dependencies[defaults: .standard, key: .hasVisitedPathScreen] = false
        dependencies[defaults: .standard, key: .hasDonated] = false
        dependencies[defaults: .standard, key: .hasChangedTheme] = false
        dependencies[defaults: .standard, key: .rateAppRetryDate] = nil
        dependencies[defaults: .standard, key: .rateAppRetryAttemptCount] = 0
    }
}
