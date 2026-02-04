// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import DifferenceKit

public extension SessionListScreenContent {
    protocol ListSection: Differentiable, Equatable, Hashable {
        var title: String? { get }
        var style: ListSectionStyle { get }
        var divider: Bool { get }
        var extraVerticalPadding: CGFloat { get }
        var footer: String? { get }
    }
    
    enum ListSectionStyle: Equatable, Hashable, Differentiable {
        case none
        case titleWithTooltips(info: TooltipInfo)
        case titleNoBackgroundContent
        case titleSeparator
        case padding
        case titleRoundedContent
        
        var height: CGFloat {
            switch self {
                case .none, .titleWithTooltips, .titleNoBackgroundContent, .titleRoundedContent:
                    return 0
                case .titleSeparator:
                    return Separator.height
                case .padding:
                    return Values.smallSpacing
            }
        }
        
        var cellMinHeight: CGFloat {
            switch self {
                case .titleSeparator, .none:
                    return 0
                default:
                    return 44
            }
        }
        
        var edgePadding: CGFloat {
            switch self {
                case .none, .padding:
                    return 0
                case .titleWithTooltips, .titleNoBackgroundContent, .titleRoundedContent, .titleSeparator:
                    return Values.largeSpacing
            }
        }
        
        var backgroundColor: ThemeValue {
            switch self {
                case .titleNoBackgroundContent, .titleSeparator, .none:
                    return .clear
                case .titleRoundedContent, .titleWithTooltips, .padding:
                    return .backgroundSecondary
            }
        }
    }
}

