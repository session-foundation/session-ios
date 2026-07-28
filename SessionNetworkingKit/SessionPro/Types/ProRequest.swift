// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtil
import SessionUtilitiesKit

public extension Network.SessionPro {
    /// A ready-to-POST Pro request, built entirely by libsession. libsession returns the route, the
    /// content-type and the opaque body bytes; the client relays them verbatim and never builds or
    /// inspects the wire format itself (signing, serialisation and endpoint pairing all live in
    /// libsession). `build` is the matching `session_pro_backend_*_request_build(...)` call — we read
    /// the fields out of the owning C struct and free it.
    struct ProRequest {
        public let endpoint: Endpoint
        public let contentType: String
        public let body: Data

        init(_ build: () -> session_pro_backend_request) throws {
            var cRequest: session_pro_backend_request = build()
            defer { session_pro_backend_request_free(&cRequest) }

            guard cRequest.success else {
                let error: String = withUnsafeBytes(of: cRequest.error) { raw in
                    guard let base: UnsafeRawPointer = raw.baseAddress else { return "" }
                    return String(cString: base.assumingMemoryBound(to: CChar.self))
                }
                Log.error([.network, .sessionPro], "Failed to build Pro request: \(error)")
                throw CryptoError.signatureGenerationFailed
            }

            self.endpoint = Endpoint(String(cString: cRequest.endpoint))
            self.contentType = String(cString: cRequest.content_type)
            self.body = cRequest.data.data.map { Data(bytes: $0, count: cRequest.data.size) } ?? Data()
        }
    }
}
