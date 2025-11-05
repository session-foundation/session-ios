// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtil
import SessionNetworkingKit
import SessionUtilitiesKit

// MARK: - Messages

public extension Crypto.Generator {
    static func encodedMessage<I: DataProtocol, R: RangeReplaceableCollection>(
        plaintext: I,
        destination: Message.Destination,
        sentTimestampMs: UInt64
    ) throws -> Crypto.Generator<R> where R.Element == UInt8 {
        return Crypto.Generator(
            id: "encodedMessage",
            args: []
        ) { dependencies in
            let cEd25519SecretKey: [UInt8] = dependencies[cache: .general].ed25519SecretKey
            let cRotatingProPubkey: [UInt8]? = dependencies[singleton: .sessionProManager]
                .currentUserCurrentRotatingKeyPair?
                .publicKey
            
            guard !cEd25519SecretKey.isEmpty else { throw CryptoError.missingUserSecretKey }
            
            let cPlaintext: [UInt8] = Array(plaintext)
            var error: [CChar] = [CChar](repeating: 0, count: 256)
            var result: session_protocol_encoded_for_destination
            
            switch destination {
                case .contact(let pubkey):
                    var cPubkey: bytes33 = bytes33()
                    cPubkey.set(\.data, to: Data(hex: pubkey))
                    result = session_protocol_encode_for_1o1(
                        cPlaintext,
                        cPlaintext.count,
                        cEd25519SecretKey,
                        cEd25519SecretKey.count,
                        sentTimestampMs,
                        &cPubkey,
                        cRotatingProPubkey,
                        (cRotatingProPubkey?.count ?? 0),
                        &error,
                        error.count
                    )
                    
                case .syncMessage:
                    var cPubkey: bytes33 = bytes33()
                    cPubkey.set(\.data, to: Data(hex: dependencies[cache: .general].sessionId.hexString))
                    result = session_protocol_encode_for_1o1(
                        cPlaintext,
                        cPlaintext.count,
                        cEd25519SecretKey,
                        cEd25519SecretKey.count,
                        sentTimestampMs,
                        &cPubkey,
                        cRotatingProPubkey,
                        (cRotatingProPubkey?.count ?? 0),
                        &error,
                        error.count
                    )
                    
                case .group(let pubkey):
                    let currentGroupEncPrivateKey: [UInt8] = try dependencies.mutate(cache: .libSession) { cache in
                        try cache.latestGroupKey(groupSessionId: SessionId(.group, hex: pubkey))
                    }
                    
                    var cPubkey: bytes33 = bytes33()
                    var cCurrentGroupEncPrivateKey: bytes32 = bytes32()
                    cPubkey.set(\.data, to: Data(hex: pubkey))
                    cCurrentGroupEncPrivateKey.set(\.data, to: currentGroupEncPrivateKey)
                    result = session_protocol_encode_for_group(
                        cPlaintext,
                        cPlaintext.count,
                        cEd25519SecretKey,
                        cEd25519SecretKey.count,
                        sentTimestampMs,
                        &cPubkey,
                        &cCurrentGroupEncPrivateKey,
                        cRotatingProPubkey,
                        (cRotatingProPubkey?.count ?? 0),
                        &error,
                        error.count
                    )
                    
                case .community:
                    result = session_protocol_encode_for_community(
                        cPlaintext,
                        cPlaintext.count,
                        cRotatingProPubkey,
                        (cRotatingProPubkey?.count ?? 0),
                        &error,
                        error.count
                    )
                    
                case .communityInbox(_, let serverPubkey, let recipientPubkey):
                    var cServerPubkey: bytes32 = bytes32()
                    var cRecipientPubkey: bytes33 = bytes33()
                    cServerPubkey.set(\.data, to: Data(hex: serverPubkey))
                    cRecipientPubkey.set(\.data, to: Data(hex: recipientPubkey))
                    result = session_protocol_encode_for_community_inbox(
                        cPlaintext,
                        cPlaintext.count,
                        cEd25519SecretKey,
                        cEd25519SecretKey.count,
                        sentTimestampMs,
                        &cRecipientPubkey,
                        &cServerPubkey,
                        cRotatingProPubkey,
                        (cRotatingProPubkey?.count ?? 0),
                        &error,
                        error.count
                    )
            }
            defer { session_protocol_encode_for_destination_free(&result) }
            
            guard result.success else {
                Log.error(.messageSender, "Failed to encode due to error: \(String(cString: error))")
                throw MessageError.encodingFailed
            }
            
            return R(UnsafeBufferPointer(start: result.ciphertext.data, count: result.ciphertext.size))
        }
    }
    
    static func decodedMessage<I: DataProtocol>(
        encodedMessage: I,
        origin: Message.Origin
    ) throws -> Crypto.Generator<DecodedMessage> {
        return Crypto.Generator(
            id: "decodedMessage",
            args: []
        ) { dependencies in
            let cEncodedMessage: [UInt8] = Array(encodedMessage)
            let cBackendPubkey: [UInt8] = Array(Data(hex: Network.SessionPro.serverPublicKey))
            let currentTimestampMs: UInt64 = dependencies[cache: .snodeAPI].currentOffsetTimestampMs()
            var error: [CChar] = [CChar](repeating: 0, count: 256)
            
            switch origin {
                case .community(_, let sender, let posted, _, _, _, _):
                    var cResult: session_protocol_decoded_community_message = session_protocol_decode_for_community(
                        cEncodedMessage,
                        cEncodedMessage.count,
                        currentTimestampMs,
                        cBackendPubkey,
                        cBackendPubkey.count,
                        &error,
                        error.count
                    )
                    defer { session_protocol_decode_for_community_free(&cResult) }
                    
                    guard cResult.success else {
                        Log.error(.messageSender, "Failed to decode community message due to error: \(String(cString: error))")
                        throw MessageError.decodingFailed
                    }
                    
                    return try DecodedMessage(decodedValue: cResult, sender: sender, posted: posted)
                    
                case .communityInbox(let posted, _, let serverPublicKey, let senderId, let recipientId):
                    // FIXME: Fold into `session_protocol_decode_envelope` once support is added
                    let (plaintextWithPadding, sender): (Data, String) = try dependencies[singleton: .crypto].tryGenerate(
                        .plaintextWithSessionBlindingProtocol(
                            ciphertext: encodedMessage,
                            senderId: senderId,
                            recipientId: recipientId,
                            serverPublicKey: serverPublicKey
                        )
                    )
                    let plaintext: Data = plaintextWithPadding.removePadding()
                    
                    return DecodedMessage(
                        content: plaintext,
                        sender: try SessionId(from: senderId),
                        decodedEnvelope: nil,   // TODO: [PRO] If we don't set this then we won't know the pro status
                        sentTimestampMs: UInt64(floor(posted * 1000))
                    )
                    
                case .swarm(let publicKey, let namespace, _, _, _):
                    /// Function to provide pointers to the keys based on the namespace the message was received from
                    func withKeys<R>(
                        for namespace: Network.SnodeAPI.Namespace,
                        publicKey: String,
                        using dependencies: Dependencies,
                        _ closure: (span_u8, UnsafePointer<span_u8>?, Int) throws -> R
                    ) throws -> R {
                        let privateKeys: [[UInt8]]
                        let sessionId: SessionId = try SessionId(from: publicKey)
                        
                        switch namespace {
                            case .default:
                                let ed25519SecretKey: [UInt8] = dependencies[cache: .general].ed25519SecretKey
                                
                                guard !ed25519SecretKey.isEmpty else { throw CryptoError.missingUserSecretKey }
                                
                                privateKeys = [ed25519SecretKey]
                                
                            case .groupMessages:
                                guard sessionId.prefix == .group else {
                                    throw MessageError.requiresGroupId(publicKey)
                                }
                                
                                privateKeys = try dependencies.mutate(cache: .libSession) { cache in
                                    try cache.allActiveGroupKeys(groupSessionId: sessionId)
                                }
                                
                            default:
                                throw MessageError.invalidMessage("Tried to decode a message from an incorrect namespace: \(namespace)")
                        }
                        
                        /// Exclude the prefix when providing the publicKey
                        return try sessionId.publicKey.withUnsafeSpan { cPublicKey in
                            return try privateKeys.withUnsafeSpanOfSpans { cPrivateKeys, cPrivateKeysLen in
                                try closure(cPublicKey, cPrivateKeys, cPrivateKeysLen)
                            }
                        }
                    }
                    
                    return try withKeys(for: namespace, publicKey: publicKey, using: dependencies) { cPublicKey, cPrivateKeys, cPrivateKeysLen in
                        let cEncodedMessage: [UInt8] = Array(encodedMessage)
                        var cKeys: session_protocol_decode_envelope_keys = session_protocol_decode_envelope_keys()
                        cKeys.set(\.decrypt_keys, to: cPrivateKeys)
                        cKeys.set(\.decrypt_keys_len, to: cPrivateKeysLen)
                        
                        /// If it's a group message then we need to set the group pubkey
                        if namespace == .groupMessages {
                            cKeys.set(\.group_ed25519_pubkey, to: cPublicKey)
                        }
                        
                        var cResult: session_protocol_decoded_envelope = session_protocol_decode_envelope(
                            &cKeys,
                            cEncodedMessage,
                            cEncodedMessage.count,
                            currentTimestampMs,
                            cBackendPubkey,
                            cBackendPubkey.count,
                            &error,
                            error.count
                        )
                        defer { session_protocol_decode_envelope_free(&cResult) }
                        
                        guard cResult.success else {
                            Log.error(.messageReceiver, "Failed to decode message due to error: \(String(cString: error))")
                            throw MessageError.decodingFailed
                        }
                        
                        return DecodedMessage(decodedValue: cResult)
                    }
            }
        }
    }
}

// MARK: - Groups

public extension Crypto.Generator {
    static func tokenSubaccount(
        config: LibSession.Config?,
        groupSessionId: SessionId,
        memberId: String
    ) -> Crypto.Generator<[UInt8]> {
        return Crypto.Generator(
            id: "tokenSubaccount",
            args: [config, groupSessionId, memberId]
        ) {
            guard case .groupKeys(let conf, _, _) = config else {
                throw LibSessionError.invalidConfigObject(wanted: .groupKeys, got: config)
            }
            
            var cMemberId: [CChar] = try memberId.cString(using: .utf8) ?? { throw LibSessionError.invalidCConversion }()
            var tokenData: [UInt8] = [UInt8](repeating: 0, count: LibSession.sizeSubaccountBytes)
            
            guard groups_keys_swarm_subaccount_token(
                conf,
                &cMemberId,
                &tokenData
            ) else { throw LibSessionError.failedToMakeSubAccountInGroup }
            
            return tokenData
        }
    }
    
    static func memberAuthData(
        config: LibSession.Config?,
        groupSessionId: SessionId,
        memberId: String
    ) -> Crypto.Generator<Authentication.Info> {
        return Crypto.Generator(
            id: "memberAuthData",
            args: [config, groupSessionId, memberId]
        ) {
            guard case .groupKeys(let conf, _, _) = config else {
                throw LibSessionError.invalidConfigObject(wanted: .groupKeys, got: config)
            }
            
            var cMemberId: [CChar] = try memberId.cString(using: .utf8) ?? { throw LibSessionError.invalidCConversion }()
            var authData: [UInt8] = [UInt8](repeating: 0, count: LibSession.sizeAuthDataBytes)
            
            guard groups_keys_swarm_make_subaccount(
                conf,
                &cMemberId,
                &authData
            ) else { throw LibSessionError.failedToMakeSubAccountInGroup }
            
            return .groupMember(groupSessionId: groupSessionId, authData: Data(authData))
        }
    }
    
    static func signatureSubaccount(
        config: LibSession.Config?,
        verificationBytes: [UInt8],
        memberAuthData: Data
    ) -> Crypto.Generator<Authentication.Signature> {
        return Crypto.Generator(
            id: "signatureSubaccount",
            args: [config, verificationBytes, memberAuthData]
        ) {
            guard case .groupKeys(let conf, _, _) = config else {
                throw LibSessionError.invalidConfigObject(wanted: .groupKeys, got: config)
            }
            
            var verificationBytes: [UInt8] = verificationBytes
            var memberAuthData: [UInt8] = Array(memberAuthData)
            var subaccount: [UInt8] = [UInt8](repeating: 0, count: LibSession.sizeSubaccountBytes)
            var subaccountSig: [UInt8] = [UInt8](repeating: 0, count: LibSession.sizeSubaccountSigBytes)
            var signature: [UInt8] = [UInt8](repeating: 0, count: LibSession.sizeSubaccountSignatureBytes)
            
            guard groups_keys_swarm_subaccount_sign_binary(
                conf,
                &verificationBytes,
                verificationBytes.count,
                &memberAuthData,
                &subaccount,
                &subaccountSig,
                &signature
            ) else { throw CryptoError.signatureGenerationFailed }
            
            return Authentication.Signature.subaccount(
                subaccount: subaccount,
                subaccountSig: subaccountSig,
                signature: signature
            )
        }
    }
}

public extension Crypto.Verification {
    static func memberAuthData(
        groupSessionId: SessionId,
        ed25519SecretKey: [UInt8],
        memberAuthData: Data
    ) -> Crypto.Verification {
        return Crypto.Verification(
            id: "memberAuthData",
            args: [groupSessionId, ed25519SecretKey, memberAuthData]
        ) {
            guard
                var cGroupId: [CChar] = groupSessionId.hexString.cString(using: .utf8),
                ed25519SecretKey.count == 64
            else { return false }
            
            var cEd25519SecretKey: [UInt8] = ed25519SecretKey
            var cAuthData: [UInt8] = Array(memberAuthData)
            
            return groups_keys_swarm_verify_subaccount(
                &cGroupId,
                &cEd25519SecretKey,
                &cAuthData
            )
        }
    }
}

// MARK: - Session Pro

public extension Crypto.Generator {
    static func sessionProMasterKeyPair() -> Crypto.Generator<KeyPair> {
        return Crypto.Generator(
            id: "encodedMessage",
            args: []
        ) { dependencies in
            let cEd25519SecretKey: [UInt8] = dependencies[cache: .general].ed25519SecretKey
            var cMasterSecretKey: [UInt8] = [UInt8](repeating: 0, count: 256)
            
            guard !cEd25519SecretKey.isEmpty else { throw CryptoError.missingUserSecretKey }
            
            guard session_ed25519_pro_privkey_for_ed25519_seed(cEd25519SecretKey, &cMasterSecretKey) else {
                throw CryptoError.keyGenerationFailed
            }
            
            let seed: Data = try dependencies[singleton: .crypto].tryGenerate(.ed25519Seed(ed25519SecretKey: cMasterSecretKey))
            
            return try dependencies[singleton: .crypto].tryGenerate(.ed25519KeyPair(seed: seed))
        }
    }
}

extension bytes32: CAccessible & CMutable {}
extension bytes33: CAccessible & CMutable {}
extension bytes64: CAccessible & CMutable {}
extension session_protocol_decode_envelope_keys: CAccessible & CMutable {}
