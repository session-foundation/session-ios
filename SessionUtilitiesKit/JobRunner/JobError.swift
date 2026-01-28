// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public protocol JobError: Error {
    /// Indicates if the failure is permanent and the job should not be retried.
    var isPermanent: Bool { get }
}
