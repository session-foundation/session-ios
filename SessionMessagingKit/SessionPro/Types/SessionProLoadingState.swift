// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionUtilitiesKit

public extension SessionPro {
    /// This is a DISPLAY state. It is not a mutex — never gate a fetch on it.
    ///
    /// `.loading` conflates "nothing fetched yet" with "a fetch is in flight", which is safe only because every
    /// reader uses it for a spinner, a placeholder, or `== .success` as a confirmed-status gate. The single-flight
    /// mutex is `SessionProManager.isRefreshingState`.
    ///
    /// Gating a refresh on `!= .loading` means a process that has never fetched can never start one, because the
    /// state the fetch would resolve is the state blocking it — the Pro screen then spins forever and no CTA fires.
    enum LoadingState: Sendable, CaseIterable, Equatable, CustomStringConvertible {
        case loading
        case error
        case success
        
        public var description: String {
            switch self {
                case .loading: return "Loading"
                case .error: return "Error"
                case .success: return "Success"
            }
        }
    }
}
