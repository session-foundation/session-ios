// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import Combine
import GRDB
import DifferenceKit
import SessionUIKit
import SessionNetworkingKit
import SessionMessagingKit
import SessionUtilitiesKit

class DeveloperSettingsNetworkViewModel: SessionTableViewModel, NavigatableStateHolder, ObservableTableSource {
    public let dependencies: Dependencies
    public let navigatableState: NavigatableState = NavigatableState()
    public let state: TableDataState<Section, TableItem> = TableDataState()
    public let observableState: ObservableTableSourceState<Section, TableItem> = ObservableTableSourceState()
    
    private var updatedDevnetPubkey: String?
    private var updatedDevnetIp: String?
    private var updatedDevnetHttpPort: String?
    private var updatedDevnetOmqPort: String?
    
    /// This value is the current state of the view
    @MainActor @Published private(set) var internalState: State
    private var observationTask: Task<Void, Never>?
    
    // MARK: - Initialization
    
    @MainActor init(using dependencies: Dependencies) {
        self.dependencies = dependencies
        self.internalState = State.initialState(using: dependencies)
        
        /// Bind the state
        self.observationTask = ObservationBuilder
            .initialValue(self.internalState)
            .debounce(for: .never)
            .using(dependencies: dependencies)
            .query(DeveloperSettingsNetworkViewModel.queryState)
            .assign { [weak self] updatedState in
                guard let self = self else { return }
                
                // FIXME: To slightly reduce the size of the changes this new observation mechanism is currently wired into the old SessionTableViewController observation mechanism, we should refactor it so everything uses the new mechanism
                let oldState: State = self.internalState
                self.internalState = updatedState
                self.pendingTableDataSubject.send(updatedState.sections(viewModel: self, previousState: oldState))
            }
    }
    
    // MARK: - Config
    
    public enum Section: SessionTableSection {
        case general
        case devnetConfig
        
        var title: String? {
            switch self {
                case .general: return nil
                case .devnetConfig: return "Devnet Configuration"
            }
        }
        
        var style: SessionTableSectionStyle {
            switch self {
                case .general: return .padding
                default: return .titleRoundedContent
            }
        }
    }
    
    public enum TableItem: Hashable, Differentiable, CaseIterable {
        case environment
        case router
        case pushNotificationService
        case forceOffline
        
        case devnetPubkey
        case devnetIp
        case devnetHttpPort
        case devnetOmqPort
        
        // MARK: - Conformance
        
        public typealias DifferenceIdentifier = String
        
        public var differenceIdentifier: String {
            switch self {
                case .environment: return "environment"
                case .router: return "router"
                case .pushNotificationService: return "pushNotificationService"
                case .forceOffline: return "forceOffline"
                    
                case .devnetPubkey: return "devnetPubkey"
                case .devnetIp: return "devnetIp"
                case .devnetHttpPort: return "devnetHttpPort"
                case .devnetOmqPort: return "devnetOmqPort"
            }
        }
        
        public func isContentEqual(to source: TableItem) -> Bool {
            self.differenceIdentifier == source.differenceIdentifier
        }
        
        public static var allCases: [TableItem] {
            var result: [TableItem] = []
            switch TableItem.environment {
                case .environment: result.append(.environment); fallthrough
                case .router: result.append(.router); fallthrough
                case .pushNotificationService: result.append(.pushNotificationService); fallthrough
                case .forceOffline: result.append(.forceOffline); fallthrough
                    
                case .devnetPubkey: result.append(.devnetPubkey); fallthrough
                case .devnetIp: result.append(.devnetIp); fallthrough
                case .devnetHttpPort: result.append(.devnetHttpPort); fallthrough
                case .devnetOmqPort: result.append(.devnetOmqPort)
            }
            
            return result
        }
    }
    
    // MARK: - Content
    
    public struct State: Equatable, ObservableKeyProvider {
        struct NetworkState: Equatable, Hashable {
            let environment: ServiceNetwork
            let router: Router
            let pushNotificationService: Network.PushNotification.Service
            let forceOffline: Bool
            
            let devnetConfig: ServiceNetwork.DevnetConfiguration
            
            public func with(
                environment: ServiceNetwork? = nil,
                router: Router? = nil,
                pushNotificationService: Network.PushNotification.Service? = nil,
                forceOffline: Bool? = nil,
                devnetConfig: ServiceNetwork.DevnetConfiguration? = nil
            ) -> NetworkState {
                return NetworkState(
                    environment: (environment ?? self.environment),
                    router: (router ?? self.router),
                    pushNotificationService: (pushNotificationService ?? self.pushNotificationService),
                    forceOffline: (forceOffline ?? self.forceOffline),
                    devnetConfig: (devnetConfig ?? self.devnetConfig)
                )
            }
        }
        
        let initialState: NetworkState
        let pendingState: NetworkState
        
        @MainActor public func sections(viewModel: DeveloperSettingsNetworkViewModel, previousState: State) -> [SectionModel] {
            DeveloperSettingsNetworkViewModel.sections(
                state: self,
                previousState: previousState,
                viewModel: viewModel
            )
        }
        
        public let observedKeys: Set<ObservableKey> = [
            .updateScreen(DeveloperSettingsNetworkViewModel.self)
        ]
        
        static func initialState(using dependencies: Dependencies) -> State {
            let initialState: NetworkState = NetworkState(
                environment: dependencies[feature: .serviceNetwork],
                router: dependencies[feature: .router],
                pushNotificationService: dependencies[feature: .pushNotificationService],
                forceOffline: dependencies[feature: .forceOffline],
                devnetConfig: dependencies[feature: .devnetConfig]
            )
            
            return State(
                initialState: initialState,
                pendingState: initialState
            )
        }
    }
    
    let title: String = "Developer Network Settings"
    
    lazy var footerButtonInfo: AnyPublisher<SessionButton.Info?, Never> = $internalState
        .map { [weak self] state -> SessionButton.Info? in
            return SessionButton.Info(
                style: .bordered,
                title: "set".localized(),
                isEnabled: {
                    guard state.initialState != state.pendingState else { return false }
                    
                    switch (state.pendingState.environment, state.pendingState.router) {
                        case (.devnet, _): return state.pendingState.devnetConfig.isValid
                        case (.testnet, .lokinet): return true
                        case (_, .lokinet): return false
                        default: return true
                    }
                }(),
                accessibility: Accessibility(
                    identifier: "Set button",
                    label: "Set button"
                ),
                minWidth: 110,
                onTap: { [weak self] in
                    Task { [weak self] in
                        await self?.saveChanges()
                    }
                }
            )
        }
        .eraseToAnyPublisher()
    
    @Sendable private static func queryState(
        previousState: State,
        events: [ObservedEvent],
        isInitialQuery: Bool,
        using dependencies: Dependencies
    ) async -> State {
        return State(
            initialState: previousState.initialState,
            pendingState: (events.first?.value as? State.NetworkState ?? previousState.pendingState)
        )
    }
    
    private static func sections(
        state: State,
        previousState: State,
        viewModel: DeveloperSettingsNetworkViewModel
    ) -> [SectionModel] {
        let general: SectionModel = SectionModel(
            model: .general,
            elements: [
                SessionCell.Info(
                    id: .environment,
                    title: "Environment",
                    subtitle: """
                    The environment used for sending requests and storing messages.
                    
                    <b>Current:</b> <span>\(state.pendingState.environment.title)</span>
                    """,
                    trailingAccessory: .icon(.squarePen),
                    onTap: { [weak viewModel] in
                        viewModel?.showEnvironmentModal(pendingState: state.pendingState)
                    }
                ),
                SessionCell.Info(
                    id: .router,
                    title: "Router",
                    subtitle: """
                    The routing method which should be used when making network requests.
                    
                    The Lokinet option only works on Testnet.
                    
                    <b>Current:</b> <span>\(state.pendingState.router.title)</span>
                    """,
                    trailingAccessory: .icon(.squarePen),
                    onTap: { [weak viewModel] in
                        viewModel?.showRoutingModal(pendingState: state.pendingState)
                    }
                ),
                SessionCell.Info(
                    id: .pushNotificationService,
                    title: "Push Notification Service",
                    subtitle: """
                    The service used for subscribing for push notifications.
                    
                    The production service only works for production builds and neither option works in the Simulator.

                    <b>Current:</b> <span>\(state.pendingState.pushNotificationService.title)</span>
                    """,
                    trailingAccessory: .icon(.squarePen),
                    onTap: { [weak viewModel] in
                        viewModel?.showPushServiceModal(pendingState: state.pendingState)
                    }
                ),
                SessionCell.Info(
                    id: .forceOffline,
                    title: "Force Offline",
                    subtitle: """
                    Shut down the current network and cause all future network requests to fail after a 1 second delay with a 'serviceUnavailable' error.
                    """,
                    trailingAccessory: .toggle(
                        state.pendingState.forceOffline,
                        oldValue: previousState.pendingState.forceOffline
                    ),
                    onTap: { [dependencies = viewModel.dependencies] in
                        dependencies.notifyAsync(
                            priority: .immediate,
                            key: .updateScreen(DeveloperSettingsNetworkViewModel.self),
                            value: state.pendingState.with(forceOffline: !state.pendingState.forceOffline)
                        )
                    }
                )
            ]
        )
        
        /// Only show the `devnetConfig` section if the environment is set to `devnet`
        guard state.pendingState.environment == .devnet else {
            return [general]
        }
        
        let devnetConfig: SectionModel = SectionModel(
            model: .devnetConfig,
            elements: [
                SessionCell.Info(
                    id: .devnetPubkey,
                    title: "Public Key",
                    subtitle: """
                    The public key for the devnet seed node.
                    
                    <b>Current Value:</b> <span>\(state.pendingState.devnetConfig.pubkey.isEmpty ? "None" : state.pendingState.devnetConfig.pubkey)</span>
                    """,
                    trailingAccessory: .icon(.squarePen),
                    onTap: { [weak viewModel] in
                        viewModel?.showDevnetPubkeyModal(pendingState: state.pendingState)
                    }
                ),
                SessionCell.Info(
                    id: .devnetIp,
                    title: "IP Address",
                    subtitle: """
                    The IP address for the devnet seed node.
                    
                    <b>Current Value:</b> <span>\(state.pendingState.devnetConfig.ip.isEmpty ? "None" : state.pendingState.devnetConfig.ip)</span>
                    """,
                    trailingAccessory: .icon(.squarePen),
                    onTap: { [weak viewModel] in
                        viewModel?.showDevnetIpModal(pendingState: state.pendingState)
                    }
                ),
                SessionCell.Info(
                    id: .devnetIp,
                    title: "HTTP Port",
                    subtitle: """
                    The HTTP port for the devnet seed node.
                    
                    <b>Current Value:</b> <span>\(state.pendingState.devnetConfig.httpPort)</span>
                    """,
                    trailingAccessory: .icon(.squarePen),
                    onTap: { [weak viewModel] in
                        viewModel?.showDevnetHttpPortModal(pendingState: state.pendingState)
                    }
                ),
                SessionCell.Info(
                    id: .devnetIp,
                    title: "QUIC Port",
                    subtitle: """
                    The QUIC port for the devnet seed node.
                    
                    <b>Current Value:</b> <span>\(state.pendingState.devnetConfig.omqPort)</span>
                    """,
                    trailingAccessory: .icon(.squarePen),
                    onTap: { [weak viewModel] in
                        viewModel?.showDevnetOmqPortModal(pendingState: state.pendingState)
                    }
                )
            ]
        )
        
        return [general, devnetConfig]
    }
    
    // MARK: - Internal Functions
    
    private func showEnvironmentModal(pendingState: State.NetworkState) {
        self.transitionToScreen(
            ConfirmationModal(
                info: ConfirmationModal.Info(
                    title: "Environment",
                    body: .radio(
                        explanation: ThemedAttributedString(
                            string: "The environment used for sending requests and storing messages."
                        ),
                        warning: nil,
                        options: ServiceNetwork.allCases.map { network in
                            ConfirmationModal.Info.Body.RadioOptionInfo(
                                title: network.title,
                                descriptionText: network.subtitle.map { ThemedAttributedString(string: $0) },
                                enabled: true,
                                selected: pendingState.environment == network
                            )
                        }
                    ),
                    confirmTitle: "select".localized(),
                    cancelStyle: .alert_text,
                    onConfirm: { [dependencies] modal in
                        let selected: ServiceNetwork = {
                            switch modal.info.body {
                                case .radio(_, _, let options):
                                    return options
                                        .enumerated()
                                        .first(where: { _, value in value.selected })
                                        .map { index, _ in
                                            guard index < ServiceNetwork.allCases.count else {
                                                return nil
                                            }
                                            
                                            return ServiceNetwork.allCases[index]
                                        }
                                        .defaulting(to: .mainnet)
                                
                                default: return .mainnet
                            }
                        }()
                        
                        dependencies.notifyAsync(
                            priority: .immediate,
                            key: .updateScreen(DeveloperSettingsNetworkViewModel.self),
                            value: pendingState.with(environment: selected)
                        )
                    }
                )
            ),
            transitionType: .present
        )
    }
    
    private func showRoutingModal(pendingState: State.NetworkState) {
        self.transitionToScreen(
            ConfirmationModal(
                info: ConfirmationModal.Info(
                    title: "Router",
                    body: .radio(
                        explanation: ThemedAttributedString(
                            string: "The routing method which should be used when making network requests."
                        ),
                        warning: nil,
                        options: Router.allCases.map { router in
                            ConfirmationModal.Info.Body.RadioOptionInfo(
                                title: router.title,
                                descriptionText: router.subtitle.map { ThemedAttributedString(string: $0) },
                                enabled: true,
                                selected: pendingState.router == router
                            )
                        }
                    ),
                    confirmTitle: "select".localized(),
                    cancelStyle: .alert_text,
                    onConfirm: { [dependencies] modal in
                        let selected: Router = {
                            switch modal.info.body {
                                case .radio(_, _, let options):
                                    return options
                                        .enumerated()
                                        .first(where: { _, value in value.selected })
                                        .map { index, _ in
                                            guard index < Router.allCases.count else {
                                                return nil
                                            }
                                            
                                            return Router.allCases[index]
                                        }
                                        .defaulting(to: .onionRequests)
                                
                                default: return .onionRequests
                            }
                        }()
                        
                        dependencies.notifyAsync(
                            priority: .immediate,
                            key: .updateScreen(DeveloperSettingsNetworkViewModel.self),
                            value: pendingState.with(router: selected)
                        )
                    }
                )
            ),
            transitionType: .present
        )
    }
    
    private func showPushServiceModal(pendingState: State.NetworkState) {
        self.transitionToScreen(
            ConfirmationModal(
                info: ConfirmationModal.Info(
                    title: "Push Notification Service",
                    body: .radio(
                        explanation: ThemedAttributedString(
                            string: "The service used for subscribing for push notifications."
                        ),
                        warning: ThemedAttributedString(
                            string: "The production service only works for production builds and neither option works in the Simulator."
                        ),
                        options: Network.PushNotification.Service.allCases.map { network in
                            ConfirmationModal.Info.Body.RadioOptionInfo(
                                title: network.title,
                                enabled: true,
                                selected: pendingState.pushNotificationService == network
                            )
                        }
                    ),
                    confirmTitle: "select".localized(),
                    cancelStyle: .alert_text,
                    onConfirm: { [dependencies] modal in
                        let selected: Network.PushNotification.Service = {
                            switch modal.info.body {
                                case .radio(_, _, let options):
                                    return options
                                        .enumerated()
                                        .first(where: { _, value in value.selected })
                                        .map { index, _ in
                                            guard index < Network.PushNotification.Service.allCases.count else {
                                                return nil
                                            }
                                            
                                            return Network.PushNotification.Service.allCases[index]
                                        }
                                        .defaulting(to: .apns)
                                
                                default: return .apns
                            }
                        }()
                        
                        dependencies.notifyAsync(
                            priority: .immediate,
                            key: .updateScreen(DeveloperSettingsNetworkViewModel.self),
                            value: pendingState.with(pushNotificationService: selected)
                        )
                    }
                )
            ),
            transitionType: .present
        )
    }
    
    private func showDevnetPubkeyModal(pendingState: State.NetworkState) {
        self.transitionToScreen(
            ConfirmationModal(
                info: ConfirmationModal.Info(
                    title: "Devnet Pubkey",
                    body: .input(
                        explanation: ThemedAttributedString(
                            string: """
                            The public key for the devnet seed node.
                            
                            This is 64 character hexadecimal value.
                            """
                        ),
                        info: ConfirmationModal.Info.Body.InputInfo(
                            placeholder: "Enter Pubkey",
                            initialValue: pendingState.devnetConfig.pubkey,
                            inputChecker: { text in
                                guard text.count <= 64 else {
                                    return "Value must be a 64 character hexadecimal string."
                                }
                                
                                return nil
                            }
                        ),
                        onChange: { [weak self] value in
                            self?.updatedDevnetPubkey = value
                        }
                    ),
                    confirmTitle: "save".localized(),
                    confirmEnabled: .afterChange { [weak self] _ in
                        guard let value: String = self?.updatedDevnetPubkey else {
                            return false
                        }
                        
                        return (
                            Hex.isValid(value) &&
                            value.trimmingCharacters(in: .whitespacesAndNewlines).count == 64
                        )
                    },
                    cancelStyle: .alert_text,
                    dismissOnConfirm: false,
                    onConfirm: { [weak self, dependencies] modal in
                        guard
                            let value: String = self?.updatedDevnetPubkey,
                            Hex.isValid(value),
                            value.trimmingCharacters(in: .whitespacesAndNewlines).count == 64
                        else {
                            modal.updateContent(
                                withError: "Value must be a 64 character hexadecimal string."
                            )
                            return
                        }
                        
                        modal.dismiss(animated: true)
                        dependencies.notifyAsync(
                            priority: .immediate,
                            key: .updateScreen(DeveloperSettingsNetworkViewModel.self),
                            value: pendingState.with(
                                devnetConfig: pendingState.devnetConfig.with(
                                    pubkey: value
                                )
                            )
                        )
                    }
                )
            ),
            transitionType: .present
        )
    }
    
    private func showDevnetIpModal(pendingState: State.NetworkState) {
        self.transitionToScreen(
            ConfirmationModal(
                info: ConfirmationModal.Info(
                    title: "Devnet IP",
                    body: .input(
                        explanation: ThemedAttributedString(
                            string: """
                            The IP address for the devnet seed node.
                            
                            This must be in the format: '255.255.255.255'
                            """
                        ),
                        info: ConfirmationModal.Info.Body.InputInfo(
                            placeholder: "Enter IP",
                            initialValue: pendingState.devnetConfig.ip
                        ),
                        onChange: { [weak self] value in self?.updatedDevnetIp = value }
                    ),
                    confirmTitle: "save".localized(),
                    confirmEnabled: .afterChange { [weak self] _ in
                        guard let value: String = self?.updatedDevnetIp else {
                            return false
                        }
                        
                        return (
                            value.split(separator: ".").count == 4 &&
                            value.split(separator: ".").allSatisfy({ part in
                                UInt8(part, radix: 10) != nil
                            })
                        )
                    },
                    cancelStyle: .alert_text,
                    dismissOnConfirm: false,
                    onConfirm: { [weak self, dependencies] modal in
                        guard
                            let value: String = self?.updatedDevnetIp,
                            value.split(separator: ".").count == 4,
                            value.split(separator: ".").allSatisfy({ part in
                                UInt8(part, radix: 10) != nil
                            })
                        else {
                            modal.updateContent(
                                withError: "Value must be a valid IP address in the format: '255.255.255.255'."
                            )
                            return
                        }
                        
                        modal.dismiss(animated: true)
                        dependencies.notifyAsync(
                            priority: .immediate,
                            key: .updateScreen(DeveloperSettingsNetworkViewModel.self),
                            value: pendingState.with(
                                devnetConfig: pendingState.devnetConfig.with(
                                    ip: value
                                )
                            )
                        )
                    }
                )
            ),
            transitionType: .present
        )
    }
    
    private func showDevnetHttpPortModal(pendingState: State.NetworkState) {
        self.transitionToScreen(
            ConfirmationModal(
                info: ConfirmationModal.Info(
                    title: "Devnet HTTP Port",
                    body: .input(
                        explanation: ThemedAttributedString(
                            string: """
                            The HTTP port for the devnet seed node.
                            
                            Value must be a number between 0 and 65,535.
                            """
                        ),
                        info: ConfirmationModal.Info.Body.InputInfo(
                            placeholder: "Enter HTTP port",
                            initialValue: "\(pendingState.devnetConfig.httpPort)"
                        ),
                        onChange: { [weak self] value in self?.updatedDevnetHttpPort = value }
                    ),
                    confirmTitle: "save".localized(),
                    confirmEnabled: .afterChange { [weak self] _ in
                        guard let value: String = self?.updatedDevnetHttpPort else {
                            return false
                        }
                        
                        return (UInt16(value, radix: 10) != nil)
                    },
                    cancelStyle: .alert_text,
                    dismissOnConfirm: false,
                    onConfirm: { [weak self, dependencies] modal in
                        guard
                            let value: String = self?.updatedDevnetHttpPort,
                            let httpPort: UInt16 = UInt16(value, radix: 10)
                        else {
                            modal.updateContent(
                                withError: "Value must be a number between 0 and 65,535."
                            )
                            return
                        }
                        
                        modal.dismiss(animated: true)
                        dependencies.notifyAsync(
                            priority: .immediate,
                            key: .updateScreen(DeveloperSettingsNetworkViewModel.self),
                            value: pendingState.with(
                                devnetConfig: pendingState.devnetConfig.with(
                                    httpPort: httpPort
                                )
                            )
                        )
                    }
                )
            ),
            transitionType: .present
        )
    }
    
    private func showDevnetOmqPortModal(pendingState: State.NetworkState) {
        self.transitionToScreen(
            ConfirmationModal(
                info: ConfirmationModal.Info(
                    title: "Devnet QUIC Port",
                    body: .input(
                        explanation: ThemedAttributedString(
                            string: """
                            The QUIC port for the devnet seed node.
                            
                            Value must be a number between 0 and 65,535.
                            """
                        ),
                        info: ConfirmationModal.Info.Body.InputInfo(
                            placeholder: "Enter QUIC port",
                            initialValue: "\(pendingState.devnetConfig.omqPort)"
                        ),
                        onChange: { [weak self] value in self?.updatedDevnetOmqPort = value }
                    ),
                    confirmTitle: "save".localized(),
                    confirmEnabled: .afterChange { [weak self] _ in
                        guard let value: String = self?.updatedDevnetOmqPort else {
                            return false
                        }
                        
                        return (UInt16(value, radix: 10) != nil)
                    },
                    cancelStyle: .alert_text,
                    dismissOnConfirm: false,
                    onConfirm: { [weak self, dependencies] modal in
                        guard
                            let value: String = self?.updatedDevnetOmqPort,
                            let omqPort: UInt16 = UInt16(value, radix: 10)
                        else {
                            modal.updateContent(
                                withError: "Value must be a number between 0 and 65,535."
                            )
                            return
                        }
                        
                        modal.dismiss(animated: true)
                        dependencies.notifyAsync(
                            priority: .immediate,
                            key: .updateScreen(DeveloperSettingsNetworkViewModel.self),
                            value: pendingState.with(
                                devnetConfig: pendingState.devnetConfig.with(
                                    omqPort: omqPort
                                )
                            )
                        )
                    }
                )
            ),
            transitionType: .present
        )
    }
    
    // MARK: - Reverting
    
    public static func disableDeveloperMode(using dependencies: Dependencies) async {
        /// First determine if any changes need to be made to the environment
        var needsEnvironmentUpdate: Bool = false
        var needsRouterUpdate: Bool = false
        var needsPushServiceUpdate: Bool = false
        
        for feature in TableItem.allCases {
            switch feature {
                case .devnetPubkey, .devnetIp, .devnetHttpPort, .devnetOmqPort: break
                case .environment: needsEnvironmentUpdate = (dependencies[feature: .serviceNetwork] != .mainnet)
                case .router: needsRouterUpdate = (dependencies[feature: .router] != .onionRequests)
                case .pushNotificationService:
                    needsPushServiceUpdate = (dependencies[feature: .pushNotificationService] != .apns)
                
                case .forceOffline:
                    guard dependencies.hasSet(feature: .forceOffline) else { break }
                    
                    dependencies.set(feature: .forceOffline, to: nil)
            }
        }
        
        /// Then make the changes needed
        switch (needsEnvironmentUpdate, needsRouterUpdate) {
            case (true, true):
                /// If we are updating both the environment and the router then swap the router over first and trigger the environment
                /// update (as that resets the state anyway, also calling `updateRouter` would be inefficient in this case)
                dependencies.set(feature: .router, to: .onionRequests)
                
                await DeveloperSettingsNetworkViewModel.updateEnvironment(
                    serviceNetwork: .mainnet,
                    devnetConfig: nil,
                    using: dependencies
                )
                
            case (true, false):
                await DeveloperSettingsNetworkViewModel.updateEnvironment(
                    serviceNetwork: .mainnet,
                    devnetConfig: nil,
                    using: dependencies
                )
                
            case (false, true):
                await DeveloperSettingsNetworkViewModel.updateRouter(
                    router: .onionRequests,
                    using: dependencies
                )
                
            default: break
        }
        
        if needsPushServiceUpdate {
            await DeveloperSettingsNetworkViewModel.updatePushNotificationService(
                service: .apns,
                using: dependencies
            )
        }
    }
    
    // MARK: - Saving
    
    @MainActor private func saveChanges(hasConfirmed: Bool = false) async {
        guard internalState.initialState != internalState.pendingState else { return }
        
        let networkEnvironmentChanged: Bool = (
            internalState.initialState.environment != internalState.pendingState.environment || (
                internalState.initialState.environment == .devnet &&
                internalState.initialState.devnetConfig.isValid &&
                internalState.initialState.devnetConfig != internalState.pendingState.devnetConfig
            )
        )
        let routerChanged: Bool = (
            internalState.initialState.router != internalState.pendingState.router
        )
        let pushServiceChanged: Bool = (
            internalState.initialState.pushNotificationService != internalState.pendingState.pushNotificationService
        )
        
        /// Changing the network settings can result in data being cleared from the database so we should confirm that is desired before
        /// we make the changes
        guard hasConfirmed else {
            /// If we don't need confirmation then just go ahead (eg. `forceOffline` (or some new) change)
            guard networkEnvironmentChanged || routerChanged || pushServiceChanged else {
                return await self.saveChanges(hasConfirmed: true)
            }
            
            let message: ThemedAttributedString = ThemedAttributedString(string: "Are you sure you want to update the network settings to:\n")
            
            let style: NSMutableParagraphStyle = NSMutableParagraphStyle()
            style.alignment = .left
            
            /// Append the list of state changes
            if networkEnvironmentChanged {
                message.append(
                    ThemedAttributedString(
                        stringWithHTMLTags: """
                        \n<b>Environment:</b> <span>\(internalState.pendingState.environment.title)</span>
                        """,
                        font: ConfirmationModal.explanationFont
                    ).addingAttribute(.paragraphStyle, value: style)
                )
            }
            
            if routerChanged {
                message.append(
                    ThemedAttributedString(
                        stringWithHTMLTags: """
                        \n<b>Router:</b> <span>\(internalState.pendingState.router.title)</span>
                        """,
                        font: ConfirmationModal.explanationFont
                    ).addingAttribute(.paragraphStyle, value: style)
                )
            }
            
            if pushServiceChanged {
                message.append(
                    ThemedAttributedString(
                        stringWithHTMLTags: """
                        \n<b>PN Service:</b> <span>\(internalState.pendingState.pushNotificationService.title)</span>
                        """,
                        font: ConfirmationModal.explanationFont
                    ).addingAttribute(.paragraphStyle, value: style)
                )
            }
            
            /// Add the warnings
            message.append(
                ThemedAttributedString(
                    stringWithHTMLTags: "\n\n<b>Warning this will result in:</b>",
                    font: ConfirmationModal.explanationFont
                )
                .addingAttribute(.paragraphStyle, value: style)
                .addingAttribute(.themeForegroundColor, value: ThemeValue.warning)
            )
            
            if networkEnvironmentChanged {
                message.append(NSAttributedString(
                    string: "\n• All conversation and snode data being cleared and any pending network requests being cancelled.",
                    attributes: [NSAttributedString.Key.paragraphStyle: style]
                ))
            }
            if routerChanged && !networkEnvironmentChanged {
                message.append(NSAttributedString(
                    string: "\n• Any pending network requests being cancelled.",
                    attributes: [NSAttributedString.Key.paragraphStyle: style]
                ))
            }
            if pushServiceChanged {
                message.append(NSAttributedString(
                    string: "\n• Resubscribing for push notifications, which may take a few minutes.",
                    attributes: [NSAttributedString.Key.paragraphStyle: style]
                ))
            }
            
            if #unavailable(iOS 16.0), (networkEnvironmentChanged || routerChanged) {
                message.append(ThemedAttributedString(
                    string: "\n\nThe app will need to restart for these changes to take effect.",
                    attributes: [
                        .paragraphStyle: style,
                        .themeForegroundColor: ThemeValue.danger
                    ]
                ))
            }
            
            self.transitionToScreen(
                ConfirmationModal(
                    info: ConfirmationModal.Info(
                        title: "Change Network Settings",
                        body: .attributedText(message, scrollMode: .never),
                        confirmTitle: {
                            if #unavailable(iOS 16.0) {
                                return "Restart"
                            }
                            
                            return "confirm".localized()
                        }(),
                        confirmStyle: .danger,
                        cancelStyle: .alert_text,
                        onConfirm: { [weak self] _ in
                            Task { [weak self] in
                                await self?.saveChanges(hasConfirmed: true)
                            }
                        }
                    )
                ),
                transitionType: .present
            )
            return
        }
        
        /// If the `forceOffline` value changed then apply the change
        if internalState.initialState.forceOffline != internalState.pendingState.forceOffline {
            dependencies.set(feature: .forceOffline, to: internalState.pendingState.forceOffline)
            
            if !internalState.pendingState.forceOffline {
                await dependencies[singleton: .network].resetNetworkStatus()
            }
            else {
                await dependencies[singleton: .network].setNetworkStatus(status: .disconnected)
            }
        }
        
        /// If the network environment changed then we should make those changes first (since they result in the database being cleared)
        if networkEnvironmentChanged {
            let state: State.NetworkState = internalState.pendingState
            
            await DeveloperSettingsNetworkViewModel.updateEnvironment(
                serviceNetwork: state.environment,
                devnetConfig: (state.environment == .devnet && state.devnetConfig.isValid ?
                    state.devnetConfig :
                    nil
                ),
                additionalChanges: (routerChanged ?
                    /// If the router was also changed then we also need to change it during the `updateEnvironment` call
                    { [dependencies] in dependencies.set(feature: .router, to: state.router) } :
                    nil
                ),
                using: dependencies
            )
        }
        
        /// If the router changed then we need to recreate the `network` instance, but updating the environment does the same so
        /// no need to do it again in that case (we will have already updated the `router` feature value above in this case)
        if routerChanged && !networkEnvironmentChanged {
            let state: State.NetworkState = internalState.pendingState
            
            await DeveloperSettingsNetworkViewModel.updateRouter(
                router: state.router,
                using: dependencies
            )
        }
        
        /// Now that any environment changes have been made (which may result in rebuilding the network state, and likely clearing the
        /// database) we can trigger the push service change
        if pushServiceChanged && dependencies[defaults: .standard, key: .isUsingFullAPNs] {
            let state: State.NetworkState = internalState.pendingState
            
            await DeveloperSettingsNetworkViewModel.updatePushNotificationService(
                service: state.pushNotificationService,
                using: dependencies
            )
        }
        
        /// Changes have been saved so we can dismiss the screen
        self.dismissScreen()
    }
    
    // MARK: - Environment Changing
    
    internal static func updateEnvironment(
        serviceNetwork: ServiceNetwork,
        devnetConfig: ServiceNetwork.DevnetConfiguration?,
        additionalChanges: (() -> Void)? = nil,
        using dependencies: Dependencies
    ) async {
        struct IdentityData {
            let ed25519KeyPair: KeyPair
            let x25519KeyPair: KeyPair
        }
        
        /// Make sure we are actually changing the network before clearing all of the data
        guard
            serviceNetwork != dependencies[feature: .serviceNetwork] || (
            serviceNetwork == .devnet &&
                devnetConfig?.isValid == true &&
                devnetConfig != dependencies[feature: .devnetConfig]
            )
        else { return }
        
        /// Need to ensure we can retrieve the identity data before resetting everything (otherwise it'll wipe everything which we don't want)
        let identityData: IdentityData
        
        do {
            identityData = try await dependencies[singleton: .storage].readAsync(value: { db in
                IdentityData(
                    ed25519KeyPair: KeyPair(
                        publicKey: Array(try Identity
                            .filter(Identity.Columns.variant == Identity.Variant.ed25519PublicKey)
                            .fetchOne(db, orThrow: StorageError.objectNotFound)
                            .data),
                        secretKey: Array(try Identity
                            .filter(Identity.Columns.variant == Identity.Variant.ed25519SecretKey)
                            .fetchOne(db, orThrow: StorageError.objectNotFound)
                            .data)
                    ),
                    x25519KeyPair: KeyPair(
                        publicKey: Array(try Identity
                            .filter(Identity.Columns.variant == Identity.Variant.x25519PublicKey)
                            .fetchOne(db, orThrow: StorageError.objectNotFound)
                            .data),
                        secretKey: Array(try Identity
                            .filter(Identity.Columns.variant == Identity.Variant.x25519PrivateKey)
                            .fetchOne(db, orThrow: StorageError.objectNotFound)
                            .data)
                    )
                )
            })
        }
        catch { return Log.warn("[DevSettings] Environment change ignored due to error fetching identity data: \(error)") }
        
        Log.info("[DevSettings] Swapping environment to \(String(describing: serviceNetwork)), clearing data")
        
        /// Stop all pollers
        dependencies.remove(singleton: .currentUserPoller)
        dependencies.remove(singleton: .groupPollerManager)
        dependencies.remove(singleton: .communityPollerManager)
        
        /// Reset the network (only if it's already been created - don't want to initialise the network if it hasn't already been started)
        ///
        /// **Note:** We need to set this to a `NoopNetwork` because a number of objects observe the `networkStatus` which
        /// would result in automatic re-creation of the network with it's current config (since the `serviceNetwork` hasn't been updated
        /// yet)
        if dependencies.has(singleton: .network) {
            await dependencies[singleton: .network].suspendNetworkAccess()
            await dependencies[singleton: .network].finishCurrentObservations()
            await dependencies[singleton: .network].clearCache()
        }
        
        dependencies.set(singleton: .network, to: LibSession.NoopNetwork(using: dependencies))
        
        /// If we have a push token then retrieve any auth details for them so we can unsubscribe once we have the new network layer
        /// setup (since these will be server requests they aren't dependant on the `serviceNetwork` so can be run after we finish
        /// updating the environment)
        let existingPushInfo: (token: String, [AuthenticationMethod])? = await {
            let maybeToken: String? = try? await dependencies[singleton: .storage].readAsync { db in
                db[.lastRecordedPushToken]
            }
            let maybeSwarmAuth: [AuthenticationMethod]? = try? await Network.PushNotification.retrieveAllSwarmAuth(
                using: dependencies
            )
            
            guard
                let token: String = maybeToken,
                let swarmAuth: [AuthenticationMethod] = maybeSwarmAuth,
                !swarmAuth.isEmpty
            else { return nil }
            
            return (token, swarmAuth)
        }()
        
        /// Remove the libSession state (store the profile locally to maintain the name between environments)
        let existingProfile: Profile = dependencies.mutate(cache: .libSession) { $0.profile }
        dependencies.remove(cache: .libSession)
        
        /// Remove any network-specific data
        try? await dependencies[singleton: .storage].writeAsync { [dependencies] db in
            let userSessionId: SessionId = dependencies[cache: .general].sessionId
            
            _ = try SnodeReceivedMessageInfo.deleteAll(db)
            _ = try SessionThread.deleteAll(db)
            _ = try MessageDeduplication.deleteAll(db)
            _ = try ClosedGroup.deleteAll(db)
            _ = try OpenGroup.deleteAll(db)
            _ = try Capability.deleteAll(db)
            _ = try GroupMember.deleteAll(db)
            _ = try Contact
                .filter(Contact.Columns.id != userSessionId.hexString)
                .deleteAll(db)
            _ = try Profile
                .filter(Profile.Columns.id != userSessionId.hexString)
                .deleteAll(db)
            _ = try BlindedIdLookup.deleteAll(db)
            _ = try ConfigDump.deleteAll(db)
        }
        
        /// Remove the `ExtensionHelper` cache
        dependencies[singleton: .extensionHelper].deleteCache()
        
        Log.info("[DevSettings] Reloading state for \(String(describing: serviceNetwork))")
        
        /// Update to the new `ServiceNetwork`
        dependencies.set(feature: .serviceNetwork, to: serviceNetwork)
        
        if let devnetConfig: ServiceNetwork.DevnetConfiguration = devnetConfig {
            dependencies.set(feature: .devnetConfig, to: devnetConfig)
        }
        
        /// Perform any additional changes (eg. updating the `router`)
        additionalChanges?()
        
        /// Run the onboarding process as if we are recovering an account (will setup the device in it's proper state)
        let updatedOnboarding: Onboarding.Manager = Onboarding.Manager(
            ed25519KeyPair: identityData.ed25519KeyPair,
            x25519KeyPair: identityData.x25519KeyPair,
            displayName: existingProfile.name
                .nullIfEmpty
                .defaulting(to: "Anonymous"),
            using: dependencies
        )
        await updatedOnboarding.completeRegistration()
        
        /// Re-enable developer mode
        dependencies.setAsync(.developerModeEnabled, true)
        
        if #unavailable(iOS 16.0) {
            /// iOS 15 doesn't support live environment changes so we need to kill the app here
            Log.info("[DevSettings] Completed swap to \(String(describing: serviceNetwork))")
            Log.flush()
            dependencies[singleton: .storage].suspendDatabaseAccess()
            exit(0)
        }
            
        /// Store the updated oboarding
        dependencies.set(singleton: .onboarding, to: updatedOnboarding)
            
        /// Remove the temporary NoopNetwork and warm a new instance now that the `serviceNetwork` has been updated
        dependencies.remove(singleton: .network)
        dependencies.warm(singleton: .network)
        
        /// Restart the current user poller (there won't be any other pollers though)
        Task { @MainActor [poller = dependencies[singleton: .currentUserPoller]] in
            await poller.startIfNeeded()
        }
        
        /// Unsubscribe from old push notifications and re-sync the push tokens for the account on the new `serviceNetwork` (if there are any)
        switch existingPushInfo {
            case .none: SyncPushTokensJob.run(uploadOnlyIfStale: false, using: dependencies).sinkUntilComplete()
            case .some((let token, let swarmAuth)):
                Task.detached(priority: .userInitiated) {
                    _ = try? await Network.PushNotification.unsubscribe(
                        token: Data(hex: token),
                        swarmAuthentication: swarmAuth,
                        using: dependencies
                    )
                    
                    SyncPushTokensJob.run(uploadOnlyIfStale: false, using: dependencies).sinkUntilComplete()
                }
        }
        
        Log.info("[DevSettings] Completed swap to \(String(describing: serviceNetwork))")
    }
    
    internal static func updateRouter(
        router: Router,
        using dependencies: Dependencies
    ) async {
        /// Make sure we are actually changing the router before recreating the network
        guard router != dependencies[feature: .router] else { return }
        
        Log.info("[DevSettings] Swapping router to \(String(describing: router))")
        
        /// Stop all pollers
        dependencies.remove(singleton: .currentUserPoller)
        dependencies.remove(singleton: .groupPollerManager)
        dependencies.remove(singleton: .communityPollerManager)
        
        /// Reset the network (only if it's already been created - don't want to initialise the network if it hasn't already been started)
        ///
        /// **Note:** We need to set this to a `NoopNetwork` because a number of objects observe the `networkStatus` which
        /// would result in automatic re-creation of the network with it's current config (since the `serviceNetwork` hasn't been updated
        /// yet)
        ///
        /// **Note 2:** No need to clear the snode cache in this case as we aren't swapping the environment
        if dependencies.has(singleton: .network) {
            await dependencies[singleton: .network].suspendNetworkAccess()
            await dependencies[singleton: .network].finishCurrentObservations()
        }
        
        dependencies.set(singleton: .network, to: LibSession.NoopNetwork(using: dependencies))
        
        /// Update to the new `Router`
        dependencies.set(feature: .router, to: router)
        
        /// Remove the temporary NoopNetwork and warm a new instance now that the `router` has been updated
        dependencies.remove(singleton: .network)
        dependencies.warm(singleton: .network)
        
        /// Restart all pollers
        Task { @MainActor [dependencies] in
            guard await dependencies[singleton: .onboarding].state.first() == .completed else { return }
            
            await dependencies[singleton: .currentUserPoller].startIfNeeded()
            await dependencies[singleton: .groupPollerManager].startAllPollers()
            await dependencies[singleton: .communityPollerManager].startAllPollers()
        }
        
        Log.info("[DevSettings] Completed swap to \(String(describing: router))")
    }
    
    internal static func updatePushNotificationService(
        service: Network.PushNotification.Service,
        using dependencies: Dependencies
    ) async {
        guard dependencies[defaults: .standard, key: .isUsingFullAPNs] else { return }
        
        /// Disable push notifications to trigger the unsubscribe, then re-enable them after updating the feature setting
        dependencies[defaults: .standard, key: .isUsingFullAPNs] = false
        
        SyncPushTokensJob
            .run(uploadOnlyIfStale: false, using: dependencies)
            .handleEvents(
                receiveOutput: { [dependencies] _ in
                    dependencies.set(feature: .pushNotificationService, to: service)
                    dependencies[defaults: .standard, key: .isUsingFullAPNs] = true
                }
            )
            .flatMap { [dependencies] _ in
                SyncPushTokensJob.run(uploadOnlyIfStale: false, using: dependencies)
            }
            .sinkUntilComplete()
    }
}
