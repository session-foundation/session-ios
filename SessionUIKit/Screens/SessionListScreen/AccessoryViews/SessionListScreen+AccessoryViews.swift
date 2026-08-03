// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import Lucide

public extension SessionListScreenContent {
    struct ListItemAccessory: Hashable, Equatable {
        @ViewBuilder public let accessoryView: () -> AnyView
        let padding: CGFloat
        
        public init<Accessory: View>(
            padding: CGFloat = 0,
            @ViewBuilder accessoryView: @escaping () -> Accessory
        ) {
            self.padding = padding
            self.accessoryView = { accessoryView().eraseToAnyView() }
        }
        
        public func hash(into hasher: inout Hasher) {}
        public static func == (lhs: ListItemAccessory, rhs: ListItemAccessory) -> Bool {
            return false
        }
    }
}

// MARK: - HighlightingBackgroundLabel

public extension SessionListScreenContent.ListItemAccessory {
    /// A pill-shaped label on the trailing edge of a row, used for the "tap to do the thing" actions on the developer
    /// settings screens (eg. "Reset Cache")
    ///
    /// **Note:** This matches the UIKit `SessionHighlightingBackgroundLabel` - bold `smallFontSize` text inset by
    /// `Values.smallSpacing` on a `solidButton_background` with a 5pt radius. The row owns the tap and already
    /// highlights on press, so unlike the UIKit version this doesn't track a highlighted state of its own.
    static func highlightingBackgroundLabel(
        title: String,
        accessibility: Accessibility? = nil
    ) -> SessionListScreenContent.ListItemAccessory {
        return SessionListScreenContent.ListItemAccessory(
            padding: Values.smallSpacing
        ) {
            Text(title)
                .font(.system(size: Values.smallFontSize).bold())
                .foregroundColor(themeColor: .textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(Values.smallSpacing)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(themeColor: .solidButton_background)
                )
                .accessibility(accessibility)
        }
    }
}

// MARK: - DropDown

public extension SessionListScreenContent.ListItemAccessory {
    /// A trailing "current value" label with a downward triangle, used for rows that open a picker
    ///
    /// **Note:** This matches the UIKit accessory - a 10pt `arrowtriangle.down.fill` followed by medium-weight
    /// `smallFontSize` text, the two separated by `Values.verySmallSpacing`. The UIKit version capped the label at
    /// 40% of the content width; here the surrounding `HStack` handles that, so the label just wraps rather than
    /// being given a hard cap.
    static func dropDown(
        _ title: String?,
        accessibility: Accessibility? = nil
    ) -> SessionListScreenContent.ListItemAccessory {
        return SessionListScreenContent.ListItemAccessory(
            padding: Values.smallSpacing
        ) {
            HStack(spacing: Values.verySmallSpacing) {
                Image(systemName: "arrowtriangle.down.fill")   // stringlint:ignore
                    .resizable()
                    .frame(width: 10, height: 10)
                    .foregroundColor(themeColor: .textPrimary)
                
                Text(title ?? "")
                    .font(.system(size: Values.smallFontSize, weight: .medium))
                    .foregroundColor(themeColor: .textPrimary)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibility(accessibility)
        }
    }
}
