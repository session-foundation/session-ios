// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import StoreKit
import Combine
import GRDB
import DifferenceKit
import SessionUIKit
import SessionNetworkingKit
import SessionMessagingKit
import SessionUtilitiesKit

class DeveloperSettingsProViewModel: SessionTableViewModel, NavigatableStateHolder, ObservableTableSource {
    public let dependencies: Dependencies
    public let navigatableState: NavigatableState = NavigatableState()
    public let state: TableDataState<Section, TableItem> = TableDataState()
    public let observableState: ObservableTableSourceState<Section, TableItem> = ObservableTableSourceState()
    
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
            .query(DeveloperSettingsProViewModel.queryState)
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
        case subscriptions
        case proBackend
        case features
        
        var title: String? {
            switch self {
                case .general: return nil
                case .subscriptions: return "Subscriptions"
                case .proBackend: return "Pro Backend"
                case .features: return "Features"
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
        case enableSessionPro
        
        case mockCurrentUserSessionProBuildVariant
        case mockCurrentUserSessionProBackendStatus
        case mockCurrentUserSessionProLoadingState
        case mockCurrentUserSessionProOriginatingPlatform
        case mockCurrentUserOriginatingAccount
        case mockCurrentUserAccessExpiryTimestamp
        case proBadgeEverywhere
        case fakeAppleSubscriptionForDev

        case forceMessageFeatureProBadge
        case forceMessageFeatureLongMessage
        case forceMessageFeatureAnimatedAvatar
        
        case purchaseProSubscription
        case manageProSubscriptions
        case restoreProSubscription
        case requestRefund
        
        case submitPurchaseToProBackend
        case refreshProState
        case resetRevocationListTicket
        case removeProFromUserConfig
        
        // MARK: - Conformance
        
        public typealias DifferenceIdentifier = String
        
        public var differenceIdentifier: String {
            switch self {
                case .enableSessionPro: return "enableSessionPro"
                    
                case .mockCurrentUserSessionProBuildVariant: return "mockCurrentUserSessionProBuildVariant"
                case .mockCurrentUserSessionProBackendStatus: return "mockCurrentUserSessionProBackendStatus"
                case .mockCurrentUserSessionProLoadingState: return "mockCurrentUserSessionProLoadingState"
                case .mockCurrentUserSessionProOriginatingPlatform: return "mockCurrentUserSessionProOriginatingPlatform"
                case .mockCurrentUserOriginatingAccount: return "mockCurrentUserOriginatingAccount"
                case .mockCurrentUserAccessExpiryTimestamp: return "mockCurrentUserAccessExpiryTimestamp"
                case .proBadgeEverywhere: return "proBadgeEverywhere"
                case .fakeAppleSubscriptionForDev: return "fakeAppleSubscriptionForDev"
                
                case .forceMessageFeatureProBadge: return "forceMessageFeatureProBadge"
                case .forceMessageFeatureLongMessage: return "forceMessageFeatureLongMessage"
                case .forceMessageFeatureAnimatedAvatar: return "forceMessageFeatureAnimatedAvatar"
                
                case .purchaseProSubscription: return "purchaseProSubscription"
                case .manageProSubscriptions: return "manageProSubscriptions"
                case .restoreProSubscription: return "restoreProSubscription"
                case .requestRefund: return "requestRefund"
                
                case .submitPurchaseToProBackend: return "submitPurchaseToProBackend"
                case .refreshProState: return "refreshProState"
                case .resetRevocationListTicket: return "resetRevocationListTicket"
                case .removeProFromUserConfig: return "removeProFromUserConfig"
            }
        }
        
        public func isContentEqual(to source: TableItem) -> Bool {
            self.differenceIdentifier == source.differenceIdentifier
        }
        
        public static var allCases: [TableItem] {
            var result: [TableItem] = []
            switch TableItem.enableSessionPro {
                case .enableSessionPro: result.append(.enableSessionPro); fallthrough
                
                case .mockCurrentUserSessionProBuildVariant: result.append(.mockCurrentUserSessionProBuildVariant); fallthrough
                case .mockCurrentUserSessionProBackendStatus: result.append(.mockCurrentUserSessionProBackendStatus); fallthrough
                case .mockCurrentUserSessionProLoadingState: result.append(.mockCurrentUserSessionProLoadingState); fallthrough
                case .mockCurrentUserSessionProOriginatingPlatform: result.append(.mockCurrentUserSessionProOriginatingPlatform); fallthrough
                case .mockCurrentUserAccessExpiryTimestamp: result.append(.mockCurrentUserAccessExpiryTimestamp); fallthrough
                case .mockCurrentUserOriginatingAccount: result.append(.mockCurrentUserOriginatingAccount); fallthrough
                case .proBadgeEverywhere: result.append(.proBadgeEverywhere); fallthrough
                case .fakeAppleSubscriptionForDev: result.append(.fakeAppleSubscriptionForDev); fallthrough

                case .forceMessageFeatureProBadge: result.append(.forceMessageFeatureProBadge); fallthrough
                case .forceMessageFeatureLongMessage: result.append(.forceMessageFeatureLongMessage); fallthrough
                case .forceMessageFeatureAnimatedAvatar: result.append(.forceMessageFeatureAnimatedAvatar); fallthrough
                
                case .purchaseProSubscription: result.append(.purchaseProSubscription); fallthrough
                case .manageProSubscriptions: result.append(.manageProSubscriptions); fallthrough
                case .restoreProSubscription: result.append(.restoreProSubscription); fallthrough
                case .requestRefund: result.append(.requestRefund); fallthrough
                
                case .submitPurchaseToProBackend: result.append(.submitPurchaseToProBackend); fallthrough
                case .refreshProState: result.append(.refreshProState); fallthrough
                case .resetRevocationListTicket: result.append(.resetRevocationListTicket); fallthrough
                case .removeProFromUserConfig: result.append(.removeProFromUserConfig)
            }
            
            return result
        }
    }
    
    public enum DeveloperSettingsProEvent: Hashable {
        case purchasedProduct([Product], Product?, String?, String?, Transaction?)
        case refundTransaction(Transaction.RefundRequestStatus)
        case submittedTransaction(String?, Bool)
        case currentProStatus(String?, Bool)
    }
    
    // MARK: - Content
    
    public struct State: Equatable, ObservableKeyProvider {
        let sessionProEnabled: Bool
        
        let mockCurrentUserSessionProBuildVariant: MockableFeature<BuildVariant>
        let mockCurrentUserSessionProBackendStatus: MockableFeature<Network.SessionPro.BackendUserProStatus>
        let mockCurrentUserSessionProLoadingState: MockableFeature<SessionPro.LoadingState>
        let mockCurrentUserSessionProOriginatingPlatform: MockableFeature<SessionProUI.ClientPlatform>
        let mockCurrentUserOriginatingAccount: MockableFeature<SessionPro.OriginatingAccount>
        let mockCurrentUserAccessExpiryTimestamp: TimeInterval
        let proBadgeEverywhere: Bool
        let fakeAppleSubscriptionForDev: Bool

        let forceMessageFeatureProBadge: Bool
        let forceMessageFeatureLongMessage: Bool
        let forceMessageFeatureAnimatedAvatar: Bool
        
        let products: [Product]
        let purchasedProduct: Product?
        let purchaseError: String?
        let purchaseStatus: String?
        let purchaseTransaction: Transaction?
        let refundRequestStatus: Transaction.RefundRequestStatus?
        
        let submittedTransactionStatus: String?
        let submittedTransactionErrored: Bool
        
        let currentProStatus: String?
        let currentProStatusErrored: Bool
        let currentRevocationListTicket: UInt32
        
        @MainActor public func sections(viewModel: DeveloperSettingsProViewModel, previousState: State) -> [SectionModel] {
            DeveloperSettingsProViewModel.sections(
                state: self,
                previousState: previousState,
                viewModel: viewModel
            )
        }
        
        public let observedKeys: Set<ObservableKey> = [
            .feature(.sessionProEnabled),
            .feature(.mockCurrentUserSessionProBuildVariant),
            .feature(.mockCurrentUserSessionProBackendStatus),
            .feature(.mockCurrentUserSessionProLoadingState),
            .feature(.mockCurrentUserSessionProOriginatingPlatform),
            .feature(.mockCurrentUserOriginatingAccount),
            .feature(.mockCurrentUserAccessExpiryTimestamp),
            .feature(.proBadgeEverywhere),
            .feature(.fakeAppleSubscriptionForDev),
            .feature(.forceMessageFeatureProBadge),
            .feature(.forceMessageFeatureLongMessage),
            .feature(.forceMessageFeatureAnimatedAvatar),
            .updateScreen(DeveloperSettingsProViewModel.self),
            .proRevocationListUpdated
        ]
        
        static func initialState(using dependencies: Dependencies) -> State {
            return State(
                sessionProEnabled: dependencies[feature: .sessionProEnabled],
                
                mockCurrentUserSessionProBuildVariant: dependencies[feature: .mockCurrentUserSessionProBuildVariant],
                mockCurrentUserSessionProBackendStatus: dependencies[feature: .mockCurrentUserSessionProBackendStatus],
                mockCurrentUserSessionProLoadingState: dependencies[feature: .mockCurrentUserSessionProLoadingState],
                mockCurrentUserSessionProOriginatingPlatform: dependencies[feature: .mockCurrentUserSessionProOriginatingPlatform],
                mockCurrentUserOriginatingAccount: dependencies[feature: .mockCurrentUserOriginatingAccount],
                mockCurrentUserAccessExpiryTimestamp: dependencies[feature: .mockCurrentUserAccessExpiryTimestamp],
                proBadgeEverywhere: dependencies[feature: .proBadgeEverywhere],
                fakeAppleSubscriptionForDev: dependencies[feature: .fakeAppleSubscriptionForDev],
                
                forceMessageFeatureProBadge: dependencies[feature: .forceMessageFeatureProBadge],
                forceMessageFeatureLongMessage: dependencies[feature: .forceMessageFeatureLongMessage],
                forceMessageFeatureAnimatedAvatar: dependencies[feature: .forceMessageFeatureAnimatedAvatar],
                
                products: [],
                purchasedProduct: nil,
                purchaseError: nil,
                purchaseStatus: nil,
                purchaseTransaction: nil,
                refundRequestStatus: nil,
                
                submittedTransactionStatus: nil,
                submittedTransactionErrored: false,
                
                currentProStatus: nil,
                currentProStatusErrored: false,
                currentRevocationListTicket: 0
            )
        }
    }
    
    let title: String = "Developer Pro Settings"
    
    @Sendable private static func queryState(
        previousState: State,
        events: [ObservedEvent],
        isInitialQuery: Bool,
        using dependencies: Dependencies
    ) async -> State {
        var currentProStatus: String? = previousState.currentProStatus
        var currentProStatusErrored: Bool = previousState.currentProStatusErrored
        
        var products: [Product] = previousState.products
        var purchasedProduct: Product? = previousState.purchasedProduct
        var purchaseError: String? = previousState.purchaseError
        var purchaseStatus: String? = previousState.purchaseStatus
        var purchaseTransaction: Transaction? = previousState.purchaseTransaction
        var refundRequestStatus: Transaction.RefundRequestStatus? = previousState.refundRequestStatus
        var submittedTransactionStatus: String? = previousState.submittedTransactionStatus
        var submittedTransactionErrored: Bool = previousState.submittedTransactionErrored
        var currentRevocationListTicket: UInt32 = previousState.currentRevocationListTicket
        
        if isInitialQuery {
            currentRevocationListTicket = ((try? await dependencies[singleton: .storage].readAsync { db in
                UInt32(db[.proRevocationsTicket] ?? 0)
            }) ?? 0)
        }
        
        let changes: EventChangeset = events.split()
        
        changes.forEach(.updateScreen, as: DeveloperSettingsProEvent.self) { eventValue in
            switch eventValue {
                case .purchasedProduct(let receivedProducts, let purchased, let error, let status, let transaction):
                    products = receivedProducts
                    purchasedProduct = purchased
                    purchaseError = error
                    purchaseStatus = status
                    purchaseTransaction = transaction
                    
                case .refundTransaction(let status):
                    refundRequestStatus = status
                    
                case .submittedTransaction(let status, let errored):
                    submittedTransactionStatus = status
                    submittedTransactionErrored = errored
                    
                case .currentProStatus(let status, let errored):
                    currentProStatus = status
                    currentProStatusErrored = errored
            }
        }
        
        if changes.contains(.proRevocationListUpdated) {
            currentRevocationListTicket = ((try? await dependencies[singleton: .storage].readAsync { db in
                UInt32(db[.proRevocationsTicket] ?? 0)
            }) ?? currentRevocationListTicket)
        }
        
        return State(
            sessionProEnabled: dependencies[feature: .sessionProEnabled],
            mockCurrentUserSessionProBuildVariant: dependencies[feature: .mockCurrentUserSessionProBuildVariant],
            mockCurrentUserSessionProBackendStatus: dependencies[feature: .mockCurrentUserSessionProBackendStatus],
            mockCurrentUserSessionProLoadingState: dependencies[feature: .mockCurrentUserSessionProLoadingState],
            mockCurrentUserSessionProOriginatingPlatform: dependencies[feature: .mockCurrentUserSessionProOriginatingPlatform],
            mockCurrentUserOriginatingAccount: dependencies[feature: .mockCurrentUserOriginatingAccount],
            mockCurrentUserAccessExpiryTimestamp: dependencies[feature: .mockCurrentUserAccessExpiryTimestamp],
            proBadgeEverywhere: dependencies[feature: .proBadgeEverywhere],
            fakeAppleSubscriptionForDev: dependencies[feature: .fakeAppleSubscriptionForDev],
            forceMessageFeatureProBadge: dependencies[feature: .forceMessageFeatureProBadge],
            forceMessageFeatureLongMessage: dependencies[feature: .forceMessageFeatureLongMessage],
            forceMessageFeatureAnimatedAvatar: dependencies[feature: .forceMessageFeatureAnimatedAvatar],
            products: products,
            purchasedProduct: purchasedProduct,
            purchaseError: purchaseError,
            purchaseStatus: purchaseStatus,
            purchaseTransaction: purchaseTransaction,
            refundRequestStatus: refundRequestStatus,
            submittedTransactionStatus: submittedTransactionStatus,
            submittedTransactionErrored: submittedTransactionErrored,
            currentProStatus: currentProStatus,
            currentProStatusErrored: currentProStatusErrored,
            currentRevocationListTicket: currentRevocationListTicket
        )
    }
    
    private static func sections(
        state: State,
        previousState: State,
        viewModel: DeveloperSettingsProViewModel
    ) -> [SectionModel] {
        let general: SectionModel = SectionModel(
            model: .general,
            elements: [
                SessionCell.Info(
                    id: .enableSessionPro,
                    title: "Enable Session Pro",
                    subtitle: """
                    Enable Post Pro Release mode.
                    Turning on this Settings will show Pro badge and CTA if needed.
                    """,
                    trailingAccessory: .toggle(
                        state.sessionProEnabled,
                        oldValue: previousState.sessionProEnabled
                    ),
                    onTap: { [weak viewModel] in
                        viewModel?.updateSessionProEnabled(current: state.sessionProEnabled)
                    }
                )
            ]
        )
        
        guard state.sessionProEnabled else { return [general] }
        
        // MARK: - Mockable Features
        
        let features: SectionModel = SectionModel(
            model: .features,
            elements: [
                SessionCell.Info(
                    id: .mockCurrentUserSessionProBuildVariant,
                    title: "Mocked Build Variant",
                    subtitle: """
                    Force the app to be a specific build variant.
                    
                    <b>Current:</b> \(devValue: state.mockCurrentUserSessionProBuildVariant)
                    """,
                    trailingAccessory: .icon(.squarePen),
                    onTap: { [weak viewModel, dependencies = viewModel.dependencies] in
                        DeveloperSettingsViewModel.showModalForMockableState(
                            title: "Mocked Build Variant",
                            explanation: "Force the app to be a specific build variant.",
                            feature: .mockCurrentUserSessionProBuildVariant,
                            currentValue: state.mockCurrentUserSessionProBuildVariant,
                            navigatableStateHolder: viewModel,
                            onMockingRemoved: { [dependencies] in
                                Task.detached(priority: .userInitiated) { [dependencies] in
                                    try? await dependencies[singleton: .sessionProManager].refreshProState()
                                }
                            },
                            using: viewModel?.dependencies
                        )
                    }
                ),
                SessionCell.Info(
                    id: .mockCurrentUserSessionProBackendStatus,
                    title: "Mocked Pro Status",
                    subtitle: """
                    Force the current users Session Pro to a specific status locally.
                    
                    <b>Current:</b> \(devValue: state.mockCurrentUserSessionProBackendStatus)
                    """,
                    trailingAccessory: .icon(.squarePen),
                    onTap: { [weak viewModel, dependencies = viewModel.dependencies] in
                        DeveloperSettingsViewModel.showModalForMockableState(
                            title: "Mocked Pro Status",
                            explanation: "Force the current users Session Pro to a specific status locally.",
                            feature: .mockCurrentUserSessionProBackendStatus,
                            currentValue: state.mockCurrentUserSessionProBackendStatus,
                            navigatableStateHolder: viewModel,
                            onMockingRemoved: { [dependencies] in
                                Task.detached(priority: .userInitiated) { [dependencies] in
                                    try? await dependencies[singleton: .sessionProManager].refreshProState()
                                }
                            },
                            using: viewModel?.dependencies
                        )
                    }
                ),
                SessionCell.Info(
                    id: .mockCurrentUserSessionProLoadingState,
                    title: "Mocked Loading State",
                    subtitle: """
                    Force the Session Pro UI into a specific loading state.
                    
                    <b>Current:</b> \(devValue: state.mockCurrentUserSessionProLoadingState)
                    
                    Note: This option will only be available if the users pro state has been mocked, there is already a mocked loading state, or the users pro state has been fetched via the "Refresh Pro State" action on this screen.
                    """,
                    trailingAccessory: .icon(.squarePen),
                    isEnabled: {
                        switch (state.mockCurrentUserSessionProLoadingState, state.mockCurrentUserSessionProBackendStatus, state.currentProStatus) {
                            case (.simulate, _, _), (_, .simulate, _), (_, _, .some): return true
                            default: return false
                        }
                    }(),
                    onTap: { [weak viewModel, dependencies = viewModel.dependencies] in
                        DeveloperSettingsViewModel.showModalForMockableState(
                            title: "Mocked Loading State",
                            explanation: "Force the Session Pro UI into a specific loading state.",
                            feature: .mockCurrentUserSessionProLoadingState,
                            currentValue: state.mockCurrentUserSessionProLoadingState,
                            navigatableStateHolder: viewModel,
                            onMockingRemoved: { [dependencies] in
                                Task.detached(priority: .userInitiated) { [dependencies] in
                                    try? await dependencies[singleton: .sessionProManager].refreshProState()
                                }
                            },
                            using: viewModel?.dependencies
                        )
                    }
                ),
                SessionCell.Info(
                    id: .mockCurrentUserSessionProOriginatingPlatform,
                    title: "Mocked Originating Platform",
                    subtitle: """
                    Force the current users Session Pro to have originated from a specific platform.
                    
                    <b>Current:</b> \(devValue: state.mockCurrentUserSessionProOriginatingPlatform)
                    
                    Note: This option will only be available if the users pro state has been mocked, there is already a mocked loading state, or the users pro state has been fetched via the "Refresh Pro State" action on this screen.
                    """,
                    trailingAccessory: .icon(.squarePen),
                    isEnabled: {
                        switch (state.mockCurrentUserSessionProLoadingState, state.mockCurrentUserSessionProBackendStatus, state.currentProStatus) {
                            case (.simulate, _, _), (_, .simulate, _), (_, _, .some): return true
                            default: return false
                        }
                    }(),
                    onTap: { [weak viewModel, dependencies = viewModel.dependencies] in
                        DeveloperSettingsViewModel.showModalForMockableState(
                            title: "Mocked Originating Platform",
                            explanation: "Force the current users Session Pro to have originated from a specific platform.",
                            feature: .mockCurrentUserSessionProOriginatingPlatform,
                            currentValue: state.mockCurrentUserSessionProOriginatingPlatform,
                            navigatableStateHolder: viewModel,
                            onMockingRemoved: { [dependencies] in
                                Task.detached(priority: .userInitiated) { [dependencies] in
                                    try? await dependencies[singleton: .sessionProManager].refreshProState()
                                }
                            },
                            using: viewModel?.dependencies
                        )
                    }
                ),
                SessionCell.Info(
                    id: .mockCurrentUserOriginatingAccount,
                    title: "Mocked Originating Account",
                    subtitle: """
                    Force the current users Session Pro to have originated from a specific account.
                    
                    <b>Current:</b> \(devValue: state.mockCurrentUserOriginatingAccount)
                    
                    Note: This option will only be available if the users pro state has been mocked, there is already a mocked loading state, or the users pro state has been fetched via the "Refresh Pro State" action on this screen.
                    """,
                    trailingAccessory: .icon(.squarePen),
                    isEnabled: {
                        switch (state.mockCurrentUserSessionProLoadingState, state.mockCurrentUserSessionProBackendStatus, state.currentProStatus) {
                            case (.simulate, _, _), (_, .simulate, _), (_, _, .some): return true
                            default: return false
                        }
                    }(),
                    onTap: { [weak viewModel, dependencies = viewModel.dependencies] in
                        DeveloperSettingsViewModel.showModalForMockableState(
                            title: "Mocked Originating Account",
                            explanation: "Force the current users Session Pro to have originated from a specific account.",
                            feature: .mockCurrentUserOriginatingAccount,
                            currentValue: state.mockCurrentUserOriginatingAccount,
                            navigatableStateHolder: viewModel,
                            onMockingRemoved: { [dependencies] in
                                Task.detached(priority: .userInitiated) { [dependencies] in
                                    try? await dependencies[singleton: .sessionProManager].refreshProState()
                                }
                            },
                            using: viewModel?.dependencies
                        )
                    }
                ),
                SessionCell.Info(
                    id: .mockCurrentUserAccessExpiryTimestamp,
                    title: "Mocked Access Expiry Date/Time",
                    subtitle: """
                    Specify a custom date/time that the users Session Pro should expire.
                    
                    <b>Current:</b> \(devValue: viewModel.dependencies[feature: .mockCurrentUserAccessExpiryTimestamp])
                    """,
                    trailingAccessory: .icon(.squarePen),
                    onTap: { [weak viewModel, dependencies = viewModel.dependencies] in
                        DeveloperSettingsViewModel.showModalForMockableDate(
                            title: "Mocked Access Expiry Date/Time",
                            explanation: "The custom date/time the users Session Pro should expire.",
                            feature: .mockCurrentUserAccessExpiryTimestamp,
                            navigatableStateHolder: viewModel,
                            using: dependencies
                        )
                    }
                ),
                SessionCell.Info(
                    id: .proBadgeEverywhere,
                    title: "Show the Pro Badge everywhere",
                    subtitle: """
                    Force the pro badge to show everywhere.
                    
                    <b>Note:</b> On the "Message Info" screen this will make the Pro Badge appear against the sender profile info, but the message feature pro badge will show based on the "Message Feature: Pro Badge" setting below.
                    """,
                    trailingAccessory: .toggle(
                        state.proBadgeEverywhere,
                        oldValue: previousState.proBadgeEverywhere
                    ),
                    onTap: { [dependencies = viewModel.dependencies] in
                        dependencies.set(
                            feature: .proBadgeEverywhere,
                            to: !state.proBadgeEverywhere
                        )
                    }
                ),
                SessionCell.Info(
                    id: .fakeAppleSubscriptionForDev,
                    title: "Fake the Apple Subscription for Pro Purchases",
                    subtitle: """
                    Apple subscriptions (even with Sandbox accounts) can't be tested on the iOS Simulator, to work around this the dev pro server allows "fake" transaction identifiers for the purposes of testing.
                    
                    This setting will bypass the AppStore section of the purchase flow and generate a fake transaction identifier to send to the Pro backend to create the purchase.
                    """,
                    trailingAccessory: .toggle(
                        state.fakeAppleSubscriptionForDev,
                        oldValue: previousState.fakeAppleSubscriptionForDev
                    ),
                    onTap: { [dependencies = viewModel.dependencies] in
                        dependencies.set(
                            feature: .fakeAppleSubscriptionForDev,
                            to: !state.fakeAppleSubscriptionForDev
                        )
                    }
                ),
                SessionCell.Info(
                    id: .forceMessageFeatureProBadge,
                    title: "Message Feature: Pro Badge",
                    subtitle: "Force all messages to show the \"Pro Badge\" feature.",
                    trailingAccessory: .toggle(
                        state.forceMessageFeatureProBadge,
                        oldValue: previousState.forceMessageFeatureProBadge
                    ),
                    onTap: { [dependencies = viewModel.dependencies] in
                        dependencies.set(
                            feature: .forceMessageFeatureProBadge,
                            to: !state.forceMessageFeatureProBadge
                        )
                    }
                ),
                SessionCell.Info(
                    id: .forceMessageFeatureLongMessage,
                    title: "Message Feature: Long Message",
                    subtitle: "Force all messages to show the \"Long Message\" feature.",
                    trailingAccessory: .toggle(
                        state.forceMessageFeatureLongMessage,
                        oldValue: previousState.forceMessageFeatureLongMessage
                    ),
                    onTap: { [dependencies = viewModel.dependencies] in
                        dependencies.set(
                            feature: .forceMessageFeatureLongMessage,
                            to: !state.forceMessageFeatureLongMessage
                        )
                    }
                ),
                SessionCell.Info(
                    id: .forceMessageFeatureAnimatedAvatar,
                    title: "Message Feature: Animated Avatar",
                    subtitle: "Force all messages to show the \"Animated Avatar\" feature.",
                    trailingAccessory: .toggle(
                        state.forceMessageFeatureAnimatedAvatar,
                        oldValue: previousState.forceMessageFeatureAnimatedAvatar
                    ),
                    onTap: { [dependencies = viewModel.dependencies] in
                        dependencies.set(
                            feature: .forceMessageFeatureAnimatedAvatar,
                            to: !state.forceMessageFeatureAnimatedAvatar
                        )
                    }
                )
            ]
        )
        
        // MARK: - Actual Pro Transactions and APIs
        
        let purchaseStatus: String = {
            switch (state.purchaseError, state.purchaseStatus) {
                case (.some(let error), _): return "<error>\(error)</error>"
                case (_, .some(let status)): return "<span>\(status)</span>"
                case (.none, .none): return "<disabled>None</disabled>"
            }
        }()
        let productName: String = (
            state.purchasedProduct.map { "<span>\($0.displayName)</span>" } ??
            "<disabled>N/A</disabled>"
        )
        let transactionId: String = (
            state.purchaseTransaction.map { "<span>\($0.id)</span>" } ??
            "<disabled>N/A</disabled>"
        )
        let refundStatus: String = {
            switch state.refundRequestStatus {
                case .success: return "<span>Success (Does not mean approved)</span>"
                case .userCancelled: return "<span>User Cancelled</span>"
                case .none: return "<disabled>N/A</disabled>"
                @unknown default: return "<disabled>N/A</disabled>"
            }
        }()
        let submittedTransactionStatus: String = {
            switch (state.submittedTransactionStatus, state.submittedTransactionErrored) {
                case (.some(let error), true): return "<error>\(error)</error>"
                case (.some(let status), false): return "<span>\(status)</span>"
                case (.none, _): return "<disabled>None</disabled>"
            }
        }()
        let currentProStatus: String = {
            switch (state.currentProStatus, state.currentProStatusErrored) {
                case (.some(let error), true): return "<error>\(error)</error>"
                case (.some(let status), false): return "<span>\(status)</span>"
                case (.none, _): return "<disabled>Unknown</disabled>"
            }
        }()
        let subscriptions: SectionModel = SectionModel(
            model: .subscriptions,
            elements: [
                SessionCell.Info(
                    id: .purchaseProSubscription,
                    title: "Purchase Subscription",
                    subtitle: """
                    Purchase Session Pro via the App Store.
                    
                    <b>Notes:</b>
                    • This only works on a real device (and some old iOS versions don't seem to support Sandbox accounts (eg. iOS 16).
                    • This subscription isn't connected to the Session account by default (they are for testing purposes)
                    
                    <b>Status:</b> \(purchaseStatus)
                    <b>Product Name:</b> \(productName)
                    <b>TransactionId:</b> \(transactionId)
                    """,
                    trailingAccessory: .highlightingBackgroundLabel(title: "Purchase"),
                    onTap: { [weak viewModel] in
                        Task { await viewModel?.purchaseSubscription(currentProduct: state.purchasedProduct) }
                    }
                ),
                SessionCell.Info(
                    id: .manageProSubscriptions,
                    title: "Manage Subscriptions",
                    subtitle: """
                    Manage subscriptions for Session Pro via the App Store.
                    
                    <b>Note:</b> You must purchase a Session Pro subscription before you can manage it.
                    """,
                    trailingAccessory: .highlightingBackgroundLabel(title: "Manage"),
                    onTap: { [weak viewModel] in
                        Task { await viewModel?.manageSubscriptions() }
                    }
                ),
                SessionCell.Info(
                    id: .restoreProSubscription,
                    title: "Restore Subscriptions",
                    subtitle: """
                    Restore a Session Pro subscription via the App Store.
                    """,
                    trailingAccessory: .highlightingBackgroundLabel(title: "Restore"),
                    onTap: { [weak viewModel] in
                        Task { await viewModel?.restoreSubscriptions() }
                    }
                ),
                SessionCell.Info(
                    id: .requestRefund,
                    title: "Request Refund",
                    subtitle: """
                    Request a refund for a Session Pro subscription via the App Store.
                    
                    <b>Status: </b>\(refundStatus)
                    """,
                    trailingAccessory: .highlightingBackgroundLabel(title: "Request"),
                    isEnabled: (state.purchaseTransaction != nil),
                    onTap: { [weak viewModel] in
                        Task { await viewModel?.requestRefund() }
                    }
                )
            ]
        )
        
        let proBackend: SectionModel = SectionModel(
            model: .proBackend,
            elements: [
                SessionCell.Info(
                    id: .submitPurchaseToProBackend,
                    title: "Submit Purchase to Pro Backend",
                    subtitle: """
                    Submit a purchase to the Session Pro Backend.
                    
                    <b>Status: </b>\(submittedTransactionStatus)
                    """,
                    trailingAccessory: .highlightingBackgroundLabel(title: "Submit"),
                    isEnabled: (
                        state.purchaseTransaction != nil ||
                        state.fakeAppleSubscriptionForDev
                    ),
                    onTap: { [weak viewModel] in
                        Task { await viewModel?.submitTransactionToProBackend() }
                    }
                ),
                SessionCell.Info(
                    id: .refreshProState,
                    title: "Refresh Pro State",
                    subtitle: """
                    Manually trigger a refresh of the users Pro state.
                    
                    <b>Status: </b>\(currentProStatus)
                    """,
                    trailingAccessory: .highlightingBackgroundLabel(title: "Refresh"),
                    onTap: { [weak viewModel] in
                        Task { await viewModel?.refreshProState() }
                    }
                ),
                SessionCell.Info(
                    id: .resetRevocationListTicket,
                    title: "Reset Revocation List Ticket",
                    subtitle: """
                    Reset the revocation list ticket (this will result in the revocation list being refetched from the beginning).
                    
                    <b>Current Ticket: </b>\(state.currentRevocationListTicket)
                    """,
                    trailingAccessory: .highlightingBackgroundLabel(title: "Reset"),
                    onTap: { [weak viewModel] in
                        Task { await viewModel?.resetProRevocationListTicket() }
                    }
                ),
                SessionCell.Info(
                    id: .removeProFromUserConfig,
                    title: "Remove Pro From User Config",
                    subtitle: """
                    Remove the cached pro state from the configs (this will mean the local device doesn't know that the user has pro on restart).
                    """,
                    trailingAccessory: .highlightingBackgroundLabel(title: "Remove"),
                    onTap: { [weak viewModel] in
                        Task { await viewModel?.removeProFromUserConfig() }
                    }
                )
            ]
        )
        
        return [general, features, subscriptions, proBackend]
    }
    
    // MARK: - Functions
    
    public static func disableDeveloperMode(using dependencies: Dependencies) {
        let features: [FeatureConfig<Bool>] = [
            .sessionProEnabled,
            .proBadgeEverywhere,
            .fakeAppleSubscriptionForDev,
            .forceMessageFeatureProBadge,
            .forceMessageFeatureLongMessage,
            .forceMessageFeatureAnimatedAvatar,
        ]
        
        features.forEach { feature in
            guard dependencies.hasSet(feature: feature) else { return }
            
            dependencies.reset(feature: feature)
        }
        
        if dependencies.hasSet(feature: .mockCurrentUserSessionProBackendStatus) {
            dependencies.reset(feature: .mockCurrentUserSessionProBackendStatus)
        }
        
        if dependencies.hasSet(feature: .mockCurrentUserSessionProLoadingState) {
            dependencies.reset(feature: .mockCurrentUserSessionProLoadingState)
        }
    }
    
    // MARK: - Internal Functions
    
    private func updateSessionProEnabled(current: Bool) {
        dependencies.set(feature: .sessionProEnabled, to: !current)
        
        if dependencies.hasSet(feature: .proBadgeEverywhere) {
            dependencies.reset(feature: .proBadgeEverywhere)
        }
        
        if dependencies.hasSet(feature: .mockCurrentUserSessionProBackendStatus) {
            dependencies.reset(feature: .mockCurrentUserSessionProBackendStatus)
        }
    }
    
    // MARK: - Pro Requests
    
    private func purchaseSubscription(currentProduct: Product?) async {
        do {
            let products: [Product] = try await Product.products(for: [
                "com.getsession.org.pro_sub_1_month",
                "com.getsession.org.pro_sub_3_months",
                "com.getsession.org.pro_sub_12_months"
            ])
            
            await MainActor.run {
                self.transitionToScreen(
                    ConfirmationModal(
                        info: ConfirmationModal.Info(
                            title: "Purchase",
                            body: .radio(
                                explanation: ThemedAttributedString(
                                    string: "Please select the subscription to purchaase."
                                ),
                                warning: nil,
                                options: products.sorted().map { product in
                                    ConfirmationModal.Info.Body.RadioOptionInfo(
                                        title: "\(product.displayName), price: \(product.displayPrice)",
                                        descriptionText: ThemedAttributedString(
                                            stringWithHTMLTags: product.description,
                                            font: RadioButton.descriptionFont
                                        ),
                                        enabled: true,
                                        selected: currentProduct?.id == product.id
                                    )
                                }
                            ),
                            confirmTitle: "select".localized(),
                            cancelStyle: .alert_text,
                            onConfirm: { [weak self] modal in
                                let selectedProduct: Product? = {
                                    switch modal.info.body {
                                        case .radio(_, _, let options):
                                            return options
                                                .enumerated()
                                                .first(where: { _, value in value.selected })
                                                .map { index, _ in
                                                    guard index >= 0 && (index - 1) < products.count else {
                                                        return nil
                                                    }
                                                    
                                                    return products[index]
                                                }
                                            
                                        default: return nil
                                    }
                                }()
                                
                                if let product: Product = selectedProduct {
                                    Task(priority: .userInitiated) { [weak self] in
                                        await self?.confirmPurchase(products: products, product: product)
                                    }
                                }
                            }
                        )
                    ),
                    transitionType: .present
                )
            }
        }
        catch {
            Log.error("[DevSettings] Unable to purchase subscription due to error: \(error)")
            dependencies.notifyAsync(
                key: .updateScreen(DeveloperSettingsProViewModel.self),
                value: DeveloperSettingsProEvent.purchasedProduct([], nil, "Failed: \(error)", nil, nil)
            )
        }
    }
    
    private func confirmPurchase(products: [Product], product: Product) async {
        do {
            let result = try await product.purchase()
            
            switch result {
                case .success(let verificationResult):
                    let transaction = try verificationResult.payloadValue
                    dependencies.notifyAsync(
                        key: .updateScreen(DeveloperSettingsProViewModel.self),
                        value: DeveloperSettingsProEvent.purchasedProduct(products, product, nil, "Successful", transaction)
                    )
                    await transaction.finish()
                    
                case .pending:
                    dependencies.notifyAsync(
                        key: .updateScreen(DeveloperSettingsProViewModel.self),
                        value: DeveloperSettingsProEvent.purchasedProduct(products, product, nil, "Pending approval", nil)
                    )
                
                case .userCancelled:
                    dependencies.notifyAsync(
                        key: .updateScreen(DeveloperSettingsProViewModel.self),
                        value: DeveloperSettingsProEvent.purchasedProduct(products, product, nil, "User cancelled", nil)
                    )
                    
                @unknown default:
                    dependencies.notifyAsync(
                        key: .updateScreen(DeveloperSettingsProViewModel.self),
                        value: DeveloperSettingsProEvent.purchasedProduct(products, product, "Unknown Error", nil, nil)
                    )
            }

        }
        catch {
            Log.error("[DevSettings] Unable to purchase subscription due to error: \(error)")
            dependencies.notifyAsync(
                key: .updateScreen(DeveloperSettingsProViewModel.self),
                value: DeveloperSettingsProEvent.purchasedProduct([], nil, "Failed: \(error)", nil, nil)
            )
        }
    }
    
    private func manageSubscriptions() async {
        guard let scene: UIWindowScene = await UIApplication.shared.connectedScenes.first as? UIWindowScene else {
            return Log.error("[DevSettings] Unable to show manage subscriptions: Unable to get UIWindowScene")
        }
        
        do {
            try await AppStore.showManageSubscriptions(in: scene)
        }
        catch {
            Log.error("[DevSettings] Unable to show manage subscriptions: \(error)")
        }
    }
    
    private func restoreSubscriptions() async {
        do {
            try await AppStore.sync()
        }
        catch {
            Log.error("[DevSettings] Unable to show manage subscriptions: \(error)")
        }
    }
    
    private func requestRefund() async {
        guard let transaction: Transaction = await internalState.purchaseTransaction else { return }
        guard let scene: UIWindowScene = await UIApplication.shared.connectedScenes.first as? UIWindowScene else {
            return Log.error("[DevSettings] Unable to show manage subscriptions: Unable to get UIWindowScene")
        }
        
        do {
            let result = try await transaction.beginRefundRequest(in: scene)
            
            dependencies.notifyAsync(
                key: .updateScreen(DeveloperSettingsProViewModel.self),
                value: DeveloperSettingsProEvent.refundTransaction(result)
            )
        }
        catch {
            Log.error("[DevSettings] Unable to request refund: \(error)")
        }
    }
    
    private func submitTransactionToProBackend() async {
        do {
            let transactionId: String = try await {
                guard await internalState.fakeAppleSubscriptionForDev else {
                    guard let transaction: Transaction = await internalState.purchaseTransaction else {
                        throw SessionProError.transactionNotFound
                    }
                    
                    return "\(transaction.id)"
                }
                
                let bytes: [UInt8] = try dependencies[singleton: .crypto].tryGenerate(.randomBytes(8))
                return "DEV.\(bytes.toHexString())"
            }()
            
            try await dependencies[singleton: .sessionProManager].addProPayment(transactionId: transactionId)
            
            dependencies.notifyAsync(
                key: .updateScreen(DeveloperSettingsProViewModel.self),
                value: DeveloperSettingsProEvent.submittedTransaction("Success", false)
            )
        }
        catch {
            Log.error("[DevSettings] Tranasction submission failed: \(error)")
            dependencies.notifyAsync(
                key: .updateScreen(DeveloperSettingsProViewModel.self),
                value: DeveloperSettingsProEvent.submittedTransaction("Failed: \(error)", true)
            )
        }
    }
    
    private func refreshProState() async {
        do {
            try await dependencies[singleton: .sessionProManager].refreshProState()
            let state: SessionPro.State = dependencies[singleton: .sessionProManager].currentUserCurrentProState
            
            dependencies.notifyAsync(
                key: .updateScreen(DeveloperSettingsProViewModel.self),
                value: DeveloperSettingsProEvent.currentProStatus("\(state.status)", false)
            )
        }
        catch {
            Log.error("[DevSettings] Refresh pro state failed: \(error)")
            dependencies.notifyAsync(
                key: .updateScreen(DeveloperSettingsProViewModel.self),
                value: DeveloperSettingsProEvent.currentProStatus("Error: \(error)", true)
            )
        }
    }
    
    private func resetProRevocationListTicket() async {
        do {
            try await dependencies[singleton: .storage].writeAsync { db in
                db[.proRevocationsTicket] = nil
            }
            
            await dependencies.notify(
                key: .proRevocationListUpdated,
                value: Array<Network.SessionPro.RevocationItem>()
            )
        }
        catch {
            Log.error("[DevSettings] Reset pro revocation list failed failed: \(error)")
        }
    }
    
    private func removeProFromUserConfig() async {
        try? await dependencies[singleton: .storage].writeAsync { [dependencies] db in
            try dependencies.mutate(cache: .libSession) { cache in
                try cache.performAndPushChange(db, for: .userProfile) { _ in
                    cache.removeProConfig()
                }
            }
        }
    }
}
