// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import Lucide
import StoreKit

public struct SessionProPaymentScreen<ViewModel: SessionProPaymentScreenContent.ViewModelType>: View {
    @EnvironmentObject var host: HostWrapper
    @EnvironmentObject var toolbarManager: ToolbarManager
    @State private var isNavigationActive: Bool = false
    @State var currentSelection: Int
    @State private var isShowingTooltip: Bool = false
    @State var isPendingPurchase: Bool = false
    
    /// There is an issue on `.onAnyInteraction` of the List and `.onTapGuesture` of the TooltipsIcon. The `.onAnyInteraction` will be called first when tapping the TooltipsIcon to dismiss a tooltip.
    /// This will result in the tooltip will show again right after it dismissed when tapping the TooltipsIcon. This `suppressUntil` is a workaround to fix this issue.
    @State var suppressUntil: Date = .distantPast

    let tooltipViewId: String = "SessionProPaymentScreenToolTip" // stringlint:ignore
    private let coordinateSpaceName: String = "SessionProPaymentScreen" // stringlint:ignore
    
    @StateObject private var viewModel: ViewModel
    
    public init(viewModel: ViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
        if
            case .update(let currentPlan, _, _, _, _, _) = viewModel.dataModel.flow,
            let indexOfCurrentPlan = viewModel.dataModel.plans.firstIndex(of: currentPlan)
        {
            self.currentSelection = indexOfCurrentPlan
        } else {
            self.currentSelection = 0
        }
    }
    
    public var body: some View {
        GeometryReader { geometry in
            ScrollView(.vertical, showsIndicators: false) {
                ZStack(alignment: .topLeading) {
                    content
                        .padding(.horizontal, Values.largeSpacing)
                        .frame(
                            maxWidth: .infinity,
                            minHeight: geometry.size.height
                        )
                        .onAnyInteraction(scrollCoordinateSpaceName: coordinateSpaceName) {
                            guard self.isShowingTooltip else { return }
                            suppressUntil = Date().addingTimeInterval(0.2)
                            withAnimation(.spring()) {
                                self.isShowingTooltip = false
                            }
                        }
                }
            }
            .coordinateSpace(name: coordinateSpaceName)
            .popoverView(
                content: {
                    ZStack {
                        if case .update(let currentPlan, _, _, _, _, _) = viewModel.dataModel.flow, let discountPercent = currentPlan.discountPercent {
                            Text(
                                "proDiscountTooltip"
                                    .put(key: "percent", value: discountPercent)
                                    .localized()
                            )
                            .font(.Body.smallRegular)
                            .multilineTextAlignment(.center)
                            .foregroundColor(themeColor: .textPrimary)
                            .padding(.horizontal, Values.smallSpacing)
                            .padding(.vertical, Values.smallSpacing)
                            .frame(maxWidth: 250)
                        }
                    }
                },
                backgroundThemeColor: .toast_background,
                isPresented: $isShowingTooltip,
                position: .topRight,
                offset: 50,
                viewId: tooltipViewId
            )
        }
    }
    
    private var content: some View {
        VStack(spacing: Values.mediumSmallSpacing) {
            ListItemLogoWithPro(
                info: ListItemLogoWithPro.Info(
                    themeStyle: {
                        switch viewModel.dataModel.flow {
                            case .refund, .cancel: return .disabled
                            default: return .normal
                        }
                    }(),
                    glowingBackgroundStyle: .base,
                    state: .success,
                    description: viewModel.dataModel.flow.description
                )
            )
            
            switch viewModel.dataModel.flow {
                case .purchase(billingAccess: true):
                    SessionProPlanPurchaseContent(
                        currentSelection: $currentSelection,
                        isShowingTooltip: $isShowingTooltip,
                        suppressUntil: $suppressUntil,
                        isPendingPurchase: $isPendingPurchase,
                        currentPlan: nil,
                        isAutoRenewing: false,
                        sessionProPlans: viewModel.dataModel.plans,
                        actionButtonTitle: "upgrade".localized(),
                        actionType: "proUpgradingAction".localized(),
                        activationType: "proActivatingActivation".localized(),
                        purchaseAction: {
                            Task { @MainActor in
                                await updatePlan()
                            }
                        },
                        openTosPrivacyAction: { openTosPrivacy() }
                    )
                    
                case .purchase(billingAccess: false):
                    NoBillingAccessContent(
                        isRenewingPro: false,
                        originatingPlatform: .iOS,
                        openProRoadmapAction: { openUrl(SNUIKit.urlStringProvider().proRoadmap) }
                    )
                
                case .renew(_, billingAccess: true):
                    SessionProPlanPurchaseContent(
                        currentSelection: $currentSelection,
                        isShowingTooltip: $isShowingTooltip,
                        suppressUntil: $suppressUntil,
                        isPendingPurchase: $isPendingPurchase,
                        currentPlan: nil,
                        isAutoRenewing: false,
                        sessionProPlans: viewModel.dataModel.plans,
                        actionButtonTitle: "renew".localized(),
                        actionType: "proRenewingAction".localized(),
                        activationType: "proReactivatingActivation".localized(),
                        purchaseAction: {
                            Task { @MainActor in
                                await updatePlan()
                            }
                        },
                        openTosPrivacyAction: { openTosPrivacy() }
                    )
                    
                case .renew(let originatingPlatform, billingAccess: false):
                    NoBillingAccessContent(
                        isRenewingPro: true,
                        originatingPlatform: originatingPlatform,
                        openProRoadmapAction: { openUrl(SNUIKit.urlStringProvider().proRoadmap) },
                        openPlatformStoreWebsiteAction: {
                            openUrl(SNUIKit.proClientPlatformStringProvider(for: .iOS).updateSubscriptionUrl)
                        }
                    )
                    
                case .update(let currentPlan, let expiredOn, originatingPlatform: .iOS, let isAutoRenewing, isNonOriginatingAccount: true, _):
                    UpdatePlanNonOriginatingPlatformContent(
                        currentPlan: currentPlan,
                        currentPlanExpiredOn: expiredOn,
                        isAutoRenewing: isAutoRenewing,
                        originatingPlatform: .iOS,
                        openPlatformStoreWebsiteAction: {
                            openUrl(SNUIKit.proClientPlatformStringProvider(for: .iOS).updateSubscriptionUrl)
                        }
                    )
                    
                case .update(let currentPlan, let expiredOn, originatingPlatform: .android, let isAutoRenewing, _, _):
                    UpdatePlanNonOriginatingPlatformContent(
                        currentPlan: currentPlan,
                        currentPlanExpiredOn: expiredOn,
                        isAutoRenewing: isAutoRenewing,
                        originatingPlatform: .android,
                        openPlatformStoreWebsiteAction: {
                            openUrl(SNUIKit.proClientPlatformStringProvider(for: .android).updateSubscriptionUrl)
                        }
                    )
                    
                case .update(let currentPlan, _, _, let isAutoRenewing, _, billingAccess: true):
                    SessionProPlanPurchaseContent(
                        currentSelection: $currentSelection,
                        isShowingTooltip: $isShowingTooltip,
                        suppressUntil: $suppressUntil,
                        isPendingPurchase: $isPendingPurchase,
                        currentPlan: currentPlan,
                        isAutoRenewing: isAutoRenewing,
                        sessionProPlans: viewModel.dataModel.plans,
                        actionButtonTitle: "updateAccess"
                            .localized(),
                        actionType: "proUpdatingAction".localized(),
                        activationType: "",
                        purchaseAction: {
                            Task { @MainActor in
                                await updatePlan()
                            }
                        },
                        openTosPrivacyAction: { openTosPrivacy() }
                    )
                    
                case .update(_, _, let originatingPlatform, _, _, billingAccess: false):
                    NoBillingAccessContent(
                        isRenewingPro: false,
                        originatingPlatform: originatingPlatform,
                        openProRoadmapAction: { openUrl(SNUIKit.urlStringProvider().proRoadmap) }
                    )
                
                case .refund(originatingPlatform: .iOS, _, requestedAt: .some, _):
                    RequestRefundSuccessContent(
                        returnAction: {
                            host.controller?.navigationController?.popViewController(animated: true)
                        },
                        openRefundSupportAction: {
                            openUrl(SNUIKit.proClientPlatformStringProvider(for: .iOS).refundStatusUrl)
                        }
                    )
                
                case .refund(originatingPlatform: .iOS, false, .none, _):
                    RequestRefundOriginatingPlatformContent(
                        requestRefundAction: {
                            Task { @MainActor [weak viewModel] in
                                do {
                                    try await viewModel?.requestRefund(scene: host.controller?.view.window?.windowScene)
                                }
                                catch {
                                    // TODO: [PRO] Request refund failure behaviour
                                }
                            }
                        }
                    )
                    
                case .refund(let originatingPlatform, let isNonOriginatingAccount, _, let isWithinQuickRefundWindow):
                    RequestRefundNonOriginatorContent(
                        originatingPlatform: originatingPlatform,
                        isNonOriginatingAccount: isNonOriginatingAccount,
                        isWithinQuickRefundWindow: isWithinQuickRefundWindow,
                        openPlatformStoreWebsiteAction: {
                            /// The destination follows the quick-refund window, not the originating platform: inside it
                            /// the copy tells the user to use the store's own refund workflow, and outside it the copy
                            /// directs them to Session Support. The platform only selects whose URLs these are.
                            let urls: StringProvider.ClientPlatform = SNUIKit
                                .proClientPlatformStringProvider(for: originatingPlatform)

                            /// Two Session-owned links, chosen on the window alone - not the provider's own
                            /// `refund_platform_url`/`refund_support_url`. Being ours, the destinations can be
                            /// repointed without a client release, and all three clients agree on them.
                            ///
                            /// The window is what decides who can act: while it is open the store takes the
                            /// request, and once it closes only Session can, which is what the copy promises.
                            openUrl(
                                isWithinQuickRefundWindow ?
                                    SNUIKit.urlStringProvider().proQuickRefund :
                                    SNUIKit.urlStringProvider().proSupport
                            )
                        }
                    )
                
                case .cancel(originatingPlatform: .iOS, isNonOriginatingAccount: false):
                    CancelPlanOriginatingPlatformContent(
                        cancelPlanAction: {
                            Task { @MainActor [weak viewModel] in
                                do {
                                    try await viewModel?.cancelPro(scene: host.controller?.view.window?.windowScene)
                                    host.controller?.navigationController?.popViewController(animated: true)
                                }
                                catch {
                                    // TODO: [PRO] Failed to cancel plan
                                }
                            }
                        }
                    )
                    
                case .cancel(let originatingPlatform, let isNonOriginatingAccount):
                    CancelPlanNonOriginatorContent(
                        originatingPlatform: originatingPlatform,
                        isNonOriginatingAccount: isNonOriginatingAccount,
                        openPlatformStoreWebsiteAction: {
                            openUrl(SNUIKit.proClientPlatformStringProvider(for: originatingPlatform).cancelSubscriptionUrl)
                        }
                    )
            }
        }
    }
    
    private func purchase(
        updatedPlan: SessionProPaymentScreenContent.SessionProPlanInfo,
        updatedPlanExpiredOn: Date? = nil
    ) async {
        isPendingPurchase = true
        
        do {
            let result = try await viewModel.purchase(planInfo: updatedPlan)
            switch result {
                case .success(let expirationTimestampSeconds):
                    let updatedPlanExpiredDate: Date? = {
                        guard let expirationTimestampSeconds else { return updatedPlanExpiredOn }
                        return Date(timeIntervalSince1970: Double(expirationTimestampSeconds))
                    }()
                    onPaymentSuccess(expiredOn: updatedPlanExpiredDate)
                case .pending:
                    // TODO: [PRO] Do we need to monitor the status change here?
                    break
                case .cancelled:
                    isPendingPurchase = false
                case .failed:
                    onPaymentFailed(
                        updatedPlan: updatedPlan,
                        updatedPlanExpiredOn: updatedPlanExpiredOn
                    )
                case .dev:
                    let modal: ConfirmationModal = ConfirmationModal(
                        info: ConfirmationModal.Info(
                            title: "DEV Purchase",  // stringlint:ignore
                            body: .text("This is a DEV purchase.", scrollMode: .automatic), // stringlint:ignore
                            cancelTitle: "okay".localized(),
                            cancelStyle: .textPrimary,
                            onCancel: { _ in
                                onPaymentSuccess(expiredOn: updatedPlanExpiredOn)
                            }
                        )
                    )
                    
                    self.host.controller?.present(modal, animated: true)
            }
        }
        catch {
            if error is StoreKitError || error is Product.PurchaseError {
                let modal: ConfirmationModal = ConfirmationModal(
                    info: ConfirmationModal.Info(
                        title: "paymentError".localized(),
                        body: .text("errorGeneric".localized(), scrollMode: .never),
                        cancelTitle: "okay".localized(),
                        cancelStyle: .alert_text
                    )
                )
                isPendingPurchase = false
                self.host.controller?.present(modal, animated: true)
            } else {
                onPaymentFailed(
                    updatedPlan: updatedPlan,
                    updatedPlanExpiredOn: updatedPlanExpiredOn
                )
            }
        }
    }
    
    private func updatePlan() async {
        let updatedPlan: SessionProPaymentScreenContent.SessionProPlanInfo = viewModel.dataModel.plans[currentSelection]

        switch viewModel.dataModel.flow {
            case .refund, .cancel: break
            case .purchase, .renew: await purchase(updatedPlan: updatedPlan)
            case .update(let currentPlan, let expiredOn, _, let isAutoRenewing, _, _):
                let updatedPlanExpiredOn: Date = (Calendar.current
                    .date(byAdding: .month, value: updatedPlan.duration, to: expiredOn) ??
                    expiredOn)
                
                let confirmationModal = ConfirmationModal(
                    info: ConfirmationModal.Info(
                        title: "updateAccess"
                            .localized(),
                        body: .attributedText(
                            isAutoRenewing ?
                                "proUpdateAccessDescription"
                                    .put(key: "current_plan_length", value: currentPlan.durationString)
                                    .put(key: "selected_plan_length", value: updatedPlan.durationString)
                                    .put(key: "selected_plan_length_singular", value: updatedPlan.durationStringSingular)
                                    .put(key: "date", value: expiredOn.formatted("MMM dd, yyyy"))
                                    .localizedFormatted(Fonts.Body.largeRegular) :
                                "proUpdateAccessExpireDescription"
                                    .put(key: "date", value: expiredOn.formatted("MMM dd, yyyy"))
                                    .put(key: "selected_plan_length", value: updatedPlan.durationString)
                                    .localizedFormatted(Fonts.Body.largeRegular),
                            scrollMode: .never
                        ),
                        confirmTitle: "update".localized(),
                        onConfirm: { _ in
                            Task { @MainActor in
                                await purchase(
                                    updatedPlan: updatedPlan,
                                    updatedPlanExpiredOn: updatedPlanExpiredOn
                                )
                            }
                        },
                        onCancel: { modal in
                            Task { @MainActor in
                                isPendingPurchase = false
                                modal.dismiss(animated: true)
                            }
                        }
                    )
                )
                
                self.host.controller?.present(confirmationModal, animated: true)
        }
    }
    
    @MainActor private func onPaymentSuccess(expiredOn: Date?) {
        isPendingPurchase = false
        guard !self.viewModel.isFromBottomSheet else {
            let sessionProBottomSheet: BottomSheetHostingViewController = BottomSheetHostingViewController(
                bottomSheet: BottomSheet(
                    hasCloseButton: true,
                    contentPrefferedHeight: 480
                ) {
                    SessionProPlanUpdatedScreen(
                        flow: self.viewModel.dataModel.flow,
                        expiredOn: expiredOn,
                        isFromBottomSheet: true
                    )
                    .backgroundColor(themeColor: .backgroundPrimary)
                }
            )
            self.host.controller?.dismiss(animated: false)
            self.host.controller?.presentingViewController?.present(sessionProBottomSheet, animated: true)
            return
        }
        
        let viewController: SessionHostingViewController = SessionHostingViewController(
            rootView: SessionProPlanUpdatedScreen(
                flow: self.viewModel.dataModel.flow,
                expiredOn: expiredOn,
                isFromBottomSheet: false
            )
        )
        viewController.modalTransitionStyle = .crossDissolve
        viewController.modalPresentationStyle = .overFullScreen
        self.host.controller?.present(viewController, animated: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250)) {
            self.host.controller?.navigationController?.popViewController(animated: false)
        }
    }
    
    @MainActor private func onPaymentFailed(
        updatedPlan: SessionProPaymentScreenContent.SessionProPlanInfo,
        updatedPlanExpiredOn: Date?
    ) {
        isPendingPurchase = false
        let action: String = {
            switch viewModel.dataModel.flow {
                case .renew: "proRenewingAction".localized()
                case .update: "proUpdatingAction".localized()
                case .purchase: "proUpgradingAction".localized()
                default: "" // shouldn't happen
            }
        }()
        let modal: ConfirmationModal = ConfirmationModal(
            info: ConfirmationModal.Info(
                title: "paymentError".localized(),
                body: .attributedText(
                    "paymentProError"
                        .put(key: "action_type", value: action)
                        .localizedFormatted(baseFont: .systemFont(ofSize: Values.smallFontSize)),
                    scrollMode: .automatic
                ),
                confirmTitle: "retry".localized(),
                confirmStyle: .alert_text,
                cancelTitle: "helpSupport".localized(),
                cancelStyle: .alert_text,
                onConfirm:  { _ in
                    Task { @MainActor in
                        await purchase(
                            updatedPlan: updatedPlan,
                            updatedPlanExpiredOn: updatedPlanExpiredOn
                        )
                    }
                },
                onCancel: { _ in
                    self.openUrl(SNUIKit.urlStringProvider().proSupport)
                }
            )
        )
        
        self.host.controller?.present(modal, animated: true)
    }
    
    private func openTosPrivacy() {
        let modal: ModalHostingViewController = ModalHostingViewController(
            modal: MutipleLinksModal(
                links: [
                    SNUIKit.urlStringProvider().proTermsOfService,
                    SNUIKit.urlStringProvider().proPrivacyPolicy
                ],
                openURL: { [weak viewModel] url in
                    viewModel?.openURL(url)
                }
            )
        )
        self.host.controller?.present(modal, animated: true)
    }
    
    private func openUrl(_ urlString: String) {
        guard let url: URL = URL(string: urlString) else { return }
        
        let modal: ConfirmationModal = ConfirmationModal(
            info: .openUrl(
                url,
                onConfirm:  { [weak viewModel] _ in
                    viewModel?.openURL(url)
                },
                onCancel: { modal in
                    UIPasteboard.general.string = url.absoluteString
                    modal.close()
                }
            )
        )
        
        self.host.controller?.present(modal, animated: true)
    }
}

