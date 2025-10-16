// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import Lucide

public struct SessionProPaymentScreen: View {
    @EnvironmentObject var host: HostWrapper
    @State var currentSelection: Int
    @State private var isShowingTooltip: Bool = false
    
    /// There is an issue on `.onAnyInteraction` of the List and `.onTapGuesture` of the TooltipsIcon. The `.onAnyInteraction` will be called first when tapping the TooltipsIcon to dismiss a tooltip.
    /// This will result in the tooltip will show again right after it dismissed when tapping the TooltipsIcon. This `suppressUntil` is a workaround to fix this issue.
    @State var suppressUntil: Date = .distantPast

    let tooltipViewId: String = "SessionProPaymentScreenToolTip" // stringlint:ignore
    private let coordinateSpaceName: String = "SessionProPaymentScreen" // stringlint:ignore
    
    private let viewModel: SessionProPaymentScreenContent.ViewModelType
    
    public init(viewModel: SessionProPaymentScreenContent.ViewModelType) {
        self.viewModel = viewModel
        if
            case .update(let currentPlan, _, _, _) = viewModel.dataModel.flow,
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
                VStack(spacing: Values.mediumSmallSpacing) {
                    ListItemLogoWithPro(
                        style: {
                            switch viewModel.dataModel.flow {
                                case .refund, .cancel: return .disabled
                                default: return .normal
                            }
                        }(),
                        description: viewModel.dataModel.flow.description
                    )
                    if case .purchase = viewModel.dataModel.flow {
                        SessionProPlanPurchaseContent(
                            currentSelection: $currentSelection,
                            isShowingTooltip: $isShowingTooltip,
                            suppressUntil: $suppressUntil,
                            currentPlan: nil,
                            sessionProPlans: viewModel.dataModel.plans,
                            actionButtonTitle: "Upgrade",
                            purchaseAction: { updatePlan() },
                            openTosPrivacyAction: { openTosPrivacy() }
                        )
                    } else if case .renew(let originatingPlatform) = viewModel.dataModel.flow {
                        if viewModel.dataModel.plans.isEmpty {
                            RenewPlanNoBillingAccessContent(
                                originatingPlatform: originatingPlatform,
                                openPlatformStoreWebsiteAction: { openPlatformStoreWebsite() }
                            )
                        } else {
                            SessionProPlanPurchaseContent(
                                currentSelection: $currentSelection,
                                isShowingTooltip: $isShowingTooltip,
                                suppressUntil: $suppressUntil,
                                currentPlan: nil,
                                sessionProPlans: viewModel.dataModel.plans,
                                actionButtonTitle: "renew".localized(),
                                purchaseAction: { updatePlan() },
                                openTosPrivacyAction: { openTosPrivacy() }
                            )
                        }
                    } else if case .update(let currentPlan, let expiredOn, let isAutoRenewing, let originatingPlatform) = viewModel.dataModel.flow {
                        if originatingPlatform == .iOS {
                            SessionProPlanPurchaseContent(
                                currentSelection: $currentSelection,
                                isShowingTooltip: $isShowingTooltip,
                                suppressUntil: $suppressUntil,
                                currentPlan: currentPlan,
                                sessionProPlans: viewModel.dataModel.plans,
                                actionButtonTitle: "updatePlan".localized(),
                                purchaseAction: { updatePlan() },
                                openTosPrivacyAction: { openTosPrivacy() }
                            )
                        } else {
                            UpdatePlanNonOriginatingPlatformContent(
                                currentPlan: currentPlan,
                                currentPlanExpiredOn: expiredOn,
                                isAutoRenewing: isAutoRenewing,
                                originatingPlatform: originatingPlatform,
                                openPlatformStoreWebsiteAction: { openPlatformStoreWebsite() }
                            )
                        }
                    } else if case .refund(let originatingPlatform, let requestedAt) = viewModel.dataModel.flow {
                        if originatingPlatform == .iOS {
                            RequestRefundOriginatingPlatformContent(
                                requestRefundAction: {}
                            )
                        } else {
                            RequestRefundNonOriginatingPlatformContent(
                                originatingPlatform: originatingPlatform,
                                requestedAt: requestedAt,
                                openPlatformStoreWebsiteAction: {}
                            )
                        }
                    } else if case .cancel(let originatingPlatform) = viewModel.dataModel.flow {
                        if originatingPlatform == .iOS {
                            CancelPlanOriginatingPlatformContent(
                                cancelPlanAction: {}
                            )
                        } else {
                            CancelPlanNonOriginatingPlatformContent(
                                originatingPlatform: originatingPlatform,
                                openPlatformStoreWebsiteAction: {}
                            )
                        }
                    }
                    
                    Spacer()
                }
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
            .coordinateSpace(name: coordinateSpaceName)
            .popoverView(
                content: {
                    ZStack {
                        if case .update(let currentPlan, _, _, _) = viewModel.dataModel.flow, let discountPercent = currentPlan.discountPercent {
                            Text(
                                "proDiscountTooltip"
                                    .put(key: "percent", value: discountPercent)
                                    .put(key: "app_pro", value: Constants.app_pro)
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
    
    private func updatePlan() {
        let updatedPlan = viewModel.dataModel.plans[currentSelection]
        if
            case .update(let currentPlan, let expiredOn, let isAutoRenewing, let originatingPlatform) = viewModel.dataModel.flow,
            let updatedPlanExpiredOn = Calendar.current.date(byAdding: .month, value: updatedPlan.duration, to: expiredOn)
        {
            let confirmationModal = ConfirmationModal(
                info: .init(
                    title: "updatePlan".localized(),
                    body: .attributedText(
                        isAutoRenewing ?
                            "proUpdatePlanDescription"
                                .put(key: "current_plan", value: currentPlan.durationString)
                                .put(key: "selected_plan", value: updatedPlan.durationString)
                                .put(key: "date", value: expiredOn.formatted("MMM dd, yyyy"))
                                .put(key: "pro", value: Constants.pro)
                                .localizedFormatted(Fonts.Body.largeRegular) :
                            "proUpdatePlanExpireDescription"
                                .put(key: "date", value: expiredOn.formatted("MMM dd, yyyy"))
                                .put(key: "selected_plan", value: updatedPlan.durationString)
                                .put(key: "pro", value: Constants.pro)
                                .localizedFormatted(Fonts.Body.largeRegular),
                        scrollMode: .never
                    ),
                    confirmTitle: "updatePlan".localized(),
                    onConfirm: { _ in
                        self.viewModel.purchase(
                            planInfo: updatedPlan,
                            success: { onPaymentSuccess(expiredOn: updatedPlanExpiredOn) },
                            failure: {
                                
                            }
                        )
                    }
                )
            )
            self.host.controller?.present(confirmationModal, animated: true)
        }
        
        switch viewModel.dataModel.flow {
            case .purchase, .renew:
                if let updatedPlanExpiredOn = Calendar.current.date(byAdding: .month, value: updatedPlan.duration, to: Date()) {
                    self.viewModel.purchase(
                        planInfo: updatedPlan,
                        success: { onPaymentSuccess(expiredOn: updatedPlanExpiredOn) },
                        failure: {
                            
                        }
                    )
                }
            default: break
        }
    }
    
    private func onPaymentSuccess(expiredOn: Date) {
        let viewController: SessionHostingViewController = SessionHostingViewController(
            rootView: SessionProPlanUpdatedScreen(
                flow: self.viewModel.dataModel.flow,
                expiredOn: expiredOn
            )
        )
        viewController.modalTransitionStyle = .crossDissolve
        viewController.modalPresentationStyle = .overFullScreen
        self.host.controller?.present(viewController, animated: true)
    }
    
    private func openTosPrivacy() {
        let modal: ConfirmationModal = ConfirmationModal(
            info: ConfirmationModal.Info(
                title: "urlOpen".localized(),
                body: .text("urlOpenBrowser".localized()),
                confirmTitle: "onboardingTos".localized(),
                confirmStyle: .textPrimary,
                cancelTitle: "onboardingPrivacy".localized(),
                cancelStyle: .textPrimary,
                hasCloseButton: true,
                onConfirm: { _ in
                    if let url: URL = URL(string: "https://getsession.org/terms-of-service") {
                        viewModel.openURL(url)
                    }
                },
                onCancel: { modal in
                    if let url: URL = URL(string: "https://getsession.org/privacy-policy") {
                        viewModel.openURL(url)
                    }
                    modal.close()
                }
            )
        )
        self.host.controller?.present(modal, animated: true)
    }
    
    private func openPlatformStoreWebsite() {
        guard let url: URL = URL(string: Constants.google_play_store_subscriptions_url) else { return }
        
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
                onConfirm:  { _ in viewModel.openURL(url) },
                onCancel: { modal in
                    UIPasteboard.general.string = url.absoluteString
                    modal.close()
                }
            )
        )
        
        self.host.controller?.present(modal, animated: true)
    }
}
