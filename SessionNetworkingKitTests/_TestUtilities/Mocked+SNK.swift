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

extension Network.SOGS.CapabilitiesResponse: @retroactive Mocked {
    public static var any: Network.SOGS.CapabilitiesResponse = Network.SOGS.CapabilitiesResponse(
        capabilities: .any,
        missing: .any
    )
    public static var mock: Network.SOGS.CapabilitiesResponse = Network.SOGS.CapabilitiesResponse(
        capabilities: [],
        missing: nil
    )
}

extension Network.SOGS.Room: @retroactive Mocked {
    public static var any:  Network.SOGS.Room = Network.SOGS.Room(
        token: .any,
        name: .any,
        roomDescription: .any,
        infoUpdates: .any,
        messageSequence: .any,
        created: .any,
        activeUsers: .any,
        activeUsersCutoff: .any,
        imageId: .any,
        pinnedMessages: .any,
        admin: .any,
        globalAdmin: .any,
        admins: .any,
        hiddenAdmins: .any,
        moderator: .any,
        globalModerator: .any,
        moderators: .any,
        hiddenModerators: .any,
        read: .any,
        defaultRead: .any,
        defaultAccessible: .any,
        write: .any,
        defaultWrite: .any,
        upload: .any,
        defaultUpload: .any
    )

    public static var mock: Network.SOGS.Room = Network.SOGS.Room(
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

extension Network.SOGS.RoomPollInfo: @retroactive Mocked {
    public static var any: Network.SOGS.RoomPollInfo = Network.SOGS.RoomPollInfo(
        token: .any,
        activeUsers: .any,
        admin: .any,
        globalAdmin: .any,
        moderator: .any,
        globalModerator: .any,
        read: .any,
        defaultRead: .any,
        defaultAccessible: .any,
        write: .any,
        defaultWrite: .any,
        upload: .any,
        defaultUpload: .any,
        details: .any
    )
    public static var mock: Network.SOGS.RoomPollInfo = Network.SOGS.RoomPollInfo(
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

extension Network.SOGS.Message: @retroactive Mocked {
    public static var any: Network.SOGS.Message = Network.SOGS.Message(
        id: .any,
        sender: .any,
        posted: .any,
        edited: .any,
        deleted: .any,
        seqNo: .any,
        whisper: .any,
        whisperMods: .any,
        whisperTo: .any,
        base64EncodedData: .any,
        base64EncodedSignature: .any,
        reactions: .any
    )
    public static var mock: Network.SOGS.Message = Network.SOGS.Message(
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

extension Network.SOGS.SendDirectMessageResponse: @retroactive Mocked {
    public static var any: Network.SOGS.SendDirectMessageResponse = Network.SOGS.SendDirectMessageResponse(
        id: .any,
        sender: .any,
        recipient: .any,
        posted: .any,
        expires: .any
    )
    public static var mock: Network.SOGS.SendDirectMessageResponse = Network.SOGS.SendDirectMessageResponse(
        id: 1,
        sender: TestConstants.blind15PublicKey,
        recipient: "testRecipient",
        posted: 1122,
        expires: 2233
    )
}

extension Network.SOGS.DirectMessage: @retroactive Mocked {
    public static var any: Network.SOGS.DirectMessage = Network.SOGS.DirectMessage(
        id: .any,
        sender: .any,
        recipient: .any,
        posted: .any,
        expires: .any,
        base64EncodedMessage: .any
    )
    public static var mock: Network.SOGS.DirectMessage = Network.SOGS.DirectMessage(
        id: 101,
        sender: TestConstants.blind15PublicKey,
        recipient: "testRecipient",
        posted: 1212,
        expires: 2323,
        base64EncodedMessage: "TestMessage".data(using: .utf8)!.base64EncodedString()
    )
}
