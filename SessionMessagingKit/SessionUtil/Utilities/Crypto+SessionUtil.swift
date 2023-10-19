// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtil
import SessionUtilitiesKit

public extension Crypto.AuthenticationInfo {
    static func memberAuthData(
        config: SessionUtil.Config?,
        groupSessionId: SessionId,
        memberId: String
    ) -> Crypto.AuthenticationInfo {
        return Crypto.AuthenticationInfo(
            id: "memberAuthData",
            args: [config, groupSessionId, memberId]
        ) {
            guard case .groupKeys(let conf, _, _) = config else { throw SessionUtilError.invalidConfigObject }
            
            var cMemberId: [CChar] = memberId.cArray
            var authData: [UInt8] = [UInt8](repeating: 0, count: SessionUtil.sizeAuthDataBytes)
            
            guard groups_keys_swarm_make_subaccount(
                conf,
                &cMemberId,
                &authData
            ) else { throw SessionUtilError.failedToMakeSubAccountInGroup }
            
            return .groupMember(groupSessionId: groupSessionId, authData: Data(authData))
        }
    }
}

public extension Crypto.AuthenticationSignature {
    static func subaccountSignature(
        config: SessionUtil.Config?,
        verificationBytes: [UInt8],
        memberAuthData: Data
    ) -> Crypto.AuthenticationSignature {
        return Crypto.AuthenticationSignature(
            id: "subaccountSignature",
            args: [config, verificationBytes, memberAuthData]
        ) {
            guard case .groupKeys(let conf, _, _) = config else { throw SessionUtilError.invalidConfigObject }
            
            var verificationBytes: [UInt8] = verificationBytes
            var memberAuthData: [UInt8] = Array(memberAuthData)
            var subaccount: [UInt8] = [UInt8](repeating: 0, count: SessionUtil.sizeSubaccountBytes)
            var subaccountSig: [UInt8] = [UInt8](repeating: 0, count: SessionUtil.sizeSubaccountSigBytes)
            var signature: [UInt8] = [UInt8](repeating: 0, count: SessionUtil.sizeSubaccountSignatureBytes)
            
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
