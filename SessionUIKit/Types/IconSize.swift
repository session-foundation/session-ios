// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import DifferenceKit

public enum IconSize: Differentiable {
    case verySmall
    case small
    case medium
    case large
    case veryLarge
    case extraLarge
    
    public var size: CGFloat {
        switch self {
            case .verySmall: return 12
            case .small: return 20
            case .medium: return 24
            case .large: return 32
            case .veryLarge: return 40
            case .extraLarge: return 80
        }
    }
}
