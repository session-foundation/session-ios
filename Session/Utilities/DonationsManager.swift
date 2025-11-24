// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit
import SessionUtilitiesKit

// MARK: - Singleton

public extension Singleton {
    static let donationsManager: SingletonConfig<DonationsManager> = Dependencies.create(
        identifier: "donationsManager",
        createInstance: { dependencies in DonationsManager(using: dependencies) }
    )
}

// MARK: - DonationsManager

public class DonationsManager {
    private static let appInstallAppearanceDelay: TimeInterval = (7 * 24 * 60 * 60) /// 7 days
    private static let appearanceDelays: [TimeInterval] = [
        0,                   /// Immediate
        (3 * 24 * 60 * 60),  /// 3 days after the first appearance
        (7 * 24 * 60 * 60),  /// 7 days after the previous appearance
        (21 * 24 * 60 * 60)  /// 21 days after the previous appearance
    ]
    
    private let dependencies: Dependencies
    @MainActor private var forceShowWasToggledThisSession: Bool = false
    
    // MARK: - Initialization
    
    public init(using dependencies: Dependencies) {
        self.dependencies = dependencies
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillEnterForeground(_:)),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - Functions
    
    @MainActor public func conversationListDidAppear() {
        /// If the user has opened or copied the donations url then we shouldn't show the CTA modal again
        guard
            dependencies[defaults: .standard, key: .donationsUrlOpenCount] == 0 &&
            dependencies[defaults: .standard, key: .donationsUrlCopyCount] == 0
        else { return }
        
        /// Don't show the modal if the app has been installed for less than 7 days (unless the user gave the app a great rating, in which
        /// case we _do_ want to show it)
        let appInstallationDate: Date = {
            let attributes: [FileAttributeKey: Any]? = try? dependencies[singleton: .fileManager]
                .attributesOfItem(atPath: dependencies[singleton: .fileManager].documentsDirectoryPath)
            
            return (attributes?[.creationDate] as? Date ?? Date.distantPast)
        }()
        
        guard
            dependencies.dateNow.timeIntervalSince(appInstallationDate) > DonationsManager.appInstallAppearanceDelay || (
                !forceShowWasToggledThisSession &&
                dependencies[defaults: .standard, key: .donationsCTAModalShouldForceShow]
            )
        else { return }
        
        /// Ensure there are still automatic appearances remaining
        let appearanceCount: Int = dependencies[defaults: .standard, key: .donationsCTAModalAppearanceCount]
        
        guard appearanceCount < DonationsManager.appearanceDelays.count else { return }
        
        let nextAppearanceDelay: TimeInterval = DonationsManager.appearanceDelays[min(appearanceCount, DonationsManager.appearanceDelays.count - 1)]
        let lastAppearanceTimestamp: TimeInterval = dependencies[defaults: .standard, key: .donationsCTAModalLastAppearanceTimestamp]
        let timeSinceLastAppearance: TimeInterval = dependencies.dateNow.timeIntervalSince(Date(timeIntervalSince1970: lastAppearanceTimestamp))
        
        guard
            (
                timeSinceLastAppearance > 0 &&
                timeSinceLastAppearance > nextAppearanceDelay
            ) || (
                !forceShowWasToggledThisSession &&
                dependencies[defaults: .standard, key: .donationsCTAModalShouldForceShow]
            )
        else { return }
        
        /// Reset the `donationsCTAModalShouldForceShow` flag (only want it to work once at a time)
        dependencies[defaults: .standard, key: .donationsCTAModalShouldForceShow] = false
        
        /// Show the modal after 1 second
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(1)) { [dependencies] in
            dependencies.notifyAsync(key: .showDonationsCTAModal)
        }
    }
    
    @MainActor public func positiveReviewChosen() {
        dependencies[defaults: .standard, key: .donationsCTAModalShouldForceShow] = true
        forceShowWasToggledThisSession = true
    }
    
    @MainActor public func openDonationsUrlModal(superPresenter: UIViewController? = nil) -> ConfirmationModal? {
        guard let url: URL = URL(string: Constants.session_donations_url) else { return nil }
        
        return ConfirmationModal(
            info: ConfirmationModal.Info(
                title: "urlOpen".localized(),
                body: .attributedText(
                    "urlOpenDescription"
                        .put(key: "url", value: url.absoluteString)
                        .localizedFormatted(baseFont: .systemFont(ofSize: Values.smallFontSize))
                ),
                confirmTitle: "open".localized(),
                confirmStyle: .danger,
                cancelTitle: "urlCopy".localized(),
                cancelStyle: .alert_text,
                hasCloseButton: true,
                dismissType: .single,
                onConfirm: { [dependencies] modal in
                    UIApplication.shared.open(url, options: [:], completionHandler: nil)
                    (superPresenter ?? modal).dismiss(animated: true)
                    
                    /// Increment the open counter
                    dependencies[defaults: .standard, key: .donationsUrlOpenCount] += 1
                },
                onCancel: { [dependencies] modal in
                    UIPasteboard.general.string = url.absoluteString
                    (superPresenter ?? modal).dismiss(animated: true)
                    
                    /// Increment the copy counter
                    dependencies[defaults: .standard, key: .donationsUrlCopyCount] += 1
                }
            )
        )
    }
    
    @MainActor public func presentDonationsCTAModal(in presenter: UIViewController) {
        let sessionProModal: ModalHostingViewController = ModalHostingViewController(
            modal: DonationCTAModal(
                dataManager: dependencies[singleton: .imageDataManager],
                dismissType: .single,
                donatePressed: { [weak self, weak presenter] in
                    guard let modal: ConfirmationModal = self?.openDonationsUrlModal(superPresenter: presenter) else {
                        return
                    }
                    
                    presenter?.presentedViewController?.present(modal, animated: true)
                }
            )
        )
        
        presenter.present(sessionProModal, animated: true)
        
        /// Increment the appearance counter and set the last appearance timestamp
        dependencies[defaults: .standard, key: .donationsCTAModalAppearanceCount] += 1
        dependencies[defaults: .standard, key: .donationsCTAModalLastAppearanceTimestamp] = dependencies.dateNow.timeIntervalSince1970
    }
    
    public func cachedState() -> [String: Any] {
        return [
            UserDefaults.BoolKey.donationsCTAModalShouldForceShow.rawValue: dependencies[defaults: .standard, key: .donationsCTAModalShouldForceShow],
            UserDefaults.DoubleKey.donationsCTAModalLastAppearanceTimestamp.rawValue: dependencies[defaults: .standard, key: .donationsCTAModalLastAppearanceTimestamp],
            UserDefaults.IntKey.donationsUrlOpenCount.rawValue: dependencies[defaults: .standard, key: .donationsUrlOpenCount],
            UserDefaults.IntKey.donationsUrlCopyCount.rawValue: dependencies[defaults: .standard, key: .donationsUrlCopyCount],
            UserDefaults.IntKey.donationsCTAModalAppearanceCount.rawValue: dependencies[defaults: .standard, key: .donationsCTAModalAppearanceCount]
        ]
    }
    
    public func restoreState(_ state: [String: Any]) {
        if let value: Bool = state[UserDefaults.BoolKey.donationsCTAModalShouldForceShow.rawValue] as? Bool {
            dependencies[defaults: .standard, key: .donationsCTAModalShouldForceShow] = value
        }
        
        if let value: Double = state[UserDefaults.DoubleKey.donationsCTAModalLastAppearanceTimestamp.rawValue] as? Double {
            dependencies[defaults: .standard, key: .donationsCTAModalLastAppearanceTimestamp] = value
        }
        
        if let value: Int = state[UserDefaults.IntKey.donationsUrlOpenCount.rawValue] as? Int {
            dependencies[defaults: .standard, key: .donationsUrlOpenCount] = value
        }
        
        if let value: Int = state[UserDefaults.IntKey.donationsUrlCopyCount.rawValue] as? Int {
            dependencies[defaults: .standard, key: .donationsUrlCopyCount] = value
        }
        
        if let value: Int = state[UserDefaults.IntKey.donationsCTAModalAppearanceCount.rawValue] as? Int {
            dependencies[defaults: .standard, key: .donationsCTAModalAppearanceCount] = value
        }
    }
    
    // MARK: - Internal Functions
    
    @objc func applicationWillEnterForeground(_ notification: Notification) {
        /// When we are about to enter the foreground we can reset the `forceShowWasToggledThisSession` flag which will
        /// result in the CTA modal appearing the next time the conversation list is seen if `donationsCTAModalShouldForceShow`
        /// is set to true
        DispatchQueue.main.async { [weak self, dependencies] in
            self?.forceShowWasToggledThisSession = false
            
            /// If the front-most view controller is the conversation list then it won't actually trigger `conversationListDidAppear`
            /// (because it's already visible) so we need to do so manually
            if dependencies[singleton: .appContext].frontMostViewController is HomeVC {
                self?.conversationListDidAppear()
            }
        }
    }
}

// MARK: - UserDefaults

// stringlint:disable_contents
public extension UserDefaults.BoolKey {
    static let donationsCTAModalShouldForceShow: UserDefaults.BoolKey = "donationsCTAModalShouldForceShow"
}

// stringlint:disable_contents
public extension UserDefaults.DoubleKey {
    static let donationsCTAModalLastAppearanceTimestamp: UserDefaults.DoubleKey = "donationsCTAModalLastAppearanceTimestamp"
}

// stringlint:disable_contents
public extension UserDefaults.IntKey {
    static let donationsUrlOpenCount: UserDefaults.IntKey = "donationsUrlOpenCount"
    static let donationsUrlCopyCount: UserDefaults.IntKey = "donationsUrlCopyCount"
    static let donationsCTAModalAppearanceCount: UserDefaults.IntKey = "donationsCTAModalAppearanceCount"
}

// MARK: - ObservableKey

// stringlint:disable_contents
public extension ObservableKey {
    static let showDonationsCTAModal: ObservableKey = ObservableKey("showDonationsCTAModal", .showDonationsCTAModal)
}

// stringlint:disable_contents
public extension GenericObservableKey {
    static let showDonationsCTAModal: GenericObservableKey = "showDonationsCTAModal"
}
