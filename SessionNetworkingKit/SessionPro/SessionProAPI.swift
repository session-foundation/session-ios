// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import Combine
import SessionUtil
import SessionUtilitiesKit

// MARK: - Log.Category

public extension Log.Category {
    static let sessionPro: Log.Category = .create("SessionPro", defaultLevel: .info)
}

public extension Network.SessionPro {
    static func test(using dependencies: Dependencies) throws -> Network.PreparedRequest<AddProPaymentOrGetProProofResponse> {
        let masterKeyPair: KeyPair = try dependencies[singleton: .crypto].tryGenerate(.ed25519KeyPair())
        let rotatingKeyPair: KeyPair = try dependencies[singleton: .crypto].tryGenerate(.ed25519KeyPair())
        let cMasterPrivateKey: [UInt8] = masterKeyPair.secretKey
        let cRotatingPrivateKey: [UInt8] = rotatingKeyPair.secretKey
        
        let cTransactionId: [UInt8] = try dependencies[singleton: .crypto].tryGenerate(.randomBytes(32))
        let transactionId: String = cTransactionId.toHexString()
        
        let cSigs: session_pro_backend_master_rotating_signatures = session_pro_backend_add_pro_payment_request_build_sigs(
            Network.SessionPro.apiVersion,
            cMasterPrivateKey,
            cMasterPrivateKey.count,
            cRotatingPrivateKey,
            cRotatingPrivateKey.count,
            PaymentProvider.appStore.libSessionValue,
            cTransactionId,
            cTransactionId.count
        )
        
        let signatures: Signatures = try Signatures(cSigs)
        let request: AddProPaymentRequest = AddProPaymentRequest(
            masterPublicKey: masterKeyPair.publicKey,
            rotatingPublicKey: rotatingKeyPair.publicKey,
            paymentTransaction: UserTransaction(
                provider: .appStore,
                paymentId: cTransactionId.toHexString()
            ),
            signatures: signatures
        )
        
        return try Network.PreparedRequest(
            request: try Request<AddProPaymentRequest, Endpoint>(
                method: .post,
                endpoint: .addProPayment,
                body: AddProPaymentRequest(
                    masterPublicKey: masterKeyPair.publicKey,
                    rotatingPublicKey: rotatingKeyPair.publicKey,
                    paymentTransaction: UserTransaction(
                        provider: .appStore,
                        paymentId: cTransactionId.toHexString()
                    ),
                    signatures: signatures
                )
            ),
            responseType: AddProPaymentOrGetProProofResponse.self,
            using: dependencies
        )
    }
}
