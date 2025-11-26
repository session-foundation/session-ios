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
        
        case purchaseProSubscription
        case manageProSubscriptions
        case restoreProSubscription
        case requestRefund
        
        case proStatus
        case proIncomingMessages
        
        // MARK: - Conformance
        
        public typealias DifferenceIdentifier = String
        
        public var differenceIdentifier: String {
            switch self {
                case .enableSessionPro: return "enableSessionPro"
                    
                case .purchaseProSubscription: return "purchaseProSubscription"
                case .manageProSubscriptions: return "manageProSubscriptions"
                case .restoreProSubscription: return "restoreProSubscription"
                case .requestRefund: return "requestRefund"
                    
                case .proStatus: return "proStatus"
                case .proIncomingMessages: return "proIncomingMessages"
            }
        }
        
        public func isContentEqual(to source: TableItem) -> Bool {
            self.differenceIdentifier == source.differenceIdentifier
        }
        
        public static var allCases: [TableItem] {
            var result: [TableItem] = []
            switch TableItem.enableSessionPro {
                case .enableSessionPro: result.append(.enableSessionPro); fallthrough
                    
                case .purchaseProSubscription: result.append(.purchaseProSubscription); fallthrough
                case .manageProSubscriptions: result.append(.manageProSubscriptions); fallthrough
                case .restoreProSubscription: result.append(.restoreProSubscription); fallthrough
                case .requestRefund: result.append(.requestRefund); fallthrough
                    
                case .proStatus: result.append(.proStatus); fallthrough
                case .proIncomingMessages: result.append(.proIncomingMessages)
            }
            
            return result
        }
    }
    
    public enum DeveloperSettingsProEvent: Hashable {
        case purchasedProduct([Product], Product?, String?, String?, Transaction?)
        case refundTransaction(Transaction.RefundRequestStatus)
    }
    
    // MARK: - Content
    
    public struct State: Equatable, ObservableKeyProvider {
        let sessionProEnabled: Bool
        
        let products: [Product]
        let purchasedProduct: Product?
        let purchaseError: String?
        let purchaseStatus: String?
        let purchaseTransaction: Transaction?
        let refundRequestStatus: Transaction.RefundRequestStatus?
        
        let mockCurrentUserSessionPro: Bool
        let treatAllIncomingMessagesAsProMessages: Bool
        
        @MainActor public func sections(viewModel: DeveloperSettingsProViewModel, previousState: State) -> [SectionModel] {
            DeveloperSettingsProViewModel.sections(
                state: self,
                previousState: previousState,
                viewModel: viewModel
            )
        }
        
        public let observedKeys: Set<ObservableKey> = [
            .feature(.sessionProEnabled),
            .updateScreen(DeveloperSettingsProViewModel.self),
            .feature(.mockCurrentUserSessionPro),
            .feature(.treatAllIncomingMessagesAsProMessages)
        ]
        
        static func initialState(using dependencies: Dependencies) -> State {
            return State(
                sessionProEnabled: dependencies[feature: .sessionProEnabled],
                
                products: [],
                purchasedProduct: nil,
                purchaseError: nil,
                purchaseStatus: nil,
                purchaseTransaction: nil,
                refundRequestStatus: nil,
                
                mockCurrentUserSessionPro: dependencies[feature: .mockCurrentUserSessionPro],
                treatAllIncomingMessagesAsProMessages: dependencies[feature: .treatAllIncomingMessagesAsProMessages]
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
        var products: [Product] = previousState.products
        var purchasedProduct: Product? = previousState.purchasedProduct
        var purchaseError: String? = previousState.purchaseError
        var purchaseStatus: String? = previousState.purchaseStatus
        var purchaseTransaction: Transaction? = previousState.purchaseTransaction
        var refundRequestStatus: Transaction.RefundRequestStatus? = previousState.refundRequestStatus
        
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
            }
        }
        
        return State(
            sessionProEnabled: dependencies[feature: .sessionProEnabled],
            products: products,
            purchasedProduct: purchasedProduct,
            purchaseError: purchaseError,
            purchaseStatus: purchaseStatus,
            purchaseTransaction: purchaseTransaction,
            refundRequestStatus: refundRequestStatus,
            mockCurrentUserSessionPro: dependencies[feature: .mockCurrentUserSessionPro],
            treatAllIncomingMessagesAsProMessages: dependencies[feature: .treatAllIncomingMessagesAsProMessages]
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
        let subscriptions: SectionModel = SectionModel(
            model: .subscriptions,
            elements: [
                SessionCell.Info(
                    id: .purchaseProSubscription,
                    title: "Purchase Subscription",
                    subtitle: """
                    Purchase Session Pro via the App Store.
                    
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
                    
                    <b>Status:</b>\(refundStatus)
                    """,
                    trailingAccessory: .highlightingBackgroundLabel(title: "Request"),
                    isEnabled: (state.purchaseTransaction != nil),
                    onTap: { [weak viewModel] in
                        Task { await viewModel?.requestRefund() }
                    }
                )
            ]
        )
        
        let features: SectionModel = SectionModel(
            model: .features,
            elements: [
                SessionCell.Info(
                    id: .proStatus,
                    title: "Pro Status",
                    subtitle: """
                    Mock current user a Session Pro user locally.
                    """,
                    trailingAccessory: .toggle(
                        state.mockCurrentUserSessionPro,
                        oldValue: previousState.mockCurrentUserSessionPro
                    ),
                    onTap: { [dependencies = viewModel.dependencies] in
                        dependencies.set(
                            feature: .mockCurrentUserSessionPro,
                            to: !state.mockCurrentUserSessionPro
                        )
                    }
                ),
                SessionCell.Info(
                    id: .proIncomingMessages,
                    title: "All Pro Incoming Messages",
                    subtitle: """
                    Treat all incoming messages as Pro messages.
                    """,
                    trailingAccessory: .toggle(
                        state.treatAllIncomingMessagesAsProMessages,
                        oldValue: previousState.treatAllIncomingMessagesAsProMessages
                    ),
                    onTap: { [dependencies = viewModel.dependencies] in
                        dependencies.set(
                            feature: .treatAllIncomingMessagesAsProMessages,
                            to: !state.treatAllIncomingMessagesAsProMessages
                        )
                    }
                )
            ]
        )
        
        return [general, subscriptions, features]
    }
    
    // MARK: - Functions
    
    public static func disableDeveloperMode(using dependencies: Dependencies) {
        let features: [FeatureConfig<Bool>] = [
            .sessionProEnabled,
            .mockCurrentUserSessionPro,
            .treatAllIncomingMessagesAsProMessages
        ]
        
        features.forEach { feature in
            guard dependencies.hasSet(feature: feature) else { return }
            
            dependencies.reset(feature: feature)
        }
    }
    
    private func updateSessionProEnabled(current: Bool) {
        dependencies.set(feature: .sessionProEnabled, to: !current)
        
        if dependencies.hasSet(feature: .mockCurrentUserSessionPro) {
            dependencies.reset(feature: .mockCurrentUserSessionPro)
        }
        
        if dependencies.hasSet(feature: .treatAllIncomingMessagesAsProMessages) {
            dependencies.reset(feature: .treatAllIncomingMessagesAsProMessages)
        }
    }
    
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
}
