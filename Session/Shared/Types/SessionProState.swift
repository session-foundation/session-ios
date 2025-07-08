// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SessionUIKit
import SessionUtilitiesKit

public class SessionProState: SessionProCTADelegate {
    public let dependencies: Dependencies
    
    public init(using dependencies: Dependencies) {
        self.dependencies = dependencies
    }
    
    public func upgradeToPro(completion: (() -> Void)?) {
        dependencies.set(feature: .mockCurrentUserSessionPro, to: true)
        completion?()
    }
}
