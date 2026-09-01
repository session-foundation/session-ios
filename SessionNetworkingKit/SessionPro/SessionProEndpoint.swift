// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation

public extension Network.SessionPro {
    /// The Pro-backend route. libsession owns the endpoint<->request pairing, so the path is whatever
    /// the request builder hands back (`session_pro_backend_request.endpoint`) — we don't keep our own
    /// copies of the route strings.
    struct Endpoint: EndpointType {
        public let path: String

        public static var name: String { "SessionPro.Endpoint" }

        public init(_ path: String) {
            self.path = path
        }
    }
}
