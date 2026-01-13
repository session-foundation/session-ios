// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import UIKit

public var isIPhone5OrSmaller: Bool {
    return (((SNUIKit.initialMainScreenMaxDimension ?? 874) - 568) < 1)     /// Avoid requiring main thread
}

public var isIPhone6OrSmaller: Bool {
    return (((SNUIKit.initialMainScreenMaxDimension ?? 874) - 667) < 1)     /// Avoid requiring main thread
}

public extension UIDevice {
    var isIPad: Bool {
        let isNativeIPad: Bool = (userInterfaceIdiom == .pad)
        let isCompatabilityModeIPad: Bool = (userInterfaceIdiom == .phone && self.model.hasPrefix("iPad"))

        return isNativeIPad || isCompatabilityModeIPad
    }
}
