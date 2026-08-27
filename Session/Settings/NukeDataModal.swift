// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import Combine
import GRDB
import SessionUIKit
import SessionNetworkingKit
import SessionMessagingKit
import SignalUtilitiesKit
import SessionUtilitiesKit

final class NukeDataModal: Modal {
    /// Test identifiers for the first stage of the clear-data flow
    ///
    /// **Note:** The confirmation this modal presents is a `ConfirmationModal`, which already tags its own
    /// title, body and buttons - these cover only what this modal itself owns
    ///
    /// **Note:** Deliberately DISTINCT from the `Modal heading`/`Modal description` and title-derived button
    /// identifiers `ConfirmationModal` applies. The confirmation is presented OVER this modal rather than
    /// replacing it, so both are in the accessibility tree at once - sharing a name would have a locator
    /// match whichever came first, which is the one underneath
    // stringlint:ignore_contents
    enum AccessibilityIdentifier {
        static let heading: String = "clear-data-heading"
        static let description: String = "clear-data-description"
        static let confirmButton: String = "clear-data-confirm-button"
        static let cancelButton: String = "clear-data-cancel-button"
        static let clearDeviceOnlyRadio: String = "clear-device-only-radio"
        static let clearDeviceAndNetworkRadio: String = "clear-device-and-network-radio"
    }

    private let dependencies: Dependencies
    
    // MARK: - Initialization
    
    init(targetView: UIView? = nil, dismissType: DismissType = .recursive, using dependencies: Dependencies, afterClosed: (() -> ())? = nil) {
        self.dependencies = dependencies
        
        super.init(targetView: targetView, dismissType: dismissType, afterClosed: afterClosed)
        
        self.modalPresentationStyle = .overFullScreen
        self.modalTransitionStyle = .crossDissolve
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: - Components
    
    private lazy var titleLabel: UILabel = {
        let result = UILabel()
        result.font = .boldSystemFont(ofSize: Values.mediumFontSize)
        result.text = "clearDataAll".localized()
        result.isAccessibilityElement = true
        result.accessibilityIdentifier = AccessibilityIdentifier.heading
        result.accessibilityLabel = result.text
        result.themeTextColor = .textPrimary
        result.textAlignment = .center
        result.lineBreakMode = .byWordWrapping
        result.numberOfLines = 0
        
        return result
    }()
    
    private lazy var explanationLabel: UILabel = {
        let result = UILabel()
        result.font = .systemFont(ofSize: Values.smallFontSize)
        result.text = "clearDataAllDescription".localized()
        result.isAccessibilityElement = true
        result.accessibilityIdentifier = AccessibilityIdentifier.description
        result.accessibilityLabel = result.text
        result.themeTextColor = .textPrimary
        result.textAlignment = .center
        result.lineBreakMode = .byWordWrapping
        result.numberOfLines = 0
        
        return result
    }()
    
    private lazy var clearDeviceRadio: RadioButton = {
        let result: RadioButton = RadioButton(size: .small) { [weak self] radio in
            self?.clearNetworkRadio.update(isSelected: false)
            radio.update(isSelected: true)
        }
        result.font = .systemFont(ofSize: Values.smallFontSize)
        result.text = "clearDeviceOnly".localized()
        result.isAccessibilityElement = true
        result.accessibilityIdentifier = AccessibilityIdentifier.clearDeviceOnlyRadio
        result.accessibilityLabel = result.text
        result.update(isSelected: true)
        
        return result
    }()
    
    private lazy var clearNetworkRadio: RadioButton = {
        let result: RadioButton = RadioButton(size: .small) { [weak self] radio in
            self?.clearDeviceRadio.update(isSelected: false)
            radio.update(isSelected: true)
        }
        result.font = .systemFont(ofSize: Values.smallFontSize)
        result.text = "clearDeviceAndNetwork".localized()
        result.isAccessibilityElement = true
        result.accessibilityIdentifier = AccessibilityIdentifier.clearDeviceAndNetworkRadio
        result.accessibilityLabel = result.text
        
        return result
    }()
    
    private lazy var clearDataButton: UIButton = {
        let result: UIButton = Modal.createButton(
            title: "clear".localized(),
            titleColor: .danger
        )
        // Matches what `ConfirmationModal` derives from its own `confirmTitle`, so the same locator reads
        // the action on both stages of the flow
        result.accessibilityIdentifier = AccessibilityIdentifier.confirmButton
        result.addTarget(self, action: #selector(clearAllData), for: UIControl.Event.touchUpInside)
        
        return result
    }()
    
    private lazy var buttonStackView: UIStackView = {
        // The base `Modal` gives its cancel button no identifier; `ConfirmationModal` sets one from its
        // own `cancelTitle`, and this matches it
        cancelButton.accessibilityIdentifier = AccessibilityIdentifier.cancelButton
        let result = UIStackView(arrangedSubviews: [ clearDataButton, cancelButton ])
        result.axis = .horizontal
        result.distribution = .fillEqually
        
        return result
    }()
    
    private lazy var contentStackView: UIStackView = {
        let result = UIStackView(arrangedSubviews: [
            titleLabel,
            explanationLabel,
            clearDeviceRadio,
            UIView.separator(),
            clearNetworkRadio
        ])
        result.axis = .vertical
        result.spacing = Values.smallSpacing
        result.isLayoutMarginsRelativeArrangement = true
        result.layoutMargins = UIEdgeInsets(
            top: Values.largeSpacing,
            leading: Values.largeSpacing,
            bottom: Values.verySmallSpacing,
            trailing: Values.largeSpacing
        )
        
        return result
    }()
    
    private lazy var mainStackView: UIStackView = {
        let result = UIStackView(arrangedSubviews: [ contentStackView, buttonStackView ])
        result.axis = .vertical
        result.spacing = Values.largeSpacing - Values.smallFontSize / 2
        
        return result
    }()
    
    // MARK: - Lifecycle
    
    override func populateContentView() {
        contentView.addSubview(mainStackView)
        
        mainStackView.pin(to: contentView)
    }
    
    // MARK: - Interaction
    
    @objc private func clearAllData() {
        guard clearNetworkRadio.isSelected else {
            clearDeviceOnly()
            return
        }
        
        let confirmationModal: ConfirmationModal = ConfirmationModal(
            info: ConfirmationModal.Info(
                title: "clearDataAll".localized(),
                body: .attributedText(
                    {
                        switch dependencies[singleton: .sessionProManager].currentUserCurrentProState.status {
                            case .active:
                                "proClearAllDataNetwork"
                                    .localizedFormatted()
                            default:
                                "clearDeviceAndNetworkConfirm"
                                    .localizedFormatted(baseFont: Fonts.Body.baseRegular)
                        }
                    }(),
                    scrollMode: .never
                ),
                confirmTitle: "clear".localized(),
                confirmStyle: .danger,
                cancelStyle: .alert_text,
                dismissOnConfirm: false
            ) { [weak self] confirmationModal in
                self?.clearEntireAccount(presentedViewController: confirmationModal)
            }
        )
        present(confirmationModal, animated: true, completion: nil)
    }
    
    private func clearDeviceOnly() {
        switch dependencies[singleton: .sessionProManager].currentUserCurrentProState.status {
            case .active:
                let confirmationModal: ConfirmationModal = ConfirmationModal(
                    info: ConfirmationModal.Info(
                        title: "clearDataAll".localized(),
                        body: .attributedText(
                            "proClearAllDataDevice"
                                .localizedFormatted(),
                            scrollMode: .never
                        ),
                        confirmTitle: "clear".localized(),
                        confirmStyle: .danger,
                        cancelStyle: .alert_text,
                        dismissOnConfirm: false
                    ) { [weak self] confirmationModal in
                        self?.clearLocalAccount(presentedViewController: confirmationModal)
                    }
                )
                present(confirmationModal, animated: true, completion: nil)
            
            default: self.clearLocalAccount(presentedViewController: self)
        }
    }
    
    private func clearLocalAccount(presentedViewController presented: UIViewController) {
        ModalActivityIndicatorViewController.present(fromViewController: presented, canCancel: false) { [weak self, dependencies] _ in
            Task(priority: .userInitiated) { [weak self, dependencies] in
                try? await ConfigurationSyncJob.run(
                    swarmPublicKey: dependencies[cache: .general].sessionId.hexString,
                    using: dependencies
                )
                
                NukeDataModal.deleteAllLocalData(using: dependencies)
                self?.dismiss(animated: true, completion: nil) // Dismiss the loader
            }
        }
    }
    
    private func clearEntireAccount(presentedViewController: UIViewController) {
        typealias PreparedClearRequests = (
            deleteAll: Network.PreparedRequest<[String: Bool]>,
            inboxRequestInfo: [Network.PreparedRequest<String>]
        )
        
        Task(priority: .userInitiated) { [weak self, weak presentedViewController, dependencies] in
            let indicator: ModalActivityIndicatorViewController = await MainActor.run { [weak presentedViewController] in
                let indicator: ModalActivityIndicatorViewController = ModalActivityIndicatorViewController(canCancel: false)
                presentedViewController?.present(indicator, animated: false)
                
                return indicator
            }
            
            do {
                let communityAuth: [AuthenticationMethod] = try await dependencies[singleton: .storage].read { db in
                    try OpenGroup
                        .filter(OpenGroup.Columns.shouldPoll == true)
                        .select(.server)
                        .distinct()
                        .asRequest(of: String.self)
                        .fetchSet(db)
                        .map { try Authentication.with(db, server: $0, using: dependencies) }
                }
                
                /// Clear the inbox of any known communities in case the user had sent messages to them
                let clearedServers: [String] = try await withThrowingTaskGroup(of: String.self) { group in
                    for authMethod in communityAuth {
                        guard case .community(let server, _, _, _, _) = authMethod.info else { continue }
                        
                        group.addTask {
                            (_, _) = try await Network.SOGS
                                .preparedClearInbox(
                                    overallTimeout: Network.defaultTimeout,
                                    authMethod: authMethod,
                                    using: dependencies
                                )
                                .send(using: dependencies)
                            
                            return server
                        }
                    }
                        
                    var result: [String] = []
                    while !group.isEmpty {
                        guard let value: String = try await group.next() else {
                            throw NetworkError.invalidResponse
                        }
                        
                        result.append(value)
                    }
                    
                    return result
                }
                        
                /// Try to ensure we have synced the network time before sending (to reduce the chance that the request will fail
                /// due to the device clock being out of sync with the network)
                let swarm: Set<LibSession.Snode> = try await dependencies[singleton: .network]
                    .getSwarm(
                        for: dependencies[cache: .general].sessionId.hexString,
                        ignoreStrikeCount: false
                    )
                let snode: LibSession.Snode = try await SwarmDrainer(swarm: swarm, using: dependencies)
                    .selectNextNode()
                try await dependencies.networkOffsetTimestampSynced(timeout: .seconds(3))
                
                /// Clear the users swarm
                let userAuth: AuthenticationMethod = try Authentication.with(
                    swarmPublicKey: dependencies[cache: .general].sessionId.hexString,
                    using: dependencies
                )
                var confirmations: [String: Bool] = try await Network.StorageServer
                    .preparedDeleteAllMessages(
                        namespace: .all,
                        snode: snode,
                        overallTimeout: Network.defaultTimeout,
                        authMethod: userAuth,
                        using: dependencies
                    )
                    .send(using: dependencies)
                        
                /// Add the cleared Community servers so we have a full list
                clearedServers.forEach { confirmations[$0] = true }
                
                await MainActor.run { [weak indicator] in
                    indicator?.dismiss(animated: true, completion: nil) /// Dismiss the loader

                    /// Get a list of nodes which failed to delete the data
                    let potentiallyMaliciousSnodes = confirmations
                        .compactMap { ($0.value == false ? $0.key : nil) }
                    
                    /// If all of the nodes successfully deleted the data then proceed to delete the local data
                    guard !potentiallyMaliciousSnodes.isEmpty else {
                        NukeDataModal.deleteAllLocalData(using: dependencies)
                        return
                    }

                    let modal: ConfirmationModal = ConfirmationModal(
                        targetView: self?.view,
                        info: ConfirmationModal.Info(
                            title: "clearDataAll".localized(),
                            body: .text("clearDataErrorDescriptionGeneric".localized()),
                            confirmTitle: "clearDevice".localized(),
                            confirmStyle: .danger,
                            cancelStyle: .alert_text
                        ) { [weak self] _ in
                            self?.clearDeviceOnly()
                        }
                    )
                    self?.present(modal, animated: true)
                }
            }
            catch {
                await MainActor.run { [weak indicator] in
                    indicator?.dismiss(animated: true, completion: nil) /// Dismiss the loader
                    
                    let modal: ConfirmationModal = ConfirmationModal(
                        targetView: self?.view,
                        info: ConfirmationModal.Info(
                            title: "clearDataAll".localized(),
                            body: .text("clearDataErrorDescriptionGeneric".localized()),
                            confirmTitle: "clearDevice".localized(),
                            confirmStyle: .danger,
                            cancelStyle: .alert_text
                        ) { [weak self] _ in
                            self?.clearDeviceOnly()
                        }
                    )
                    self?.present(modal, animated: true)
                }
            }
        }
    }
    
    public static func deleteAllLocalData(using dependencies: Dependencies) {
        Log.info("Starting local data deletion.")
        
        Task.detached(priority: .userInitiated) {
            /// Unregister push notifications if needed
            let isUsingFullAPNs: Bool = dependencies[defaults: .standard, key: .isUsingFullAPNs]
            let maybeDeviceToken: String? = dependencies[defaults: .standard, key: .deviceToken]
            
            if isUsingFullAPNs {
                await UIApplication.shared.unregisterForRemoteNotifications()
                
                if let deviceToken: String = maybeDeviceToken, dependencies[singleton: .storage].syncState.hasValidDatabaseConnection {
                    Task.detached(priority: .userInitiated) {
                        try? await Network.PushNotification.unsubscribeAll(
                            token: Data(hex: deviceToken),
                            using: dependencies
                        )
                    }
                }
            }
            
            /// Stop the pollers
            await (UIApplication.shared.delegate as? AppDelegate)?.stopPollers()
            
            /// Stop and cancel all current jobs (don't want to inadvertantly have a job store data after it's table has already been cleared)
            ///
            /// **Note:** This is file as long as this process kills the app, if it doesn't then we need an alternate mechanism to flag that
            /// the `JobRunner` is allowed to start it's queues again
            await dependencies[singleton: .jobRunner].stopAndClearJobs()
            
            /// Clear the app badge and notifications
            dependencies[singleton: .notificationsManager].clearAllNotifications()
            await MainActor.run { UIApplication.shared.applicationIconBadgeNumber = 0 }
            
            /// Call through to the SessionApp's `resetAppData` which will wipe out logs, database and profile storage
            let wasUnlinked: Bool = dependencies[defaults: .standard, key: .wasUnlinked]
            let serviceNetwork: ServiceNetwork = dependencies[feature: .serviceNetwork]
            let donationsState: [String: Any] = dependencies[singleton: .donationsManager].cachedState()
            
            await dependencies[singleton: .app].resetData { [dependencies] in
                /// Resetting the data clears the old user defaults. We need to restore the unlink default.
                dependencies[defaults: .standard, key: .wasUnlinked] = wasUnlinked
                
                /// We want to maintain the state for the donations CTA modals so we don't spam the user if they decide to create
                /// a new account
                dependencies[singleton: .donationsManager].restoreState(donationsState)
                
                /// We also want to keep the `ServiceNetwork` setting (so someone testing can delete and restore accounts
                /// on `Testnet` without issue
                dependencies.set(feature: .serviceNetwork, to: serviceNetwork)
            }
        }
    }
}
