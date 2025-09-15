// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation

@testable import SessionNetworkingKit

extension NoResponse: Mocked {
    static var mock: NoResponse = NoResponse()
}

extension Network.BatchSubResponse: MockedGeneric where T: Mocked {
    typealias Generic = T
    
    static func mock(type: T.Type) -> Network.BatchSubResponse<T> {
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

extension Network.Destination: Mocked {
    static var mock: Network.Destination = try! Network.Destination.server(
        server: "testServer",
        headers: [:],
        x25519PublicKey: ""
    ).withGeneratedUrl(for: MockEndpoint.mock)
}

extension Network.SOGS.CapabilitiesResponse: Mocked {
    static var mock: Network.SOGS.CapabilitiesResponse = Network.SOGS.CapabilitiesResponse(capabilities: [], missing: nil)
}

extension Network.SOGS.Room: Mocked {
    static var mock: Network.SOGS.Room = Network.SOGS.Room(
        token: "test",
        name: "testRoom",
        roomDescription: nil,
        infoUpdates: 1,
        messageSequence: 1,
        created: 1,
        activeUsers: 1,
        activeUsersCutoff: 1,
        imageId: nil,
        pinnedMessages: nil,
        admin: false,
        globalAdmin: false,
        admins: [],
        hiddenAdmins: nil,
        moderator: false,
        globalModerator: false,
        moderators: [],
        hiddenModerators: nil,
        read: true,
        defaultRead: nil,
        defaultAccessible: nil,
        write: true,
        defaultWrite: nil,
        upload: true,
        defaultUpload: nil
    )
}

extension Network.SOGS.RoomPollInfo: Mocked {
    static var mock: Network.SOGS.RoomPollInfo = Network.SOGS.RoomPollInfo(
        token: "test",
        activeUsers: 1,
        admin: false,
        globalAdmin: false,
        moderator: false,
        globalModerator: false,
        read: true,
        defaultRead: nil,
        defaultAccessible: nil,
        write: true,
        defaultWrite: nil,
        upload: true,
        defaultUpload: false,
        details: .mock
    )
}

extension Network.SOGS.Message: Mocked {
    static var mock: Network.SOGS.Message = Network.SOGS.Message(
        id: 100,
        sender: TestConstants.blind15PublicKey,
        posted: 1,
        edited: nil,
        deleted: nil,
        seqNo: 1,
        whisper: false,
        whisperMods: false,
        whisperTo: nil,
        base64EncodedData: nil,
        base64EncodedSignature: nil,
        reactions: nil
    )
}

extension Network.SOGS.SendDirectMessageResponse: Mocked {
    static var mock: Network.SOGS.SendDirectMessageResponse = Network.SOGS.SendDirectMessageResponse(
        id: 1,
        sender: TestConstants.blind15PublicKey,
        recipient: "testRecipient",
        posted: 1122,
        expires: 2233
    )
}

extension Network.SOGS.DirectMessage: Mocked {
    static var mock: Network.SOGS.DirectMessage = Network.SOGS.DirectMessage(
        id: 101,
        sender: TestConstants.blind15PublicKey,
        recipient: "testRecipient",
        posted: 1212,
        expires: 2323,
        base64EncodedMessage: "TestMessage".data(using: .utf8)!.base64EncodedString()
    )
}
