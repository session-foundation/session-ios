// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import Combine
import GRDB
import SessionUIKit
import SessionSnodeKit
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
                body: .text("clearDeviceAndNetworkConfirm".localized()),
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
        ModalActivityIndicatorViewController.present(fromViewController: self, canCancel: false) { [weak self, dependencies] _ in
            ConfigurationSyncJob
                .run(swarmPublicKey: dependencies[cache: .general].sessionId.hexString, using: dependencies)
                .subscribe(on: DispatchQueue.global(qos: .userInitiated))
                .receive(on: DispatchQueue.main)
                .sinkUntilComplete(
                    receiveCompletion: { _ in
                        self?.deleteAllLocalData()
                        self?.dismiss(animated: true, completion: nil) // Dismiss the loader
                    }
                )
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
                    .readPublisher { db -> PreparedClearRequests in
                        (
                            try SnodeAPI.preparedDeleteAllMessages(
                                namespace: .all,
                                requestAndPathBuildTimeout: Network.defaultTimeout,
                                authMethod: try Authentication.with(
                                    db,
                                    swarmPublicKey: dependencies[cache: .general].sessionId.hexString,
                                    using: dependencies
                                ),
                                using: dependencies
                            ),
                            try OpenGroup
                                .filter(OpenGroup.Columns.isActive == true)
                                .select(.server)
                                .distinct()
                                .asRequest(of: String.self)
                                .fetchSet(db)
                                .map { server in
                                    try OpenGroupAPI
                                        .preparedClearInbox(
                                            db,
                                            on: server,
                                            requestAndPathBuildTimeout: Network.defaultTimeout,
                                            using: dependencies
                                        )
                                        .map { _, _ in server }
                                }
                        )
                    }
                    .subscribe(on: DispatchQueue.global(qos: .userInitiated), using: dependencies)
                    .flatMap { preparedRequests -> AnyPublisher<(Network.PreparedRequest<[String: Bool]>, [String]), Error> in
                        Publishers
                            .MergeMany(preparedRequests.inboxRequestInfo.map { $0.send(using: dependencies) })
                            .collect()
                            .map { response in (preparedRequests.deleteAll, response.map { $0.1 }) }
                            .eraseToAnyPublisher()
                    }
                    .flatMap { preparedDeleteAllRequest, clearedServers in
                        preparedDeleteAllRequest
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
                                self?.deleteAllLocalData()
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
    
    private func deleteAllLocalData() {
        /// Unregister push notifications if needed
        let isUsingFullAPNs: Bool = dependencies[defaults: .standard, key: .isUsingFullAPNs]
        let maybeDeviceToken: String? = dependencies[defaults: .standard, key: .deviceToken]
        
        if isUsingFullAPNs {
            UIApplication.shared.unregisterForRemoteNotifications()
            
            if let deviceToken: String = maybeDeviceToken {
                PushNotificationAPI
                    .unsubscribeAll(token: Data(hex: deviceToken), using: dependencies)
                    .sinkUntilComplete()
            }
        }
        
        /// Stop and cancel all current jobs (don't want to inadvertantly have a job store data after it's table has already been cleared)
        ///
        /// **Note:** This is file as long as this process kills the app, if it doesn't then we need an alternate mechanism to flag that
        /// the `JobRunner` is allowed to start it's queues again
        dependencies[singleton: .jobRunner].stopAndClearPendingJobs()
        
        // Clear the app badge and notifications
        dependencies[singleton: .notificationsManager].clearAllNotifications()
        UIApplication.shared.applicationIconBadgeNumber = 0
        
        // Clear out the user defaults
        UserDefaults.removeAll(using: dependencies)
        
        // Remove the general cache
        dependencies.remove(cache: .general)
        
        // Stop any pollers
        (UIApplication.shared.delegate as? AppDelegate)?.stopPollers()
        
        // Call through to the SessionApp's "resetAppData" which will wipe out logs, database and
        // profile storage
        let wasUnlinked: Bool = dependencies[defaults: .standard, key: .wasUnlinked]
        let serviceNetwork: ServiceNetwork = dependencies[feature: .serviceNetwork]
        
        dependencies[singleton: .app].resetData { [dependencies] in
            // Resetting the data clears the old user defaults. We need to restore the unlink default.
            dependencies[defaults: .standard, key: .wasUnlinked] = wasUnlinked
            
            // We also want to keep the `ServiceNetwork` setting (so someone testing can delete and restore
            // accounts on Testnet without issue
            dependencies.set(feature: .serviceNetwork, to: serviceNetwork)
        }
    }
}
