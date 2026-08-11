// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionUtilitiesKit

public extension SessionPro {
    /// 🔴 **This is a DISPLAY state. It is not a mutex — never gate a fetch on it.**
    ///
    /// `.loading` conflates two different things: *"nothing has been fetched yet"* and *"a fetch is in flight"*.
    /// That is safe only because nothing in the app treats it as *"a request is already running, don't start
    /// another"* — every reader uses it for a spinner, a placeholder, or `== .success` as a confirmed-status
    /// gate. The single-flight mutex is `SessionProManager.isRefreshingState`, a dedicated bool read in exactly
    /// one place.
    ///
    /// **What goes wrong if you conflate them**, so this isn't an abstract rule: add a
    /// `guard loadingState != .loading` anywhere on the way into a refresh — the obvious way to avoid a
    /// duplicate request — and a process that has never fetched can never start one, because the state that
    /// would be resolved *by* the fetch is the state blocking it. The Pro screen then spins forever and no CTA
    /// can fire, since both gate on a confirmed fetch.
    ///
    /// So: single-flight belongs in the manager, freshness belongs in the refresh floor, and this type answers
    /// only *"what should the UI show, and has a fetch confirmed?"*
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
