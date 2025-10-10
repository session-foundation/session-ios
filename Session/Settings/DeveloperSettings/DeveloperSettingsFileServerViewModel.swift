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

class DeveloperSettingsFileServerViewModel: SessionTableViewModel, NavigatableStateHolder, ObservableTableSource {
    public let dependencies: Dependencies
    public let navigatableState: NavigatableState = NavigatableState()
    public let state: TableDataState<Section, TableItem> = TableDataState()
    public let observableState: ObservableTableSourceState<Section, TableItem> = ObservableTableSourceState()
    
    private var updatedCustomServerUrl: String?
    private var updatedCustomServerPubkey: String?
    
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
            .query(DeveloperSettingsFileServerViewModel.queryState)
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
        
        var title: String? {
            switch self {
                case .general: return nil
            }
        }
        
        var style: SessionTableSectionStyle {
            switch self {
                case .general: return .padding
            }
        }
    }
    
    public enum TableItem: Hashable, Differentiable, CaseIterable {
        case shortenFileTTL
        case deterministicAttachmentEncryption
        case customFileServerUrl
        case customFileServerPubkey
        
        // MARK: - Conformance
        
        public typealias DifferenceIdentifier = String
        
        public var differenceIdentifier: String {
            switch self {
                case .shortenFileTTL: return "shortenFileTTL"
                case .deterministicAttachmentEncryption: return "deterministicAttachmentEncryption"
                case .customFileServerUrl: return "customFileServerUrl"
                case .customFileServerPubkey: return "customFileServerPubkey"
            }
        }
        
        public func isContentEqual(to source: TableItem) -> Bool {
            self.differenceIdentifier == source.differenceIdentifier
        }
        
        public static var allCases: [TableItem] {
            var result: [TableItem] = []
            switch TableItem.shortenFileTTL {
                case .shortenFileTTL: result.append(.shortenFileTTL); fallthrough
                case .deterministicAttachmentEncryption: result.append(.deterministicAttachmentEncryption); fallthrough
                case .customFileServerUrl: result.append(.customFileServerUrl); fallthrough
                case .customFileServerPubkey: result.append(.customFileServerPubkey)
            }
            
            return result
        }
    }
    
    // MARK: - Content
    
    public struct State: Equatable, ObservableKeyProvider {
        struct Info: Equatable, Hashable {
            let shortenFileTTL: Bool
            let deterministicAttachmentEncryption: Bool
            let customFileServer: Network.FileServer.Custom
            
            public func with(
                shortenFileTTL: Bool? = nil,
                deterministicAttachmentEncryption: Bool? = nil,
                customFileServer: Network.FileServer.Custom? = nil
            ) -> Info {
                return Info(
                    shortenFileTTL: (shortenFileTTL ?? self.shortenFileTTL),
                    deterministicAttachmentEncryption: (deterministicAttachmentEncryption ?? self.deterministicAttachmentEncryption),
                    customFileServer: (customFileServer ?? self.customFileServer)
                )
            }
        }
        
        let initialState: Info
        let pendingState: Info
        
        @MainActor public func sections(viewModel: DeveloperSettingsFileServerViewModel, previousState: State) -> [SectionModel] {
            DeveloperSettingsFileServerViewModel.sections(
                state: self,
                previousState: previousState,
                viewModel: viewModel
            )
        }
        
        public let observedKeys: Set<ObservableKey> = [
            .updateScreen(DeveloperSettingsFileServerViewModel.self),
            .feature(.shortenFileTTL),
            .feature(.deterministicAttachmentEncryption),
            .feature(.customFileServer)
        ]
        
        static func initialState(using dependencies: Dependencies) -> State {
            let initialInfo: Info = Info(
                shortenFileTTL: dependencies[feature: .shortenFileTTL],
                deterministicAttachmentEncryption: dependencies[feature: .deterministicAttachmentEncryption],
                customFileServer: dependencies[feature: .customFileServer]
            )
            
            return State(
                initialState: initialInfo,
                pendingState: initialInfo
            )
        }
    }
    
    let title: String = "Developer File Server Settings"
    
    lazy var footerButtonInfo: AnyPublisher<SessionButton.Info?, Never> = $internalState
        .map { [weak self] state -> SessionButton.Info? in
            return SessionButton.Info(
                style: .bordered,
                title: "set".localized(),
                isEnabled: {
                    guard state.initialState != state.pendingState else { return false }
                    
                    return (
                        state.pendingState.customFileServer.isEmpty ||
                        state.pendingState.customFileServer.isValid
                    )
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
            pendingState: (events.first?.value as? State.Info ?? previousState.pendingState)
        )
    }
    
    private static func sections(
        state: State,
        previousState: State,
        viewModel: DeveloperSettingsFileServerViewModel
    ) -> [SectionModel] {
        let general: SectionModel = SectionModel(
            model: .general,
            elements: [
                SessionCell.Info(
                    id: .shortenFileTTL,
                    title: "Shorten File TTL",
                    subtitle: "Set the TTL for files in the cache to 1 minute",
                    trailingAccessory: .toggle(
                        state.pendingState.shortenFileTTL,
                        oldValue: previousState.pendingState.shortenFileTTL
                    ),
                    onTap: { [dependencies = viewModel.dependencies] in
                        dependencies.notifyAsync(
                            priority: .immediate,
                            key: .updateScreen(DeveloperSettingsFileServerViewModel.self),
                            value: state.pendingState.with(
                                shortenFileTTL: !state.pendingState.shortenFileTTL
                            )
                        )
                    }
                ),
                SessionCell.Info(
                    id: .deterministicAttachmentEncryption,
                    title: "Deterministic Attachment Encryption",
                    subtitle: """
                    Controls whether the new deterministic encryption should be used for attachment and display pictures
                    
                    <warn>Warning: Old clients won't be able to decrypt attachments sent while this is enabled</warn>
                    """,
                    trailingAccessory: .toggle(
                        state.pendingState.deterministicAttachmentEncryption,
                        oldValue: previousState.pendingState.deterministicAttachmentEncryption
                    ),
                    onTap: { [dependencies = viewModel.dependencies] in
                        dependencies.notifyAsync(
                            priority: .immediate,
                            key: .updateScreen(DeveloperSettingsFileServerViewModel.self),
                            value: state.pendingState.with(
                                deterministicAttachmentEncryption: !state.pendingState.deterministicAttachmentEncryption
                            )
                        )
                    }
                ),
                SessionCell.Info(
                    id: .customFileServerUrl,
                    title: "Custom File Server URL",
                    subtitle: """
                    The URL to use instead of the default File Server for uploading files
                    
                    <b>Current:</b> <span>\(state.pendingState.customFileServer.url.isEmpty ? "Default" : state.pendingState.customFileServer.url)</span>
                    """,
                    trailingAccessory: .icon(.squarePen),
                    onTap: { [weak viewModel] in
                        viewModel?.showServerUrlModal(pendingState: state.pendingState)
                    }
                ),
                SessionCell.Info(
                    id: .customFileServerPubkey,
                    title: "Custom File Server Public Key",
                    subtitle: """
                    The public key to use for the above custom File Server (if empty then the pubkey for the default file server will be used)
                    
                    <b>Current:</b> <span>\(state.pendingState.customFileServer.pubkey.isEmpty ? "Default" : state.pendingState.customFileServer.pubkey)</span>
                    """,
                    trailingAccessory: .icon(.squarePen),
                    onTap: { [weak viewModel] in
                        viewModel?.showServerPubkeyModal(pendingState: state.pendingState)
                    }
                )
            ]
        )
        
        return [general]
    }
    
    // MARK: - Internal Functions
    
    private func showServerUrlModal(pendingState: State.Info) {
        self.transitionToScreen(
            ConfirmationModal(
                info: ConfirmationModal.Info(
                    title: "Custom File Server URL",
                    body: .input(
                        explanation: ThemedAttributedString(
                            string: "The url for the custom file server."
                        ),
                        info: ConfirmationModal.Info.Body.InputInfo(
                            placeholder: "Enter URL",
                            initialValue: pendingState.customFileServer.url,
                            inputChecker: { text in
                                guard URL(string: text) != nil else {
                                    return "Value must be a valid url (with HTTP or HTTPS)."
                                }
                                
                                return nil
                            }
                        ),
                        onChange: { [weak self] value in
                            self?.updatedCustomServerUrl = value.lowercased()
                        }
                    ),
                    confirmTitle: "save".localized(),
                    confirmEnabled: .afterChange { [weak self] _ in
                        guard
                            let value: String = self?.updatedCustomServerUrl,
                            let url: URL = URL(string: value)
                        else { return false }
                        
                        return (url.scheme != nil && url.host != nil)
                    },
                    cancelTitle: (pendingState.customFileServer.url.isEmpty ?
                        "cancel".localized() :
                        "remove".localized()
                    ),
                    cancelStyle: (pendingState.customFileServer.url.isEmpty ? .alert_text : .danger),
                    hasCloseButton: !pendingState.customFileServer.url.isEmpty,
                    dismissOnConfirm: false,
                    onConfirm: { [weak self, dependencies] modal in
                        guard
                            let value: String = self?.updatedCustomServerUrl,
                            URL(string: value) != nil
                        else {
                            modal.updateContent(
                                withError: "Value must be a valid url (with HTTP or HTTPS)."
                            )
                            return
                        }
                        
                        modal.dismiss(animated: true)
                        dependencies.notifyAsync(
                            priority: .immediate,
                            key: .updateScreen(DeveloperSettingsFileServerViewModel.self),
                            value: pendingState.with(
                                customFileServer: pendingState.customFileServer.with(
                                    url: value
                                )
                            )
                        )
                    },
                    onCancel: { [dependencies] modal in
                        modal.dismiss(animated: true)
                        
                        guard !pendingState.customFileServer.url.isEmpty else { return }
                        
                        dependencies.notifyAsync(
                            priority: .immediate,
                            key: .updateScreen(DeveloperSettingsFileServerViewModel.self),
                            value: pendingState.with(
                                customFileServer: pendingState.customFileServer.with(url: "")
                            )
                        )
                    }
                )
            ),
            transitionType: .present
        )
    }
    
    private func showServerPubkeyModal(pendingState: State.Info) {
        self.transitionToScreen(
            ConfirmationModal(
                info: ConfirmationModal.Info(
                    title: "Custom File Server Pubkey",
                    body: .input(
                        explanation: ThemedAttributedString(
                            string: """
                            The public key for the custom file server.
                            
                            This is 64 character hexadecimal value.
                            """
                        ),
                        info: ConfirmationModal.Info.Body.InputInfo(
                            placeholder: "Enter Pubkey",
                            initialValue: pendingState.customFileServer.pubkey,
                            inputChecker: { text in
                                guard text.count <= 64 else {
                                    return "Value must be a 64 character hexadecimal string."
                                }
                                
                                return nil
                            }
                        ),
                        onChange: { [weak self] value in
                            self?.updatedCustomServerPubkey = value
                        }
                    ),
                    confirmTitle: "save".localized(),
                    confirmEnabled: .afterChange { [weak self] _ in
                        guard let value: String = self?.updatedCustomServerPubkey else {
                            return false
                        }
                        
                        return (
                            Hex.isValid(value) &&
                            value.trimmingCharacters(in: .whitespacesAndNewlines).count == 64
                        )
                    },
                    cancelTitle: (pendingState.customFileServer.pubkey.isEmpty ?
                        "cancel".localized() :
                        "remove".localized()
                    ),
                    cancelStyle: (pendingState.customFileServer.pubkey.isEmpty ? .alert_text : .danger),
                    hasCloseButton: !pendingState.customFileServer.pubkey.isEmpty,
                    dismissOnConfirm: false,
                    onConfirm: { [weak self, dependencies] modal in
                        guard
                            let value: String = self?.updatedCustomServerPubkey,
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
                            key: .updateScreen(DeveloperSettingsFileServerViewModel.self),
                            value: pendingState.with(
                                customFileServer: pendingState.customFileServer.with(
                                    pubkey: value
                                )
                            )
                        )
                    },
                    onCancel: { [dependencies] modal in
                        modal.dismiss(animated: true)
                        
                        guard !pendingState.customFileServer.pubkey.isEmpty else { return }
                        
                        dependencies.notifyAsync(
                            priority: .immediate,
                            key: .updateScreen(DeveloperSettingsFileServerViewModel.self),
                            value: pendingState.with(
                                customFileServer: pendingState.customFileServer.with(pubkey: "")
                            )
                        )
                    }
                )
            ),
            transitionType: .present
        )
    }
    
    // MARK: - Reverting
    
    public static func disableDeveloperMode(using dependencies: Dependencies) {
        let features: [FeatureConfig<Bool>] = [
            .shortenFileTTL,
            .deterministicAttachmentEncryption
        ]
        
        features.forEach { feature in
            guard dependencies.hasSet(feature: feature) else { return }
            
            dependencies.set(feature: feature, to: nil)
        }
        
        if dependencies.hasSet(feature: .customFileServer) {
            dependencies.set(feature: .customFileServer, to: nil)
        }
    }
    
    // MARK: - Saving
    
    @MainActor private func saveChanges(hasConfirmed: Bool = false) async {
        guard internalState.initialState != internalState.pendingState else { return }
        
        if internalState.initialState.shortenFileTTL != internalState.pendingState.shortenFileTTL {
            dependencies.set(feature: .shortenFileTTL, to: internalState.pendingState.shortenFileTTL)
        }
        
        if internalState.initialState.deterministicAttachmentEncryption != internalState.pendingState.deterministicAttachmentEncryption {
            dependencies.set(
                feature: .deterministicAttachmentEncryption,
                to: internalState.pendingState.deterministicAttachmentEncryption
            )
        }
        
        if internalState.initialState.customFileServer != internalState.pendingState.customFileServer {
            dependencies.set(
                feature: .customFileServer,
                to: internalState.pendingState.customFileServer
            )
        }
        
        /// Changes have been saved so we can dismiss the screen
        self.dismissScreen()
    }
}
