// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import Lucide

public struct SessionProPlanScreen: View {
    @EnvironmentObject var host: HostWrapper
    @State var currentSelection: Int
    @State private var isShowingTooltip: Bool = false
    @State var tooltipContentFrame: CGRect = CGRect.zero
    
    /// There is an issue on `.onAnyInteraction` of the List and `.onTapGuesture` of the TooltipsIcon. The `.onAnyInteraction` will be called first when tapping the TooltipsIcon to dismiss a tooltip.
    /// This will result in the tooltip will show again right after it dismissed when tapping the TooltipsIcon. This `suppressUntil` is a workaround to fix this issue.
    @State var suppressUntil: Date = .distantPast

    let tooltipViewId: String = "SessionProPlanScreenToolTip" // stringlint:ignore
    private let coordinateSpaceName: String = "SessionProPlanScreen" // stringlint:ignore
    
    private let dataModel: SessionProPlanScreenContent.DataModel
    
    public init(dataModel: SessionProPlanScreenContent.DataModel) {
        self.dataModel = dataModel
        if
            case .update(let currentPlan, _, _, _) = dataModel.flow,
            let indexOfCurrentPlan = dataModel.plans.firstIndex(of: currentPlan)
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
                    ListItemLogWithPro()
                    
                    if case .update(let currentPlan, let expiredOn, let isAutoRenewing, let originatingPlatform) = dataModel.flow {
                        if originatingPlatform == .iOS {
                            OriginatingPlatformContent(
                                currentSelection: $currentSelection,
                                isShowingTooltip: $isShowingTooltip,
                                suppressUntil: $suppressUntil,
                                currentPlan: currentPlan,
                                currentPlanExpiredOn: expiredOn,
                                isAutoRenewing: isAutoRenewing,
                                sessionProPlans: dataModel.plans,
                                updatePlanAction: { updatePlan() },
                                openTosPrivacyAction: { openTosPrivacy() }
                            )
                        } else {
                            NonOriginatingPlatformContent(
                                currentPlan: currentPlan,
                                currentPlanExpiredOn: expiredOn,
                                isAutoRenewing: isAutoRenewing,
                                originatingPlatform: originatingPlatform,
                                openPlatformStoreWebsiteAction: { openPlatformStoreWebsite() }
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
                        if case .update(let currentPlan, _, _, _) = dataModel.flow, let discountPercent = currentPlan.discountPercent {
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
                    .overlay(
                        GeometryReader { geometry in
                            Color.clear // Invisible overlay
                                .onAppear {
                                    self.tooltipContentFrame = geometry.frame(in: .global)
                                }
                        }
                    )
                },
                backgroundThemeColor: .toast_background,
                isPresented: $isShowingTooltip,
                frame: $tooltipContentFrame,
                position: .topRight,
                offset: 50,
                viewId: tooltipViewId
            )
        }
    }
    
    private func updatePlan() {
        let updatedPlan = dataModel.plans[currentSelection]
        
        if
            case .update(let currentPlan, let expiredOn, let isAutoRenewing, let originatingPlatform) = dataModel.flow,
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
                    onConfirm: { [host = self.host] _ in
                        let viewController: SessionHostingViewController = SessionHostingViewController(
                            rootView: SessionProPlanUpdatedScreen(
                                flow: dataModel.flow,
                                expiredOn: expiredOn
                            )
                        )
                        viewController.modalTransitionStyle = .crossDissolve
                        viewController.modalPresentationStyle = .overFullScreen
                        host.controller?.present(viewController, animated: true)
                    }
                )
            )
            
            self.host.controller?.present(confirmationModal, animated: true)
        }
    }
    
    private func openTosPrivacy() {
        
    }
    
    private func openPlatformStoreWebsite() {
        
    }
}

// MARK: - Update Plan Originating Platform Content

struct OriginatingPlatformContent: View {
    @Binding var currentSelection: Int
    @Binding var isShowingTooltip: Bool
    @Binding var suppressUntil: Date
    
    let currentPlan: SessionProPlanScreenContent.SessionProPlanInfo
    let currentPlanExpiredOn: Date
    let isAutoRenewing: Bool
    let sessionProPlans: [SessionProPlanScreenContent.SessionProPlanInfo]
    let updatePlanAction: () -> Void
    let openTosPrivacyAction: () -> Void
    
    var body: some View {
        VStack(spacing: Values.mediumSmallSpacing) {
            AttributedText(
                isAutoRenewing ?
                    "proPlanActivatedAuto"
                        .put(key: "app_pro", value: Constants.app_pro)
                        .put(key: "current_plan", value: currentPlan.durationString)
                        .put(key: "date", value: currentPlanExpiredOn.formatted("MMM dd, yyyy"))
                        .put(key: "pro", value: Constants.pro)
                        .localizedFormatted(Fonts.Body.baseRegular) :
                    "proPlanActivatedNotAuto"
                        .put(key: "app_pro", value: Constants.app_pro)
                        .put(key: "date", value: currentPlanExpiredOn.formatted("MMM dd, yyyy"))
                        .put(key: "pro", value: Constants.pro)
                        .localizedFormatted(Fonts.Body.baseRegular)
            )
            .font(.Body.baseRegular)
            .foregroundColor(themeColor: .textPrimary)
            .multilineTextAlignment(.center)
            .padding(.vertical, Values.smallSpacing)
            
            ForEach(sessionProPlans.indices, id: \.self) { index in
                PlanCell(
                    currentSelection: $currentSelection,
                    isShowingTooltip: $isShowingTooltip,
                    suppressUntil: $suppressUntil,
                    plan: sessionProPlans[index],
                    index: index,
                    isCurrentPlan: (sessionProPlans[index] == currentPlan)
                )
            }
            
            Button {
                updatePlanAction()
            } label: {
                Text("updatePlan".localized())
                    .font(.Body.largeRegular)
                    .foregroundColor(themeColor: .sessionButton_primaryFilledText)
                    .framing(
                        maxWidth: .infinity,
                        height: 50,
                        alignment: .center
                    )
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(
                                themeColor: (sessionProPlans[currentSelection] == currentPlan) ?
                                    .disabled :
                                    .sessionButton_primaryFilledBackground
                            )
                    )
                    .padding(.vertical, Values.smallSpacing)
            }
            .disabled((sessionProPlans[currentSelection] == currentPlan))
            
            AttributedText(
                "proTosPrivacy"
                    .put(key: "app_pro", value: Constants.app_pro)
                    .put(key: "icon", value: "<icon>\(Lucide.Icon.squareArrowUpRight)</icon>")
                    .localizedFormatted(Fonts.Body.smallRegular)
            )
            .font(.Body.smallRegular)
            .foregroundColor(themeColor: .textSecondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, Values.smallSpacing)
            .onTapGesture { openTosPrivacyAction() }
        }
    }
}

// MARK: - Non Originating Platform Content

struct NonOriginatingPlatformContent: View {
    let currentPlan: SessionProPlanScreenContent.SessionProPlanInfo
    let currentPlanExpiredOn: Date
    let isAutoRenewing: Bool
    let originatingPlatform: SessionProPlanScreenContent.ClientPlatform
    let openPlatformStoreWebsiteAction: () -> Void

    var body: some View {
        VStack(spacing: Values.mediumSpacing) {
            AttributedText(
                isAutoRenewing ?
                    "proPlanActivatedAutoShort"
                        .put(key: "app_pro", value: Constants.app_pro)
                        .put(key: "current_plan", value: currentPlan.durationString)
                        .put(key: "date", value: currentPlanExpiredOn.formatted("MMM dd, yyyy"))
                        .localizedFormatted(Fonts.Body.baseRegular) :
                    "proPlanExpireDate"
                        .put(key: "app_pro", value: Constants.app_pro)
                        .put(key: "date", value: currentPlanExpiredOn.formatted("MMM dd, yyyy"))
                        .localizedFormatted(Fonts.Body.baseRegular)
            )
            .font(.Body.baseRegular)
            .foregroundColor(themeColor: .textPrimary)
            .multilineTextAlignment(.center)
            .padding(.vertical, Values.smallSpacing)
            
            VStack(
                alignment: .leading,
                spacing: Values.mediumSpacing
            ) {
                Text("updatePlan".localized())
                    .font(.Headings.H7)
                    .foregroundColor(themeColor: .textPrimary)
                
                Text(
                    "proPlanSignUp"
                        .put(key: "app_pro", value: Constants.app_pro)
                        .put(key: "platform_store", value: originatingPlatform.store)
                        .put(key: "platform_account", value: originatingPlatform.account)
                        .localized()
                )
                .font(.Body.baseRegular)
                .foregroundColor(themeColor: .textPrimary)
                .multilineTextAlignment(.leading)
                
                Text("updatePlanTwo".localized())
                    .font(.Body.baseRegular)
                    .foregroundColor(themeColor: .textSecondary)
                
                HStack(
                    alignment: .top,
                    spacing: Values.mediumSpacing
                ) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(themeColor: .value(.primary, alpha: 0.1))
                        
                        AttributedText(Lucide.Icon.smartphone.attributedString(size: 24))
                            .foregroundColor(themeColor: .primary)
                    }
                    .frame(width: 34, height: 34)
                    
                    VStack(
                        alignment: .leading,
                        spacing: Values.verySmallSpacing
                    ) {
                        Text(
                            "onDevice"
                                .put(key: "device_type", value: originatingPlatform.deviceType)
                                .localized()
                        )
                        .font(.Body.baseBold)
                        .foregroundColor(themeColor: .textPrimary)
                        
                        Text(
                            "onDeviceDescription"
                                .put(key: "app_name", value: Constants.app_name)
                                .put(key: "device_type", value: originatingPlatform.deviceType)
                                .put(key: "platform_account", value: originatingPlatform.account)
                                .put(key: "app_pro", value: Constants.app_pro)
                                .localized()
                        )
                        .font(.Body.baseRegular)
                        .foregroundColor(themeColor: .textPrimary)
                        .multilineTextAlignment(.leading)
                    }
                }
                .padding(Values.mediumSpacing)
                .background(
                    RoundedRectangle(cornerRadius: 11)
                        .fill(themeColor: .inputButton_background)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 11)
                        .stroke(themeColor: .borderSeparator)
                )
                
                HStack(
                    alignment: .top,
                    spacing: Values.mediumSpacing
                ) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(themeColor: .value(.primary, alpha: 0.1))
                        
                        AttributedText(Lucide.Icon.globe.attributedString(size: 20))
                            .foregroundColor(themeColor: .primary)
                    }
                    .frame(width: 34, height: 34)
                    
                    VStack(
                        alignment: .leading,
                        spacing: Values.verySmallSpacing
                    ) {
                        Text(
                            "viaStoreWebsite"
                                .put(key: "platform_store", value: originatingPlatform.store)
                                .localized()
                        )
                        .font(.Body.baseBold)
                        .foregroundColor(themeColor: .textPrimary)
                        
                        AttributedText(
                            "viaStoreWebsiteDescription"
                                .put(key: "platform_account", value: originatingPlatform.account)
                                .put(key: "platform_store", value: originatingPlatform.store)
                                .localizedFormatted(Fonts.Body.baseRegular)
                        )
                        .font(.Body.baseRegular)
                        .multilineTextAlignment(.leading)
                    }
                }
                .padding(Values.mediumSpacing)
                .background(
                    RoundedRectangle(cornerRadius: 11)
                        .fill(themeColor: .inputButton_background)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 11)
                        .stroke(themeColor: .borderSeparator)
                )
            }
            .padding(Values.mediumSpacing)
            .background(
                RoundedRectangle(cornerRadius: 11)
                    .fill(themeColor: .backgroundSecondary)
            )
            
            Button {
                openPlatformStoreWebsiteAction()
            } label: {
                Text("openStoreWebsite".put(key: "platform_store", value: originatingPlatform.store).localized())
                    .font(.Body.largeRegular)
                    .foregroundColor(themeColor: .sessionButton_primaryFilledText)
                    .framing(
                        maxWidth: .infinity,
                        height: 50,
                        alignment: .center
                    )
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(themeColor: .sessionButton_primaryFilledBackground)
                    )
                    .padding(.vertical, Values.smallSpacing)
            }
        }
    }
}

// MARK: - Plan Cells

struct PlanCell: View {
    static let radioBorderSize: CGFloat = 22
    static let radioSelectionSize: CGFloat = 17
    
    @Binding var currentSelection: Int
    @Binding var isShowingTooltip: Bool
    @Binding var suppressUntil: Date
    
    let tooltipViewId: String = "SessionProPlanScreenToolTip" // stringlint:ignore
    
    var isSelected: Bool { currentSelection == index }
    let plan: SessionProPlanScreenContent.SessionProPlanInfo
    let index: Int
    let isCurrentPlan: Bool
    
    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack {
                VStack(
                    alignment: .leading,
                    spacing: 0
                ) {
                    Text(plan.titleWithPrice)
                        .font(.Headings.H7)
                        .foregroundColor(themeColor: .textPrimary)
                        .multilineTextAlignment(.leading)
                        .frame(
                            maxWidth: .infinity,
                            alignment: .leading
                        )
                    
                    Text(plan.subtitleWithPrice)
                        .font(.Body.smallRegular)
                        .foregroundColor(themeColor: .textSecondary)
                        .frame(
                            maxWidth: .infinity,
                            alignment: .leading
                        )
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Values.verySmallSpacing)
                
                Spacer()
                
                ZStack(alignment: .center) {
                    Circle()
                        .stroke(themeColor: currentSelection == index ? .sessionButton_primaryFilledBackground : .borderSeparator)
                        .frame(
                            width: Self.radioBorderSize,
                            height: Self.radioBorderSize
                        )
                    
                    if currentSelection == index {
                        Circle()
                            .fill(themeColor: .sessionButton_primaryFilledBackground)
                            .frame(
                                width: Self.radioSelectionSize,
                                height: Self.radioSelectionSize
                            )
                    }
                }
            }
            .padding(Values.mediumSpacing)
            .frame(
                maxWidth: .infinity
            )
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(themeColor: .backgroundSecondary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(themeColor: isSelected ? .sessionButton_primaryFilledBackground : .borderSeparator)
            )
            .padding(.top, Values.smallSpacing)
            .contentShape(Rectangle())
            .onTapGesture {
                self.currentSelection = index
            }
            
            HStack (spacing: Values.smallSpacing) {
                if isCurrentPlan {
                    Text("currentPlan".localized())
                        .font(.Body.smallBold)
                        .foregroundColor(themeColor: .sessionButton_primaryFilledText)
                        .padding(.vertical, 2)
                        .padding(.horizontal, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(themeColor: .sessionButton_primaryFilledBackground)
                        )
                }
                
                if let discountPercent = plan.discountPercent {
                    HStack(spacing: Values.verySmallSpacing) {
                        Text(
                            "proPercentOff"
                                .put(key: "percent", value: discountPercent)
                                .localized()
                        )
                        .font(.Body.smallBold)
                        .foregroundColor(themeColor: .sessionButton_primaryFilledText)
                        
                        
                        if isCurrentPlan {
                            Image(systemName: "questionmark.circle")
                                .font(.Body.smallBold)
                                .foregroundColor(themeColor: .sessionButton_primaryFilledText)
                                .anchorView(viewId: tooltipViewId)
                        }
                    }
                    .padding(.vertical, 2)
                    .padding(.horizontal, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(themeColor: .sessionButton_primaryFilledBackground)
                    )
                    .onTapGesture {
                        guard isCurrentPlan else { return }
                        guard Date() >= suppressUntil else { return }
                        withAnimation {
                            isShowingTooltip.toggle()
                        }
                    }
                }
            }
            .padding(.leading, Values.mediumSpacing)
        }
    }
}
