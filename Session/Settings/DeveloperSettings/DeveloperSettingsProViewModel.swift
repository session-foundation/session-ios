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
        case features
        
        var title: String? {
            switch self {
                case .general: return nil
                case .subscriptions: return "Subscriptions"
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
        
        case proStatus
        case proBadgeEverywhere

        case forceMessageFeatureProBadge
        case forceMessageFeatureLongMessage
        case forceMessageFeatureAnimatedAvatar
        
        case purchaseProSubscription
        case manageProSubscriptions
        case restoreProSubscription
        case requestRefund
        case submitPurchaseToProBackend
        case refreshProStatus
        
        // MARK: - Conformance
        
        public typealias DifferenceIdentifier = String
        
        public var differenceIdentifier: String {
            switch self {
                case .enableSessionPro: return "enableSessionPro"
                    
                case .proStatus: return "proStatus"
                case .proBadgeEverywhere: return "proBadgeEverywhere"
                
                case .forceMessageFeatureProBadge: return "forceMessageFeatureProBadge"
                case .forceMessageFeatureLongMessage: return "forceMessageFeatureLongMessage"
                case .forceMessageFeatureAnimatedAvatar: return "forceMessageFeatureAnimatedAvatar"
                    
                case .purchaseProSubscription: return "purchaseProSubscription"
                case .manageProSubscriptions: return "manageProSubscriptions"
                case .restoreProSubscription: return "restoreProSubscription"
                case .requestRefund: return "requestRefund"
                case .submitPurchaseToProBackend: return "submitPurchaseToProBackend"
                case .refreshProStatus: return "refreshProStatus"
            }
        }
        
        public func isContentEqual(to source: TableItem) -> Bool {
            self.differenceIdentifier == source.differenceIdentifier
        }
        
        public static var allCases: [TableItem] {
            var result: [TableItem] = []
            switch TableItem.enableSessionPro {
                case .enableSessionPro: result.append(.enableSessionPro); fallthrough
                    
                case .proStatus: result.append(.proStatus); fallthrough
                case .proBadgeEverywhere: result.append(.proBadgeEverywhere); fallthrough

                case .forceMessageFeatureProBadge: result.append(.forceMessageFeatureProBadge); fallthrough
                case .forceMessageFeatureLongMessage: result.append(.forceMessageFeatureLongMessage); fallthrough
                case .forceMessageFeatureAnimatedAvatar: result.append(.forceMessageFeatureAnimatedAvatar)
                    
                case .purchaseProSubscription: result.append(.purchaseProSubscription); fallthrough
                case .manageProSubscriptions: result.append(.manageProSubscriptions); fallthrough
                case .restoreProSubscription: result.append(.restoreProSubscription); fallthrough
                case .requestRefund: result.append(.requestRefund); fallthrough
                case .submitPurchaseToProBackend: result.append(.submitPurchaseToProBackend); fallthrough
                case .refreshProStatus: result.append(.refreshProStatus)
            }
            
            return result
        }
    }
    
    public enum DeveloperSettingsProEvent: Hashable {
        case purchasedProduct([Product], Product?, String?, String?, Transaction?)
        case refundTransaction(Transaction.RefundRequestStatus)
        case submittedTranasction(KeyPair?, KeyPair?, String?, Bool)
        case currentProStatus(String?, Bool)
    }
    
    // MARK: - Content
    
    public struct State: Equatable, ObservableKeyProvider {
        let sessionProEnabled: Bool
        
        let mockCurrentUserSessionProBackendStatus: Network.SessionPro.BackendUserProStatus?
        let proBadgeEverywhere: Bool

        let forceMessageFeatureProBadge: Bool
        let forceMessageFeatureLongMessage: Bool
        let forceMessageFeatureAnimatedAvatar: Bool
        
        let products: [Product]
        let purchasedProduct: Product?
        let purchaseError: String?
        let purchaseStatus: String?
        let purchaseTransaction: Transaction?
        let refundRequestStatus: Transaction.RefundRequestStatus?
        
        let submittedTransactionMasterKeyPair: KeyPair?
        let submittedTransactionRotatingKeyPair: KeyPair?
        let submittedTransactionStatus: String?
        let submittedTransactionErrored: Bool
        
        let currentProStatus: String?
        let currentProStatusErrored: Bool
        
        @MainActor public func sections(viewModel: DeveloperSettingsProViewModel, previousState: State) -> [SectionModel] {
            DeveloperSettingsProViewModel.sections(
                state: self,
                previousState: previousState,
                viewModel: viewModel
            )
        }
        
        public let observedKeys: Set<ObservableKey> = [
            .feature(.sessionProEnabled),
            .feature(.mockCurrentUserSessionProBackendStatus),
            .feature(.proBadgeEverywhere),
            .feature(.forceMessageFeatureProBadge),
            .feature(.forceMessageFeatureLongMessage),
            .feature(.forceMessageFeatureAnimatedAvatar),
            .updateScreen(DeveloperSettingsProViewModel.self)
        ]
        
        static func initialState(using dependencies: Dependencies) -> State {
            return State(
                sessionProEnabled: dependencies[feature: .sessionProEnabled],
                
                mockCurrentUserSessionProBackendStatus: dependencies[feature: .mockCurrentUserSessionProBackendStatus],
                proBadgeEverywhere: dependencies[feature: .proBadgeEverywhere],

                forceMessageFeatureProBadge: dependencies[feature: .forceMessageFeatureProBadge],
                forceMessageFeatureLongMessage: dependencies[feature: .forceMessageFeatureLongMessage],
                forceMessageFeatureAnimatedAvatar: dependencies[feature: .forceMessageFeatureAnimatedAvatar],
                
                products: [],
                purchasedProduct: nil,
                purchaseError: nil,
                purchaseStatus: nil,
                purchaseTransaction: nil,
                refundRequestStatus: nil,
                
                submittedTransactionMasterKeyPair: nil,
                submittedTransactionRotatingKeyPair: nil,
                submittedTransactionStatus: nil,
                submittedTransactionErrored: false,
                
                currentProStatus: nil,
                currentProStatusErrored: false
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
        var submittedTransactionMasterKeyPair: KeyPair? = previousState.submittedTransactionMasterKeyPair
        var submittedTransactionRotatingKeyPair: KeyPair? = previousState.submittedTransactionRotatingKeyPair
        var submittedTransactionStatus: String? = previousState.submittedTransactionStatus
        var submittedTransactionErrored: Bool = previousState.submittedTransactionErrored
        
        events.forEach { event in
            guard let eventValue: DeveloperSettingsProEvent = event.value as? DeveloperSettingsProEvent else { return }
            
            switch eventValue {
                case .purchasedProduct(let receivedProducts, let purchased, let error, let status, let transaction):
                    products = receivedProducts
                    purchasedProduct = purchased
                    purchaseError = error
                    purchaseStatus = status
                    purchaseTransaction = transaction
                    
                case .refundTransaction(let status):
                    refundRequestStatus = status
                    
                case .submittedTranasction(let masterKeyPair, let rotatingKeyPair, let status, let errored):
                    submittedTransactionMasterKeyPair = masterKeyPair
                    submittedTransactionRotatingKeyPair = rotatingKeyPair
                    submittedTransactionStatus = status
                    submittedTransactionErrored = errored
                    
                case .currentProStatus(let status, let errored):
                    currentProStatus = status
                    currentProStatusErrored = errored
            }
        }
        
        return State(
            sessionProEnabled: dependencies[feature: .sessionProEnabled],
            mockCurrentUserSessionProBackendStatus: dependencies[feature: .mockCurrentUserSessionProBackendStatus],
            proBadgeEverywhere: dependencies[feature: .proBadgeEverywhere],
            forceMessageFeatureProBadge: dependencies[feature: .forceMessageFeatureProBadge],
            forceMessageFeatureLongMessage: dependencies[feature: .forceMessageFeatureLongMessage],
            forceMessageFeatureAnimatedAvatar: dependencies[feature: .forceMessageFeatureAnimatedAvatar],
            products: products,
            purchasedProduct: purchasedProduct,
            purchaseError: purchaseError,
            purchaseStatus: purchaseStatus,
            purchaseTransaction: purchaseTransaction,
            refundRequestStatus: refundRequestStatus,
            submittedTransactionMasterKeyPair: submittedTransactionMasterKeyPair,
            submittedTransactionRotatingKeyPair: submittedTransactionRotatingKeyPair,
            submittedTransactionStatus: submittedTransactionStatus,
            submittedTransactionErrored: submittedTransactionErrored,
            currentProStatus: currentProStatus,
            currentProStatusErrored: currentProStatusErrored
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
        
        let mockedProStatus: String = {
            switch state.mockCurrentUserSessionProBackendStatus {
                case .some(let status): return "<span>\(status)</span>"
                case .none: return "<disabled>None</disabled>"
            }
        }()
        
        var features: SectionModel = SectionModel(
            model: .features,
            elements: [
                SessionCell.Info(
                    id: .proStatus,
                    title: "Mocked Pro Status",
                    subtitle: """
                    Force the current users Session Pro to a specific status locally.
                    
                    <b>Current:</b> \(mockedProStatus)
                    """,
                    trailingAccessory: .icon(.squarePen),
                    onTap: { [weak viewModel] in
                        viewModel?.showMockProStatusModal(currentStatus: state.mockCurrentUserSessionProBackendStatus)
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
        let rotatingPubkey: String = (
            (state.submittedTransactionRotatingKeyPair?.publicKey).map { "<span>\($0.toHexString())</span>" } ??
            "<disabled>N/A</disabled>"
        )
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
                    
                    <b>Note:</b> This only works on a real device (and some old iOS versions don't seem to support Sandbox accounts (eg. iOS 16).
                    
                    <b>Status:</b> \(purchaseStatus)
                    <b>Product Name:</b> \(productName)
                    <b>TransactionId:</b> \(transactionId)
                    """,
                    trailingAccessory: .highlightingBackgroundLabel(title: "Purchase"),
                    onTap: { [weak viewModel] in
                        Task { await viewModel?.purchaseSubscription() }
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
                ),
                SessionCell.Info(
                    id: .submitPurchaseToProBackend,
                    title: "Submit Purchase to Pro Backend",
                    subtitle: """
                    Submit a purchase to the Session Pro Backend.
                    
                    <b>Rotating Pubkey: </b>\(rotatingPubkey)
                    <b>Status: </b>\(submittedTransactionStatus)
                    """,
                    trailingAccessory: .highlightingBackgroundLabel(title: "Submit"),
                    isEnabled: (state.purchaseTransaction != nil),
                    onTap: { [weak viewModel] in
                        Task { await viewModel?.submitTransactionToProBackend() }
                    }
                ),
                SessionCell.Info(
                    id: .refreshProStatus,
                    title: "Refresh Pro Status",
                    subtitle: """
                    Refresh the pro status.
                    
                    <b>Status: </b>\(currentProStatus)
                    """,
                    trailingAccessory: .highlightingBackgroundLabel(title: "Refresh"),
                    isEnabled: (state.submittedTransactionMasterKeyPair != nil),
                    onTap: { [weak viewModel] in
                        Task { await viewModel?.refreshProStatus() }
                    }
                )
            ]
        )
        
        return [general, features, subscriptions]
    }
    
    // MARK: - Functions
    
    public static func disableDeveloperMode(using dependencies: Dependencies) {
        let features: [FeatureConfig<Bool>] = [
            .sessionProEnabled,
            .proBadgeEverywhere,
            .forceMessageFeatureProBadge,
            .forceMessageFeatureLongMessage,
            .forceMessageFeatureAnimatedAvatar,
        ]
        
        features.forEach { feature in
            guard dependencies.hasSet(feature: feature) else { return }
            
            dependencies.set(feature: feature, to: nil)
        }
        
        if dependencies.hasSet(feature: .mockCurrentUserSessionProBackendStatus) {
            dependencies.set(feature: .mockCurrentUserSessionProBackendStatus, to: nil)
        }
    }
    
    // MARK: - Internal Functions
    
    private func updateSessionProEnabled(current: Bool) {
        dependencies.set(feature: .sessionProEnabled, to: !current)
        
        if dependencies.hasSet(feature: .mockCurrentUserSessionProBackendStatus) {
            dependencies.set(feature: .mockCurrentUserSessionProBackendStatus, to: nil)
        }
        
        if dependencies.hasSet(feature: .proBadgeEverywhere) {
            dependencies.set(feature: .proBadgeEverywhere, to: nil)
        }
    }
    
    private func showMockProStatusModal(currentStatus: Network.SessionPro.BackendUserProStatus?) {
        self.transitionToScreen(
            ConfirmationModal(
                info: ConfirmationModal.Info(
                    title: "Mocked Pro Status",
                    body: .radio(
                        explanation: ThemedAttributedString(
                            string: "Force the current users Session Pro to a specific status locally."
                        ),
                        warning: nil,
                        options: {
                            return ([nil] + Network.SessionPro.BackendUserProStatus.allCases).map { status in
                                ConfirmationModal.Info.Body.RadioOptionInfo(
                                    title: status.title,
                                    descriptionText: status.subtitle.map {
                                        ThemedAttributedString(
                                            stringWithHTMLTags: $0,
                                            font: RadioButton.descriptionFont
                                        )
                                    },
                                    enabled: true,
                                    selected: currentStatus == status
                                )
                            }
                        }()
                    ),
                    confirmTitle: "select".localized(),
                    cancelStyle: .alert_text,
                    onConfirm: { [dependencies] modal in
                        let selectedStatus: Network.SessionPro.BackendUserProStatus? = {
                            switch modal.info.body {
                                case .radio(_, _, let options):
                                    return options
                                        .enumerated()
                                        .first(where: { _, value in value.selected })
                                        .map { index, _ in
                                            let targetIndex: Int = (index - 1)
                                            
                                            guard targetIndex >= 0 && (targetIndex - 1) < Network.SessionPro.BackendUserProStatus.allCases.count else {
                                                return nil
                                            }
                                            
                                            return Network.SessionPro.BackendUserProStatus.allCases[targetIndex]
                                        }
                                
                                default: return nil
                            }
                        }()
                        
                        dependencies.set(feature: .mockCurrentUserSessionProBackendStatus, to: selectedStatus)
                    }
                )
            ),
            transitionType: .present
        )
    }
    
    // MARK: - Pro Requests
    
    private func purchaseSubscription() async {
        do {
            let products: [Product] = try await Product.products(for: ["com.getsession.org.pro_sub"])
            
            guard let product: Product = products.first else {
                Log.error("[DevSettings] Unable to purchase subscription due to error: No products found")
                dependencies.notifyAsync(
                    key: .updateScreen(DeveloperSettingsProViewModel.self),
                    value: DeveloperSettingsProEvent.purchasedProduct([], nil, "No products found", nil, nil)
                )
                return
            }
            
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
        guard let scene: UIWindowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene else {
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
        guard let scene: UIWindowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene else {
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
        guard let transaction: Transaction = await internalState.purchaseTransaction else { return }
        
        do {
            let masterKeyPair: KeyPair = try dependencies[singleton: .crypto].tryGenerate(.ed25519KeyPair())
            let rotatingKeyPair: KeyPair = try dependencies[singleton: .crypto].tryGenerate(.ed25519KeyPair())
            let request = try? Network.SessionPro.addProPaymentOrGetProProof(
                transactionId: "\(transaction.id)",
                masterKeyPair: masterKeyPair,
                rotatingKeyPair: rotatingKeyPair,
                using: dependencies
            )
            // FIXME: Make this async/await when the refactored networking is merged
            let response = try await request
                .send(using: dependencies)
                .values
                .first(where: { _ in true })?.1 ?? { throw NetworkError.invalidResponse }()
            
            guard response.header.errors.isEmpty else {
                Log.error("[DevSettings] Tranasction submission failed: \(response.header.errors[0])")
                dependencies.notifyAsync(
                    key: .updateScreen(DeveloperSettingsProViewModel.self),
                    value: DeveloperSettingsProEvent.submittedTranasction(
                        masterKeyPair,
                        rotatingKeyPair,
                        "Failed: \(response.header.errors[0])",
                        true
                    )
                )
                return
            }
            
            dependencies.notifyAsync(
                key: .updateScreen(DeveloperSettingsProViewModel.self),
                value: DeveloperSettingsProEvent.submittedTranasction(masterKeyPair, rotatingKeyPair, "Success", false)
            )
        }
        catch {
            Log.error("[DevSettings] Tranasction submission failed: \(error)")
            dependencies.notifyAsync(
                key: .updateScreen(DeveloperSettingsProViewModel.self),
                value: DeveloperSettingsProEvent.submittedTranasction(nil, nil, "Failed: \(error)", true)
            )
        }
    }
    
    private func refreshProStatus() async {
        guard let masterKeyPair: KeyPair = await internalState.submittedTransactionMasterKeyPair else { return }
        
        do {
            let request = try? Network.SessionPro.getProStatus(
                masterKeyPair: masterKeyPair,
                using: dependencies
            )
            // FIXME: Make this async/await when the refactored networking is merged
            let response = try await request
                .send(using: dependencies)
                .values
                .first(where: { _ in true })?.1 ?? { throw NetworkError.invalidResponse }()
            
            guard response.header.errors.isEmpty else {
                Log.error("[DevSettings] Refresh pro status failed: \(response.header.errors[0])")
                dependencies.notifyAsync(
                    key: .updateScreen(DeveloperSettingsProViewModel.self),
                    value: DeveloperSettingsProEvent.currentProStatus(
                        "Error: \(response.header.errors[0])",
                        true
                    )
                )
                return
            }
            
            dependencies.notifyAsync(
                key: .updateScreen(DeveloperSettingsProViewModel.self),
                value: DeveloperSettingsProEvent.currentProStatus("\(response.status)", false)
            )
        }
        catch {
            Log.error("[DevSettings] Refresh pro status failed: \(error)")
            dependencies.notifyAsync(
                key: .updateScreen(DeveloperSettingsProViewModel.self),
                value: DeveloperSettingsProEvent.currentProStatus("Error: \(error)", true)
            )
        }
    }
}
