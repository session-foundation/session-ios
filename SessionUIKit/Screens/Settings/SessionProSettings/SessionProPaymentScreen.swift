// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import Lucide

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
                                    .put(key: "app_pro", value: Constants.app_pro)
                                    .put(key: "pro", value: Constants.pro)
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
                    
                case .update(let currentPlan, _, _, _, _, billingAccess: true):
                    SessionProPlanPurchaseContent(
                        currentSelection: $currentSelection,
                        isShowingTooltip: $isShowingTooltip,
                        suppressUntil: $suppressUntil,
                        isPendingPurchase: $isPendingPurchase,
                        currentPlan: currentPlan,
                        sessionProPlans: viewModel.dataModel.plans,
                        actionButtonTitle: "updateAccess"
                            .put(key: "pro", value: Constants.pro)
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
                
                case .refund(originatingPlatform: .iOS, _, requestedAt: .some):
                    RequestRefundSuccessContent(
                        returnAction: {
                            host.controller?.navigationController?.popViewController(animated: true)
                        },
                        openRefundSupportAction: {
                            openUrl(SNUIKit.proClientPlatformStringProvider(for: .iOS).refundStatusUrl)
                        }
                    )
                
                case .refund(originatingPlatform: .iOS, false, .none):
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
                    
                case .refund(let originatingPlatform, let isNonOriginatingAccount, let requestedAt):
                    RequestRefundNonOriginatorContent(
                        originatingPlatform: originatingPlatform,
                        isNonOriginatingAccount: isNonOriginatingAccount,
                        requestedAt: requestedAt,
                        openPlatformStoreWebsiteAction: {
                            switch originatingPlatform {
                                case .iOS:
                                    openUrl(SNUIKit.proClientPlatformStringProvider(for: .iOS).refundPlatformUrl)
                                case .android:
                                    openUrl(SNUIKit.proClientPlatformStringProvider(for: .android).refundSupportUrl)
                            }
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
                            openUrl(SNUIKit.proClientPlatformStringProvider(for: originatingPlatform).updateSubscriptionUrl)
                        }
                    )
            }
        }
    }
    
    private func purchase(
        updatedPlan: SessionProPaymentScreenContent.SessionProPlanInfo,
        updatedPlanExpiredOn: Date? = nil
    ) async {
        do {
            let result = try await viewModel.purchase(planInfo: updatedPlan)
            switch result {
                case .success:
                    onPaymentSuccess(expiredOn: updatedPlanExpiredOn)
                case .pending:
                    // TODO: [PRO] Do we need to monitor the status change here?
                    break
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
            onPaymentFailed(
                updatedPlan: updatedPlan,
                updatedPlanExpiredOn: updatedPlanExpiredOn
            )
        }
    }
    
    private func updatePlan() async {
        let updatedPlan: SessionProPaymentScreenContent.SessionProPlanInfo = viewModel.dataModel.plans[currentSelection]
        isPendingPurchase = true

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
                            .put(key: "pro", value: Constants.pro)
                            .localized(),
                        body: .attributedText(
                            isAutoRenewing ?
                                "proUpdateAccessDescription"
                                    .put(key: "current_plan_length", value: currentPlan.durationString)
                                    .put(key: "selected_plan_length", value: updatedPlan.durationString)
                                    .put(key: "selected_plan_length_singular", value: updatedPlan.durationStringSingular)
                                    .put(key: "date", value: expiredOn.formatted("MMM dd, yyyy"))
                                    .put(key: "pro", value: Constants.pro)
                                    .localizedFormatted(Fonts.Body.largeRegular) :
                                "proUpdateAccessExpireDescription"
                                    .put(key: "date", value: expiredOn.formatted("MMM dd, yyyy"))
                                    .put(key: "selected_plan_length", value: updatedPlan.durationString)
                                    .put(key: "pro", value: Constants.pro)
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
        let modal: ConfirmationModal = ConfirmationModal(
            info: ConfirmationModal.Info(
                title: "urlOpen".localized(),
                body: .attributedText(
                    "paymentProError"
                        .put(
                            key: "action_type",
                            value: {
                                switch viewModel.dataModel.flow {
                                    case .renew: "proRenewingAction".localized()
                                    case .update: "proUpdatingAction".localized()
                                    case .purchase: "proUpgradingAction".localized()
                                    default: "" // shouldn't happen
                                }
                            }()
                        )
                        .put(key: "pro", value: Constants.pro)
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
            info: ConfirmationModal.Info(
                title: "urlOpen".localized(),
                body: .attributedText(
                    "urlOpenDescription"
                        .put(key: "url", value: url.absoluteString)
                        .localizedFormatted(baseFont: .systemFont(ofSize: Values.smallFontSize)),
                    scrollMode: .automatic
                ),
                confirmTitle: "open".localized(),
                confirmStyle: .danger,
                cancelTitle: "urlCopy".localized(),
                cancelStyle: .alert_text,
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
