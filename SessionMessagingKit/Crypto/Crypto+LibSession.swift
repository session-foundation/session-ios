// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtil
import SessionUtilitiesKit

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
    
    static func ciphertextForDestination<I: DataProtocol, R: RangeReplaceableCollection>(
        plaintext: I,
        destination: Message.Destination,
        sentTimestampMs: UInt64
    ) throws -> Crypto.Generator<R> where R.Element == UInt8 {
        return Crypto.Generator(
            id: "ciphertextForDestination",
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
                    
                case .closedGroup(let pubkey):
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
                    
                case .openGroupInbox(_, let serverPubkey, let recipientPubkey):
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
                    
                case .openGroup:
                    result = session_protocol_encode_for_community(
                        cPlaintext,
                        cPlaintext.count,
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
