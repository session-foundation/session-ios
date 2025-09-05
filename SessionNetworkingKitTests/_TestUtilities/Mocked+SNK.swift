// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import TestUtilities

@testable import SessionNetworkingKit

extension NoResponse: @retroactive Mocked {
    public static var any: NoResponse = NoResponse()
    public static var mock: NoResponse = NoResponse()
}

extension Network.BatchSubResponse: @retroactive MockedGeneric where T: Mocked {
    public typealias Generic = T
    
    public static func mock(type: T.Type) -> Network.BatchSubResponse<T> {
        return Network.BatchSubResponse(
            code: 200,
            headers: [:],
            body: Generic.mock,
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
    public static var mock: Network.Destination = try! Network.Destination.server(
        server: "testServer",
        headers: [:],
        x25519PublicKey: ""
    ).withGeneratedUrl(for: MockEndpoint.mock)
}

extension Network.RequestCategory: @retroactive Mocked {
    public static var any: Network.RequestCategory = .upload
    public static var mock: Network.RequestCategory = .standard
}
