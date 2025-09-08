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
    
    private var delegate: SessionProManagerType?
    private let variant: Variant
    
    public init(_ delegate: SessionProManagerType?, variant: Variant) {
        self.delegate = delegate
        self.variant = variant
        if
            let currentPlan = delegate?.currentPlan,
            let plans = delegate?.sessionProPlans,
            let indexOfCurrentPlan = plans.firstIndex(of: currentPlan)
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
                    
                    if let currentPlan = delegate?.currentPlan, let currentPlanExpiredOn = delegate?.currentPlanExpiredOn {
                        AttributedText(
                            (delegate?.isAutoRenewEnabled == true) ?
                                "proPlanActivatedAuto"
                                    .put(key: "app_pro", value: Constants.app_pro)
                                    .put(key: "current_plan", value: currentPlan.variant.durationString)
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
                    }
                    
                    if let sessionProPlans = delegate?.sessionProPlans {
                        ForEach(sessionProPlans.indices, id: \.self) { index in
                            PlanCell(
                                currentSelection: $currentSelection,
                                isShowingTooltip: $isShowingTooltip,
                                suppressUntil: $suppressUntil,
                                plan: sessionProPlans[index],
                                index: index,
                                isCurrentPlan: (sessionProPlans[index] == delegate?.currentPlan)
                            )
                        }
                    }
                    
                    Button {
                        
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
                                    .fill(themeColor: .sessionButton_primaryFilledBackground)
                            )
                            .padding(.vertical, Values.smallSpacing)
                    }
                    
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
                    .onTapGesture {
                        
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
                        if let discountPercent = delegate?.currentPlan?.discountPercent {
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
}

// MARK: - Variant

public extension SessionProPlanScreen {
    enum Variant {
        case purchase
        case update(isOriginatingPlatform: Bool)
        case renew
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
    let plan: SessionProPlan
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
