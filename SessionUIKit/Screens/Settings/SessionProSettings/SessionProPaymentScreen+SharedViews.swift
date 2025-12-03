// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import Lucide

// MARK: - Plan Cells

struct PlanCell: View {
    static let radioBorderSize: CGFloat = 22
    static let radioSelectionSize: CGFloat = 17
    
    @Binding var currentSelection: Int
    @Binding var isShowingTooltip: Bool
    @Binding var suppressUntil: Date
    
    let tooltipViewId: String = "SessionProPaymentScreenToolTip" // stringlint:ignore
    
    var isSelected: Bool { currentSelection == index }
    let plan: SessionProPaymentScreenContent.SessionProPlanInfo
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
                    .shadow(
                        color: .black.opacity(0.4),
                        radius: 4,
                        x: 2,
                        y: 3
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(themeColor: isSelected ? .sessionButton_text : .borderSeparator)
            )
            .padding(.top, Values.smallSpacing)
            .contentShape(Rectangle())
            .onTapGesture {
                self.currentSelection = index
            }
            
            HStack (spacing: Values.smallSpacing) {
                if isCurrentPlan {
                    Text("currentBilling".localized())
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

// MARK: - Approach Cell

struct ApproachCell: View {
    enum Variant {
        case link
        case device
        case website
        
        var icon: Lucide.Icon {
            switch self {
                case .link:
                    return .link
                case .device:
                    return .smartphone
                case .website:
                    return .globe
            }
        }
    }
    
    struct Info {
        let title: String
        let description: ThemedAttributedString
        let variant: Variant
        let action: (() -> Void)?
        
        public init(title: String, description: ThemedAttributedString, variant: Variant, action: (() -> Void)? = nil) {
            self.title = title
            self.description = description
            self.variant = variant
            self.action = action
        }
    }
    
    let info: Info
    
    init(info: Info) {
        self.info = info
    }
    
    var body: some View {
        HStack(
            alignment: .top,
            spacing: Values.mediumSpacing
        ) {
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(themeColor: .value(.primary, alpha: 0.1))
                
                AttributedText(info.variant.icon.attributedString(size: 24))
                    .foregroundColor(themeColor: .primary)
            }
            .frame(width: 34, height: 34)
            
            VStack(
                alignment: .leading,
                spacing: Values.verySmallSpacing
            ) {
                Text(info.title)
                    .font(.Body.baseBold)
                    .foregroundColor(themeColor: .textPrimary)
                
                AttributedText(info.description)
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
        .onTapGesture { info.action?() }
    }
}
