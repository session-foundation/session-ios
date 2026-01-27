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
        
        return result
    }()
    
    private lazy var clearDataButton: UIButton = {
        let result: UIButton = Modal.createButton(
            title: "clear".localized(),
            titleColor: .danger
        )
        result.addTarget(self, action: #selector(clearAllData), for: UIControl.Event.touchUpInside)
        
        return result
    }()
    
    private lazy var buttonStackView: UIStackView = {
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
                                    .put(key: "app_pro", value: Constants.app_pro)
                                    .put(key: "pro", value: Constants.pro)
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
                                .put(key: "app_pro", value: Constants.app_pro)
                                .put(key: "pro", value: Constants.pro)
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
        
        ModalActivityIndicatorViewController
            .present(fromViewController: presentedViewController, canCancel: false) { [weak self, dependencies] _ in
                dependencies[singleton: .storage]
                    .readPublisher { db -> [AuthenticationMethod] in
                        try OpenGroup
                            .select(.server)
                            .distinct()
                            .asRequest(of: String.self)
                            .fetchSet(db)
                            .map { try Authentication.with(db, server: $0, using: dependencies) }
                    }
                    .subscribe(on: DispatchQueue.global(qos: .userInitiated), using: dependencies)
                    .tryFlatMap { communityAuth -> AnyPublisher<(AuthenticationMethod, [String]), Error> in
                        let userAuth: AuthenticationMethod = try Authentication.with(
                            swarmPublicKey: dependencies[cache: .general].sessionId.hexString,
                            using: dependencies
                        )
                        
                        return Publishers
                            .MergeMany(
                                try communityAuth.compactMap { authMethod in
                                    switch authMethod.info {
                                        case .community(let server, _, _, _, _):
                                            return try Network.SOGS.preparedClearInbox(
                                                requestAndPathBuildTimeout: Network.defaultTimeout,
                                                authMethod: authMethod,
                                                using: dependencies
                                            )
                                            .map { _, _ in server }
                                            .send(using: dependencies)
                                            
                                        default: return nil
                                    }
                                }
                            )
                            .collect()
                            .map { response in (userAuth, response.map { $0.1 }) }
                            .eraseToAnyPublisher()
                    }
                    .tryFlatMap { authMethod, clearedServers in
                        try Network.SnodeAPI
                            .preparedDeleteAllMessages(
                                namespace: .all,
                                requestAndPathBuildTimeout: Network.defaultTimeout,
                                authMethod: authMethod,
                                using: dependencies
                            )
                            .send(using: dependencies)
                            .map { _, data in
                                clearedServers.reduce(into: data) { result, next in result[next] = true }
                            }
                    }
                    .receive(on: DispatchQueue.main, using: dependencies)
                    .sinkUntilComplete(
                        receiveCompletion: { result in
                            switch result {
                                case .finished: break
                                case .failure:
                                    self?.dismiss(animated: true, completion: nil) // Dismiss the loader
                                
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
                        },
                        receiveValue: { confirmations in
                            self?.dismiss(animated: true, completion: nil) // Dismiss the loader

                            // Get a list of nodes which failed to delete the data
                            let potentiallyMaliciousSnodes = confirmations
                                .compactMap { ($0.value == false ? $0.key : nil) }
                            
                            // If all of the nodes successfully deleted the data then proceed
                            // to delete the local data
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
                    )
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
                
                if let deviceToken: String = maybeDeviceToken, dependencies[singleton: .storage].hasValidDatabaseConnection {
                    Network.PushNotification
                        .unsubscribeAll(token: Data(hex: deviceToken), using: dependencies)
                        .sinkUntilComplete()
                }
            }
            
            /// Stop and cancel all current jobs (don't want to inadvertantly have a job store data after it's table has already been cleared)
            ///
            /// **Note:** This is file as long as this process kills the app, if it doesn't then we need an alternate mechanism to flag that
            /// the `JobRunner` is allowed to start it's queues again
            await dependencies[singleton: .jobRunner].stopAndClearJobs()
            
            // Clear the app badge and notifications
            dependencies[singleton: .notificationsManager].clearAllNotifications()
            await MainActor.run {
                UIApplication.shared.applicationIconBadgeNumber = 0
                
                // Stop any pollers
                (UIApplication.shared.delegate as? AppDelegate)?.stopPollers()
            }
            
            // Call through to the SessionApp's "resetAppData" which will wipe out logs, database and
            // profile storage
            let wasUnlinked: Bool = dependencies[defaults: .standard, key: .wasUnlinked]
            let serviceNetwork: ServiceNetwork = dependencies[feature: .serviceNetwork]
            let donationsState: [String: Any] = dependencies[singleton: .donationsManager].cachedState()
            
            dependencies[singleton: .app].resetData { [dependencies] in
                // Resetting the data clears the old user defaults. We need to restore the unlink default.
                dependencies[defaults: .standard, key: .wasUnlinked] = wasUnlinked
                
                // We want to maintain the state for the donations CTA modals so we don't spam the user if
                // they decide to create a new account
                dependencies[singleton: .donationsManager].restoreState(donationsState)
                
                // We also want to keep the `ServiceNetwork` setting (so someone testing can delete and restore
                // accounts on Testnet without issue
                dependencies.set(feature: .serviceNetwork, to: serviceNetwork)
            }
        }
    }
}
