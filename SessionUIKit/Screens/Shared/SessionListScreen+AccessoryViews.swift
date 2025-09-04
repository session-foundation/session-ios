// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import Lucide

public extension SessionListScreenContent {
    struct TextInfo: Hashable, Equatable {
        public enum Accessory: Hashable, Equatable {
            case proBadgeLeading
            case proBadgeTrailing
            case none
        }
        
        let text: String?
        let font: Font?
        let attributedString: ThemedAttributedString?
        let alignment: TextAlignment
        let color: ThemeValue
        let accessory: Accessory
        let accessibility: Accessibility?
        
        public init(
            _ text: String? = nil,
            font: Font? = nil,
            attributedString: ThemedAttributedString? = nil,
            alignment: TextAlignment = .leading,
            color: ThemeValue = .textPrimary,
            accessory: Accessory = .none,
            accessibility: Accessibility? = nil
        ) {
            self.text = text
            self.font = font
            self.attributedString = attributedString
            self.alignment = alignment
            self.color = color
            self.accessory = accessory
            self.accessibility = accessibility
        }
        
        // MARK: - Conformance
        
        public func hash(into hasher: inout Hasher) {
            text.hash(into: &hasher)
            font.hash(into: &hasher)
            attributedString.hash(into: &hasher)
            alignment.hash(into: &hasher)
            color.hash(into: &hasher)
            accessory.hash(into: &hasher)
            accessibility.hash(into: &hasher)
        }
        
        public static func == (lhs: TextInfo, rhs: TextInfo) -> Bool {
            return (
                lhs.text == rhs.text &&
                lhs.font == rhs.font &&
                lhs.attributedString == rhs.attributedString &&
                lhs.alignment == rhs.alignment &&
                lhs.color == rhs.color &&
                lhs.accessory == rhs.accessory &&
                lhs.accessibility == rhs.accessibility
            )
        }
    }
    
    struct ListItemAccessory: Hashable, Equatable {
        @ViewBuilder public let accessoryView: () -> AnyView
        
        public init<Accessory: View>(
            @ViewBuilder accessoryView: @escaping () -> Accessory
        ) {
            self.accessoryView = { AnyView(accessoryView()) }
        }
        
        public func hash(into hasher: inout Hasher) {}
        public static func == (lhs: ListItemAccessory, rhs: ListItemAccessory) -> Bool {
            return false
        }
        
        // MARK: - DSL
        
        public static func icon(
            _ icon: Lucide.Icon,
            size: IconSize = .medium,
            customTint: ThemeValue? = nil,
            shouldFill: Bool = false,
            accessibility: Accessibility? = nil
        ) -> ListItemAccessory {
            return .icon(
                Lucide.image(icon: icon, size: size.size),
                size: size,
                customTint: customTint,
                shouldFill: shouldFill,
                accessibility: accessibility
            )
        }
        
        public static func icon(
            _ image: UIImage?,
            size: IconSize = .medium,
            customTint: ThemeValue? = nil,
            shouldFill: Bool = false,
            accessibility: Accessibility? = nil
        ) -> ListItemAccessory {
            return ListItemAccessory {
                Image(uiImage: image ?? UIImage())
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: (shouldFill ? .fill : .fit))
                    .frame(width: size.size, height: size.size)
                    .foregroundColor(themeColor: customTint)
                    .accessibility(accessibility)
            }
        }
        
        public static func icon(
            _ image: UIImage?,
            iconSize: IconSize = .medium,
            customTint: ThemeValue? = nil,
            gradientBackgroundColors: [Color] = [],
            backgroundSize: IconSize = .veryLarge,
            backgroundCornerRadius: CGFloat = 0,
            accessibility: Accessibility? = nil
        ) -> ListItemAccessory {
            return ListItemAccessory {
                ZStack {
                    LinearGradient(
                        colors: gradientBackgroundColors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .frame(width: backgroundSize.size, height: backgroundSize.size)
                    .cornerRadius(backgroundCornerRadius)
                    
                    Image(uiImage: image ?? UIImage())
                        .renderingMode(.template)
                        .resizable()
                        .frame(width: iconSize.size, height: iconSize.size)
                        .foregroundColor(themeColor: customTint)
                        .accessibility(accessibility)
                }
            }
        }
        
        public static func toggle(
            _ value: Binding<Bool>,
            accessibility: Accessibility = Accessibility(identifier: "Switch")
        ) -> ListItemAccessory {
            return ListItemAccessory {
                Toggle(isOn: value) { EmptyView() }
                    .toggleStyle(.switch)
                    .listRowInsets(EdgeInsets())
            }
        }
    }
}
