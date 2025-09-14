// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import TestUtilities

@testable import SessionNetworkingKit

extension NoResponse: @retroactive Mocked {
    public static let any: NoResponse = NoResponse()
    public static let mock: NoResponse = NoResponse()
}

extension Network.BatchSubResponse: @retroactive Mocked where T: Mocked {
    public static var any: Network.BatchSubResponse<T> {
        Network.BatchSubResponse(
            code: .any,
            headers: .any,
            body: T.any,
            failedToParseBody: .any
        )
    }
    public static var mock: Network.BatchSubResponse<T> {
        Network.BatchSubResponse(
            code: 200,
            headers: [:],
            body: T.mock,
            failedToParseBody: false
        )
    }
}

extension Network.BatchSubResponse {
    static func mockArrayValue<M: Mocked>(type: M.Type) -> Network.BatchSubResponse<Array<M>> {
        return Network.BatchSubResponse(
            code: 200,
            headers: [:],
            body: [M.mock],
            failedToParseBody: false
        )
    }
}

extension Network.Destination: @retroactive Mocked {
    public static var any: Network.Destination = Network.Destination.server(
        server: .any,
        headers: .any,
        x25519PublicKey: .any
    )
    public static var mock: Network.Destination = Network.Destination.server(
        server: "testServer",
        headers: [:],
        x25519PublicKey: ""
    )
}

extension Network.RequestCategory: @retroactive Mocked {
    public static var any: Network.RequestCategory = .invalid
    public static var mock: Network.RequestCategory = .standard
}
