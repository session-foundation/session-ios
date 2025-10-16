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
            
            guard !cEd25519SecretKey.isEmpty else { throw MessageSenderError.noUserED25519KeyPair }
            
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
                        nil,
                        0,
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
                        nil,
                        0,
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
                        nil,
                        0,
                        &error,
                        error.count
                    )
                    
                case .community:
                    result = session_protocol_encode_for_community(
                        cPlaintext,
                        cPlaintext.count,
                        nil,
                        0,
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
                        nil,
                        0,
                        &error,
                        error.count
                    )
            }
            defer { session_protocol_encode_for_destination_free(&result) }
            
            guard result.success else {
                Log.error(.messageSender, "Failed to encrypt due to error: \(String(cString: error))")
                throw MessageSenderError.encryptionFailed
            }
            
            return R(UnsafeBufferPointer(start: result.ciphertext.data, count: result.ciphertext.size))
        }
    }
    
    static func decodedMessage<I: DataProtocol>(
        encodedMessage: I,
        origin: Message.Origin
    ) throws -> Crypto.Generator<(proto: SNProtoContent, sender: String, sentTimestampMs: UInt64)> {
        return Crypto.Generator(
            id: "decodedMessage",
            args: []
        ) { dependencies in
            let cEncodedMessage: [UInt8] = Array(encodedMessage)
            let currentTimestampMs: UInt64 = dependencies[cache: .snodeAPI].currentOffsetTimestampMs()
            var error: [CChar] = [CChar](repeating: 0, count: 256)
            
            /// Communities have a separate decoding function to handle them first
            if case .community(_, let sender, let posted, _, _, _, _) = origin {
                var result: session_protocol_decoded_community_message = session_protocol_decode_for_community(
                    cEncodedMessage,
                    cEncodedMessage.count,
                    currentTimestampMs,
                    nil,
                    0,
                    &error,
                    error.count
                )
                defer { session_protocol_decode_for_community_free(&result) }
                
                guard result.success else {
                    Log.error(.messageSender, "Failed to decrypt community message due to error: \(String(cString: error))")
                    throw MessageReceiverError.decryptionFailed
                }
                
                let plaintext: Data = Data(UnsafeBufferPointer(start: result.content_plaintext.data, count: result.content_plaintext_unpadded_size))
                let proto: SNProtoContent = try Result(catching: { try SNProtoContent.parseData(plaintext) })
                    .onFailure { Log.error(.messageReceiver, "Couldn't parse proto due to error: \($0).") }
                    .get()
                let sentTimestampMs: UInt64 = UInt64(floor(posted * 1000))
                
                return (proto, sender, sentTimestampMs)
            }
            
            guard case .swarm(let publicKey, let namespace, let serverHash, let serverTimestampMs, let serverExpirationTimestamp) = origin else {
                throw MessageReceiverError.invalidMessage
            }
            
            /// Function to provide pointers to the keys based on the namespace the message was received from
            func withKeys<R>(
                for namespace: Network.SnodeAPI.Namespace,
                using dependencies: Dependencies,
                _ closure: (UnsafePointer<span_u8>?, Int) throws -> R
            ) throws -> R {
                let privateKeys: [[UInt8]]
                
                switch namespace {
                    case .default:
                        let ed25519SecretKey: [UInt8] = dependencies[cache: .general].ed25519SecretKey
                        
                        guard !ed25519SecretKey.isEmpty else { throw MessageReceiverError.noUserED25519KeyPair }
                        
                        privateKeys = [ed25519SecretKey]
                        
                    case .groupMessages:
                        throw MessageReceiverError.invalidMessage
                        
                    default: throw MessageReceiverError.invalidMessage
                }
                
                return try privateKeys.withUnsafeSpanOfSpans { cPrivateKeys, cPrivateKeysLen in
                    try closure(cPrivateKeys, cPrivateKeysLen)
                }
            }
            
            return try withKeys(for: namespace, using: dependencies) { cPrivateKeys, cPrivateKeysLen in
                let cEncodedMessage: [UInt8] = Array(encodedMessage)
                var cKeys: session_protocol_decode_envelope_keys = session_protocol_decode_envelope_keys()
                cKeys.set(\.ed25519_privkeys, to: cPrivateKeys)
                cKeys.set(\.ed25519_privkeys_len, to: cPrivateKeysLen)
                
                var result: session_protocol_decoded_envelope = session_protocol_decode_envelope(
                    &cKeys,
                    cEncodedMessage,
                    cEncodedMessage.count,
                    currentTimestampMs,
                    nil,
                    0,
                    &error,
                    error.count
                )
                defer { session_protocol_decode_envelope_free(&result) }
                
                guard result.success else {
                    Log.error(.messageSender, "Failed to decrypt message due to error: \(String(cString: error))")
                    throw MessageReceiverError.decryptionFailed
                }
                
                let plaintext: Data = Data(UnsafeBufferPointer(start: result.content_plaintext.data, count: result.content_plaintext.size))
                let proto: SNProtoContent = try Result(catching: { try SNProtoContent.parseData(plaintext) })
                    .onFailure { Log.error(.messageReceiver, "Couldn't parse proto due to error: \($0).") }
                    .get()
                let sender: SessionId = SessionId(.standard, publicKey: result.get(\.sender_x25519_pubkey))
                
                return (proto, sender.hexString, result.envelope.timestamp_ms)
            }
        }
    }
    
    static func plaintextForGroupMessage(
        groupSessionId: SessionId,
        ciphertext: [UInt8]
    ) throws -> Crypto.Generator<(plaintext: Data, sender: String)> {
        return Crypto.Generator(
            id: "plaintextForGroupMessage",
            args: [groupSessionId, ciphertext]
        ) { dependencies in
            return try dependencies.mutate(cache: .libSession) { cache in
                guard let config: LibSession.Config = cache.config(for: .groupKeys, sessionId: groupSessionId) else {
                    throw LibSessionError.invalidConfigObject(wanted: .groupKeys, got: nil)
                }
                guard case .groupKeys(let conf, _, _) = config else {
                    throw LibSessionError.invalidConfigObject(wanted: .groupKeys, got: config)
                }
                
                var cSessionId: [CChar] = [CChar](repeating: 0, count: 67)
                var maybePlaintext: UnsafeMutablePointer<UInt8>? = nil
                var plaintextLen: Int = 0
                let didDecrypt: Bool = groups_keys_decrypt_message(
                    conf,
                    ciphertext,
                    ciphertext.count,
                    &cSessionId,
                    &maybePlaintext,
                    &plaintextLen
                )
                
                // If we got a reported failure then just stop here
                guard didDecrypt else { throw MessageReceiverError.decryptionFailed }
                
                // We need to manually free 'maybePlaintext' upon a successful decryption
                defer { free(UnsafeMutableRawPointer(mutating: maybePlaintext)) }
                
                guard
                    plaintextLen > 0,
                    let plaintext: Data = maybePlaintext
                        .map({ Data(bytes: $0, count: plaintextLen) })
                else { throw MessageReceiverError.decryptionFailed }
                
                return (plaintext, String(cString: cSessionId))
            } ?? { throw MessageReceiverError.decryptionFailed }()
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
            ) else { throw MessageSenderError.signingFailed }
            
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

extension bytes32: CAccessible & CMutable {}
extension bytes33: CAccessible & CMutable {}
extension bytes64: CAccessible & CMutable {}
extension session_protocol_decode_envelope_keys: CAccessible & CMutable {}
extension session_protocol_decoded_envelope: CAccessible & CMutable {}
