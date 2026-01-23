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
        createInstance: { dependencies, _ in SessionApp(using: dependencies) }
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
    
    public func presentConversationCreatingIfNeeded(
        for threadId: String,
        variant: SessionThread.Variant,
        action: ConversationViewModel.Action = .none,
        dismissing presentingViewController: UIViewController?,
        animated: Bool
    ) async {
        guard let homeViewController: HomeVC = self.homeViewController else {
            Log.error("[SessionApp] Unable to present conversation due to missing HomeVC.")
            return
        }
        
        /// The thread should generally exist at the time of calling this method, but on the off chance it doesn't then we need to
        /// `fetchOrCreate` it and should do it on a background thread just in case something is keeping the DBWrite thread
        /// busy as in the past this could cause the app to hang
        let threadExists: Bool? = try? await dependencies[singleton: .storage].readAsync { db in
            SessionThread.filter(id: threadId).isNotEmpty(db)
        }
        
        if threadExists != true {
            _ = try? await dependencies[singleton: .storage].writeAsync { [dependencies] db in
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
            }
        }
        
        let maybeThreadInfo: ConversationInfoViewModel? = try? await ConversationViewModel.fetchConversationInfo(
            threadId: threadId,
            using: dependencies
        )
        
        guard let threadInfo: ConversationInfoViewModel = maybeThreadInfo else {
            Log.error("Failed to present \(variant) conversation \(threadId) due to failure to fetch threadViewModel")
            return
        }
        
        await MainActor.run { [weak self] in
            self?.showConversation(
                threadInfo: threadInfo,
                action: action,
                dismissing: presentingViewController,
                homeViewController: homeViewController,
                animated: animated
            )
        }
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
        
        /// Wait for a small duration before killing the app (hoping to avoid a crash due to `libSession` shutting down connections
        /// which result in spdlog trying to log and crashing)
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(10)) {
            exit(0)
        }
    }
    
    /// Show Session Network Page for this release. We'll be able to extend this fuction to show other screens that is new
    /// or we want to promote in the future.
    @MainActor public func showPromotedScreen() {
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
    
    @MainActor private func showConversation(
        threadInfo: ConversationInfoViewModel,
        action: ConversationViewModel.Action,
        dismissing presentingViewController: UIViewController?,
        homeViewController: HomeVC,
        animated: Bool
    ) {
        presentingViewController?.dismiss(animated: true, completion: nil)
        
        homeViewController.navigationController?.setViewControllers(
            [
                homeViewController,
                (threadInfo.isMessageRequest && action != .compose ?
                    SessionTableViewController(viewModel: MessageRequestsViewModel(using: dependencies)) :
                    nil
                ),
                ConversationVC(
                    threadInfo: threadInfo,
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
    @MainActor func showHomeView()
    func presentConversationCreatingIfNeeded(
        for threadId: String,
        variant: SessionThread.Variant,
        action: ConversationViewModel.Action,
        dismissing presentingViewController: UIViewController?,
        animated: Bool
    ) async
    func createNewConversation()
    func resetData(onReset: (() -> ()))
    @MainActor func showPromotedScreen()
}

public extension SessionAppType {
    func resetData() { resetData(onReset: {}) }
}
