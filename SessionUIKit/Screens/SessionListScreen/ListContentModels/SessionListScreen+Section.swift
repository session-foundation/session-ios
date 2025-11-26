// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import DifferenceKit

public extension SessionListScreenContent {
    protocol ListSection: Differentiable, Equatable, Hashable {
        var title: String? { get }
        var style: ListSectionStyle { get }
        var divider: Bool { get }
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
                case .none:
                    return 0
                case .titleWithTooltips, .titleNoBackgroundContent, .titleRoundedContent:
                    return 44
                case .titleSeparator:
                    return Separator.height
                case .padding:
                    return Values.smallSpacing
            }
        }
        
        var edgePadding: CGFloat {
            switch self {
                case .none, .padding:
                    return 0
            case .titleWithTooltips, .titleNoBackgroundContent, .titleRoundedContent:
                    return (Values.largeSpacing + Values.mediumSpacing)
                case .titleSeparator:
                    return Values.largeSpacing
            }
        }
    }
}

