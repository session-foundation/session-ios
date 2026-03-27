// Copyright © 2026 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SwiftUI

internal func withAccessibleAnimation<Result>(
    _ animation: Animation? = .default,
    _ body: () throws -> Result
) rethrows -> Result {
    if UIAccessibility.isReduceMotionEnabled || !UIView.areAnimationsEnabled {
        try body()
    }
    else {
        try withAnimation {
            try body()
        }
    }
}
