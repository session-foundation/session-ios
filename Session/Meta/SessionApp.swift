// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionUtilitiesKit
import SessionMessagingKit
import SessionUIKit

// MARK: - Singleton

public extension Singleton {
    static let app: SingletonConfig<SessionAppType> = Dependencies.create(
        identifier: "app",
        createInstance: { dependencies in SessionApp(using: dependencies) }
    )
}

// MARK: - SessionApp

public class SessionApp: SessionAppType {
    private let dependencies: Dependencies
    private var homeViewController: HomeVC?
    
    @MainActor public var homePresentedViewController: UIViewController? {
        homeViewController?.presentedViewController
    }
    
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
            "libSession: \(LibSession.version)",
            commitInfo
        ].compactMap { $0 }
        
        return versionInfo.joined(separator: ", ")
    }
    
    // MARK: - Initialization
    
    init(using dependencies: Dependencies) {
        self.dependencies = dependencies
    }
    
    // MARK: - Functions
    
    public func setHomeViewController(_ homeViewController: HomeVC) {
        self.homeViewController = homeViewController
    }
    
    public func showHomeView() {
        guard Thread.isMainThread else {
            return DispatchQueue.main.async {
                self.showHomeView()
            }
        }
        
        let homeViewController: HomeVC = HomeVC(using: dependencies)
        let navController: UINavigationController = StyledNavigationController(rootViewController: homeViewController)
        (UIApplication.shared.delegate as? AppDelegate)?.window?.rootViewController = navController
        self.homeViewController = homeViewController
    }
    
    @MainActor public func presentConversationCreatingIfNeeded(
        for threadId: String,
        variant: SessionThread.Variant,
        action: ConversationViewModel.Action = .none,
        dismissing presentingViewController: UIViewController?,
        animated: Bool
    ) {
        guard let homeViewController: HomeVC = self.homeViewController else {
            Log.error("[SessionApp] Unable to present conversation due to missing HomeVC.")
            return
        }
        
        let threadExists: Bool? = dependencies[singleton: .storage].read { db in
            SessionThread.filter(id: threadId).isNotEmpty(db)
        }
        
        /// The thread should generally exist at the time of calling this method, but on the off chance it doesn't then we need to
        /// `fetchOrCreate` it and should do it on a background thread just in case something is keeping the DBWrite thread
        /// busy as in the past this could cause the app to hang
        creatingThreadIfNeededThenRunOnMain(
            threadId: threadId,
            variant: variant,
            threadExists: (threadExists == true),
            onComplete: { [weak self, dependencies] in
                self?.showConversation(
                    threadId: threadId,
                    threadVariant: variant,
                    isMessageRequest: dependencies.mutate(cache: .libSession) { cache in
                        cache.isMessageRequest(threadId: threadId, threadVariant: variant)
                    },
                    action: action,
                    dismissing: presentingViewController,
                    homeViewController: homeViewController,
                    animated: animated
                )
            }
        )
    }
    
    public func createNewConversation() {
        guard let homeViewController: HomeVC = self.homeViewController else { return }
        
        let viewController = SessionHostingViewController(
            rootView: StartConversationScreen(using: dependencies),
            customizedNavigationBackground: .backgroundSecondary
        )
        viewController.setNavBarTitle("conversationsStart".localized())
        viewController.setUpDismissingButton(on: .right)
        
        let navigationController = StyledNavigationController(rootViewController: viewController)
        if UIDevice.current.isIPad {
            navigationController.modalPresentationStyle = .fullScreen
        }
        navigationController.modalPresentationCapturesStatusBarAppearance = true
        homeViewController.present(navigationController, animated: true, completion: nil)
    }
    
    public func resetData(onReset: (() -> ())) {
        homeViewController = nil
        dependencies.remove(cache: .general)
        dependencies.remove(cache: .snodeAPI)
        dependencies.remove(cache: .libSession)
        dependencies.mutate(cache: .libSessionNetwork) {
            $0.suspendNetworkAccess()
            $0.clearSnodeCache()
            $0.clearCallbacks()
        }
        dependencies[singleton: .storage].resetAllStorage()
        dependencies[singleton: .extensionHelper].deleteCache()
        dependencies[singleton: .displayPictureManager].resetStorage()
        dependencies[singleton: .attachmentManager].resetStorage()
        dependencies[singleton: .notificationsManager].clearAllNotifications()
        try? dependencies[singleton: .keychain].removeAll()
        UserDefaults.removeAll(using: dependencies)
        
        onReset()
        LibSession.clearLoggers()
        Log.info("Data Reset Complete.")
        Log.flush()
        
        /// Wait until the next run loop to kill the app (hoping to avoid a crash due to the connection closes
        /// triggering logs)
        DispatchQueue.main.async {
            exit(0)
        }
    }
    
    /// Show Session Network Page for this release. We'll be able to extend this fuction to show other screens that is new
    /// or we want to promote in the future.
    public func showPromotedScreen() {
        guard let homeViewController: HomeVC = self.homeViewController else { return }
        
        let viewController: SessionHostingViewController = SessionHostingViewController(
            rootView: SessionNetworkScreen(
                viewModel: SessionNetworkScreenContent.ViewModel(dependencies: dependencies)
            )
        )
        viewController.setNavBarTitle(Constants.network_name)
        viewController.setUpDismissingButton(on: .left)
        
        let navigationController = StyledNavigationController(rootViewController: viewController)
        navigationController.modalPresentationStyle = .fullScreen
        homeViewController.present(navigationController, animated: true, completion: nil)
    }
    
    // MARK: - Internal Functions
    
    @MainActor private func creatingThreadIfNeededThenRunOnMain(
        threadId: String,
        variant: SessionThread.Variant,
        threadExists: Bool,
        onComplete: @escaping () -> Void
    ) {
        guard !threadExists else {
            return onComplete()
        }
        
        Task(priority: .userInitiated) { [storage = dependencies[singleton: .storage], dependencies] in
            storage.writeAsync(
                updates: { db in
                    try SessionThread.upsert(
                        db,
                        id: threadId,
                        variant: variant,
                        values: SessionThread.TargetValues(
                            shouldBeVisible: .useLibSession,
                            isDraft: .useExistingOrSetTo(true)
                        ),
                        using: dependencies
                    )
                },
                completion: { _ in
                    Task { @MainActor in onComplete() }
                }
            )
        }
    }
    
    @MainActor private func showConversation(
        threadId: String,
        threadVariant: SessionThread.Variant,
        isMessageRequest: Bool,
        action: ConversationViewModel.Action,
        dismissing presentingViewController: UIViewController?,
        homeViewController: HomeVC,
        animated: Bool
    ) {
        presentingViewController?.dismiss(animated: true, completion: nil)
        
        homeViewController.navigationController?.setViewControllers(
            [
                homeViewController,
                (isMessageRequest && action != .compose ?
                    SessionTableViewController(viewModel: MessageRequestsViewModel(using: dependencies)) :
                    nil
                ),
                ConversationVC(
                    threadId: threadId,
                    threadVariant: threadVariant,
                    focusedInteractionInfo: nil,
                    using: dependencies
                )
            ].compactMap { $0 },
            animated: animated
        )
    }
}

// MARK: - SessionAppType

public protocol SessionAppType {
    @MainActor var homePresentedViewController: UIViewController? { get }
    
    func setHomeViewController(_ homeViewController: HomeVC)
    func showHomeView()
    @MainActor func presentConversationCreatingIfNeeded(
        for threadId: String,
        variant: SessionThread.Variant,
        action: ConversationViewModel.Action,
        dismissing presentingViewController: UIViewController?,
        animated: Bool
    )
    func createNewConversation()
    func resetData(onReset: (() -> ()))
    func showPromotedScreen()
}

public extension SessionAppType {
    func resetData() { resetData(onReset: {}) }
}
