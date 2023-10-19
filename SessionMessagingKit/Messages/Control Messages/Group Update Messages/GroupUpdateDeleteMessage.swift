// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

public final class GroupUpdateDeleteMessage: ControlMessage {
    private enum CodingKeys: String, CodingKey {
        case recipientSessionIdHexString
        case groupSessionId
        case adminSignature
    }
    
    public var recipientSessionIdHexString: String
    public var groupSessionId: SessionId
    public var adminSignature: Authentication.Signature
    
    override public var processWithBlockedSender: Bool { true }
    
    // MARK: - Initialization
    
    public init(
        recipientSessionIdHexString: String,
        groupSessionId: SessionId,
        sentTimestamp: UInt64,
        authMethod: AuthenticationMethod,
        using dependencies: Dependencies
    ) throws {
        self.recipientSessionIdHexString = recipientSessionIdHexString
        self.groupSessionId = groupSessionId
        self.adminSignature = try authMethod.generateSignature(
            with: GroupUpdateDeleteMessage.generateVerificationBytes(
                recipientSessionIdHexString: recipientSessionIdHexString,
                timestampMs: sentTimestamp
            ),
            using: dependencies
        )
        
        super.init(
            sentTimestamp: sentTimestamp
        )
    }
    
    private init(
        recipientSessionIdHexString: String,
        groupSessionId: SessionId,
        adminSignature: Authentication.Signature
    ) {
        self.recipientSessionIdHexString = recipientSessionIdHexString
        self.groupSessionId = groupSessionId
        self.adminSignature = adminSignature
        
        super.init()
    }
    
    // MARK: - Signature Generation
    
    public static func generateVerificationBytes(
        recipientSessionIdHexString: String,
        timestampMs: UInt64
    ) -> [UInt8] {
        /// Ed25519 signature of `("DELETE" || recipientSessionIdHexString || timestamp)`
        return "DELETE".bytes
            .appending(contentsOf: recipientSessionIdHexString.bytes)
            .appending(contentsOf: "\(timestampMs)".data(using: .ascii)?.bytes)
    }
    
    // MARK: - Codable
    
    required init(from decoder: Decoder) throws {
        let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
        
        recipientSessionIdHexString = try container.decode(String.self, forKey: .recipientSessionIdHexString)
        groupSessionId = SessionId(.group, publicKey: Array(try container.decode(Data.self, forKey: .groupSessionId)))
        adminSignature = Authentication.Signature.standard(
            signature: try container.decode([UInt8].self, forKey: .adminSignature)
        )
        
        try super.init(from: decoder)
    }
    
    public override func encode(to encoder: Encoder) throws {
        try super.encode(to: encoder)
        
        var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)
        
        try container.encode(recipientSessionIdHexString, forKey: .recipientSessionIdHexString)
        try container.encode(Data(groupSessionId.publicKey), forKey: .groupSessionId)
        
        switch adminSignature {
            case .standard(let signature): try container.encode(signature, forKey: .adminSignature)
            case .subaccount: throw MessageSenderError.signingFailed
        }
    }

    // MARK: - Proto Conversion
    
    public override class func fromProto(_ proto: SNProtoContent, sender: String) -> GroupUpdateDeleteMessage? {
        guard let groupDeleteMessage = proto.dataMessage?.groupUpdateMessage?.deleteMessage else { return nil }
        
        let userSessionId: SessionId = getUserSessionId()
        
        return GroupUpdateDeleteMessage(
            recipientSessionIdHexString: userSessionId.hexString,
            groupSessionId: SessionId(.group, hex: groupDeleteMessage.groupSessionID),
            adminSignature: Authentication.Signature.standard(
                signature: Array(groupDeleteMessage.adminSignature)
            )
        )
    }

    public override func toProto(_ db: Database, threadId: String) -> SNProtoContent? {
        do {
            let deleteMessageBuilder: SNProtoGroupUpdateDeleteMessage.SNProtoGroupUpdateDeleteMessageBuilder = SNProtoGroupUpdateDeleteMessage.builder(
                groupSessionID: groupSessionId.hexString,    // Include the prefix
                adminSignature: try {
                    switch adminSignature {
                        case .standard(let signature): return Data(signature)
                        case .subaccount: throw MessageSenderError.signingFailed
                    }
                }()
            )
            
            let groupUpdateMessage = SNProtoGroupUpdateMessage.builder()
            groupUpdateMessage.setDeleteMessage(try deleteMessageBuilder.build())
            
            let dataMessage = SNProtoDataMessage.builder()
            dataMessage.setGroupUpdateMessage(try groupUpdateMessage.build())
            
            let contentProto = SNProtoContent.builder()
            contentProto.setDataMessage(try dataMessage.build())
            return try contentProto.build()
        } catch {
            SNLog("Couldn't construct data extraction notification proto from: \(self).")
            return nil
        }
    }

    // MARK: - Description
    
    public var description: String {
        """
        GroupUpdateDeleteMessage(
            recipientSessionIdHexString: \(recipientSessionIdHexString),
            groupSessionId: \(groupSessionId),
            adminSignature: \(adminSignature)
        )
        """
    }
}
