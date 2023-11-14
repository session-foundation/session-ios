// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import GRDB
import SessionUtilitiesKit

public final class GroupUpdateDeleteMessage: ControlMessage, NotProtoConvertible {
    public static let minDeletedMemberIdLength: Int = (66 + 1)  // (SessionId || GROUP_KEYS Gen)
    
    public struct Content: Codable, Equatable, CustomStringConvertible {
        private enum CodingKeys: String, CodingKey {
            case encryptedDeletedMemberIdData = "d"
        }
        
        public var encryptedDeletedMemberIdData: [Data]
        
        // MARK: - Description
        
        public var description: String {
            let mergedEncDeletedMemberIdData: String = encryptedDeletedMemberIdData
                .map { $0.toHexString() }
                .joined(separator: ", ")
            
            return """
            {
                encryptedDeletedMemberIdData: [\(mergedEncDeletedMemberIdData)]
            }
            """
        }
    }
    
    public let content: Content
    public let adminSignature: Authentication.Signature
    
    override public var processWithBlockedSender: Bool { true }
    
    // MARK: - Validation
    
    public override func isValid(using dependencies: Dependencies) -> Bool {
        switch adminSignature {
            case .standard: return true
            case .subaccount: return false
        }
    }
    
    // MARK: - Initialization
    
    public init(
        encryptedDeletedMemberIdData: [Data],
        authMethod: AuthenticationMethod,
        using dependencies: Dependencies
    ) throws {
        self.content = Content(
            encryptedDeletedMemberIdData: encryptedDeletedMemberIdData
        )
        self.adminSignature = try authMethod.generateSignature(
            with: GroupUpdateDeleteMessage.generateVerificationBytes(
                content: content
            ),
            using: dependencies
        )
        
        super.init()
    }
    
    private init(
        content: Content,
        adminSignature: Authentication.Signature
    ) {
        self.content = content
        self.adminSignature = adminSignature
        
        super.init()
    }
    
    // MARK: - Signature Generation
    
    public static func generateVerificationBytes(
        content: Content
    ) -> [UInt8] {
        /// Ed25519 signature of `(encryptedDeletedMemberIdData[0] || ... || encryptedDeletedMemberIdData[N])`
        return Array(content.encryptedDeletedMemberIdData.map { Array($0) }.joined())
    }
    
    // MARK: - Codable
    
    required init(from decoder: Decoder) throws {
        var container: UnkeyedDecodingContainer = try decoder.unkeyedContainer()
        
        content = try container.decode(Content.self)
        adminSignature = Authentication.Signature.standard(
            signature: try container.decodeAdditionalData([UInt8].self)
        )
        
        /// We intentionally don't call `super.init(from decoder:)` here as the `GroupUpdateDeleteMessage`
        /// doesn't use any of the `super` properties and has custom encoding/decoding to support both `Bencode`
        /// and `JSON` which will break as the `Message` expects it to be using a `KeyedDecodingContainer`
        super.init()
    }
    
    override public func encode(to encoder: Encoder) throws {
        var container: UnkeyedEncodingContainer = encoder.unkeyedContainer()
        try container.encode(self.content)
        
        switch adminSignature {
            case .standard(let signature): try container.encodeAdditionalData(signature)
            case .subaccount: throw MessageSenderError.signingFailed
        }
    }
    
    // MARK: - Description
    
    public var description: String {
        """
        GroupUpdateDeleteMessage(
            content: \(content),
            adminSignature: \(adminSignature)
        )
        """
    }
}
