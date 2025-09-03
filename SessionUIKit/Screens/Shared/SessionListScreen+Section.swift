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
        case titleWithTooltips(content: String)
        case titleNoBackgroundContent
        
        var height: CGFloat {
            switch self {
                case .none:
                    return 0
                case .titleWithTooltips, .titleNoBackgroundContent:
                    return 44
            }
        }
        
        var edgePadding: CGFloat {
            switch self {
                case .none:
                    return 0
                case .titleWithTooltips, .titleNoBackgroundContent:
                    return (Values.largeSpacing + Values.mediumSpacing)
            }
        }
    }
}

