// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionUtilitiesKit
import SessionMessagingKit
import SessionUIKit

public struct SessionApp {
    // FIXME: Refactor this to be protocol based for unit testing (or even dynamic based on view hierarchy - do want to avoid needing to use the main thread to access them though)
    @ThreadSafeObject static var homeViewController: HomeVC? = nil
    @ThreadSafeObject static var currentlyOpenConversationViewController: ConversationVC? = nil
    
    static var versionInfo: String {
        let buildNumber: String = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String)
            .map { " (\($0))" }
            .defaulting(to: "")
        let appVersion: String? = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
            .map { "App: \($0)\(buildNumber)" }
        let commitInfo: String? = (Bundle.main.infoDictionary?["GitCommitHash"] as? String).map { "Commit: \($0)" }
        
        let versionInfo: [String] = [
            "iOS \(UIDevice.current.systemVersion)",
            appVersion,
            "libSession: \(LibSession.libSessionVersion)",
            commitInfo
        ].compactMap { $0 }
        
        return versionInfo.joined(separator: ", ")
    }
    
    // MARK: - View Convenience Methods
    
    public static func presentConversationCreatingIfNeeded(
        for threadId: String,
        variant: SessionThread.Variant,
        action: ConversationViewModel.Action = .none,
        dismissing presentingViewController: UIViewController?,
        animated: Bool,
        using dependencies: Dependencies
    ) {
        let threadInfo: (threadExists: Bool, isMessageRequest: Bool)? = Storage.shared.read { db in
            let isMessageRequest: Bool = {
                switch variant {
                    case .contact:
                        return SessionThread
                            .isMessageRequest(
                                id: threadId,
                                variant: .contact,
                                currentUserPublicKey: getUserHexEncodedPublicKey(db),
                                shouldBeVisible: nil,
                                contactIsApproved: (try? Contact
                                    .filter(id: threadId)
                                    .select(.isApproved)
                                    .asRequest(of: Bool.self)
                                    .fetchOne(db))
                                    .defaulting(to: false),
                                includeNonVisible: true
                            )
                        
                    default: return false
                }
            }()
            
            return (SessionThread.filter(id: threadId).isNotEmpty(db), isMessageRequest)
        }
        
        // Store the post-creation logic in a closure to avoid duplication
        let afterThreadCreated: () -> () = {
            presentingViewController?.dismiss(animated: true, completion: nil)
            
            homeViewController?.show(
                threadId,
                variant: variant,
                isMessageRequest: (threadInfo?.isMessageRequest == true),
                with: action,
                focusedInteractionInfo: nil,
                animated: animated
            )
        }
        
        /// The thread should generally exist at the time of calling this method, but on the off chance it doesn't then we need to
        /// `fetchOrCreate` it and should do it on a background thread just in case something is keeping the DBWrite thread
        /// busy as in the past this could cause the app to hang
        guard threadInfo?.threadExists == true else {
            DispatchQueue.global(qos: .userInitiated).async {
                Storage.shared.write { db in
                    try SessionThread.upsert(
                        db,
                        id: threadId,
                        variant: variant,
                        values: .existingOrDefault,
                        using: dependencies
                    )
                }

                // Send back to main thread for UI transitions
                DispatchQueue.main.async {
                    afterThreadCreated()
                }
            }
            return
        }
        
        // Send to main thread if needed
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                afterThreadCreated()
            }
            return
        }
        
        afterThreadCreated()
    }

    // MARK: - Functions
    
    public static func resetAppData(
        using dependencies: Dependencies,
        onReset: (() -> ())? = nil
    ) {
        LibSession.clearLoggers()
        LibSession.clearMemoryState(using: dependencies)
        LibSession.clearSnodeCache()
        LibSession.suspendNetworkAccess()
        PushNotificationAPI.resetKeys()
        dependencies.storage.resetAllStorage()
        ProfileManager.resetProfileStorage()
        Attachment.resetAttachmentStorage()
        AppEnvironment.shared.notificationPresenter.clearAllNotifications()
        
        onReset?()
        Log.info("Data Reset Complete.")
        Log.flush()

        /// Wait until the next run loop to kill the app (hoping to avoid a crash due to the connection closes
        /// triggering logs)
        DispatchQueue.main.async {
            exit(0)
        }
    }
    
    static func setHomeViewController(_ homeVC: HomeVC) {
        _homeViewController.set(to: homeVC)
    }
    
    static func setCurrentlyOpenConversationViewController(_ viewController: ConversationVC?) {
        _currentlyOpenConversationViewController.set(to: viewController)
    }
    
    public static func showHomeView(using dependencies: Dependencies) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                self.showHomeView(using: dependencies)
            }
            return
        }
        
        let homeViewController: HomeVC = HomeVC(using: dependencies)
        let navController: UINavigationController = StyledNavigationController(rootViewController: homeViewController)
        (UIApplication.shared.delegate as? AppDelegate)?.window?.rootViewController = navController
    }
}
