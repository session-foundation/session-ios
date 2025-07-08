// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

public extension Dependencies {
    func notifyAsync(_ key: ObservableKey, value: AnyHashable?) {
        Task(priority: .userInitiated) { [dependencies = self] in
            await dependencies[singleton: .observationManager].notify(key, value: value)
        }
    }
}
