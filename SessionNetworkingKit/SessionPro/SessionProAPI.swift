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
    static func addProPaymentOrGetProProof(
        transactionId: String,
        masterKeyPair: KeyPair,
        rotatingKeyPair: KeyPair,
        using dependencies: Dependencies
    ) throws -> Network.PreparedRequest<AddProPaymentOrGetProProofResponse> {
        let cMasterPrivateKey: [UInt8] = masterKeyPair.secretKey
        let cRotatingPrivateKey: [UInt8] = rotatingKeyPair.secretKey
        let cTransactionId: [UInt8] = Array(transactionId.utf8)
        let signatures: Signatures = try Signatures(
            session_pro_backend_add_pro_payment_request_build_sigs(
                Network.SessionPro.apiVersion,
                cMasterPrivateKey,
                cMasterPrivateKey.count,
                cRotatingPrivateKey,
                cRotatingPrivateKey.count,
                PaymentProvider.appStore.libSessionValue,
                cTransactionId,
                cTransactionId.count
            )
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
                        paymentId: transactionId
                    ),
                    signatures: signatures
                )
            ),
            responseType: AddProPaymentOrGetProProofResponse.self,
            using: dependencies
        )
    }
    
    static func getProProof(
        masterKeyPair: KeyPair,
        rotatingKeyPair: KeyPair,
        using dependencies: Dependencies
    ) throws -> Network.PreparedRequest<AddProPaymentOrGetProProofResponse> {
        let cMasterPrivateKey: [UInt8] = masterKeyPair.secretKey
        let cRotatingPrivateKey: [UInt8] = rotatingKeyPair.secretKey
        let timestampMs: UInt64 = dependencies[cache: .snodeAPI].currentOffsetTimestampMs()
        let signatures: Signatures = try Signatures(
            session_pro_backend_get_pro_proof_request_build_sigs(
                Network.SessionPro.apiVersion,
                cMasterPrivateKey,
                cMasterPrivateKey.count,
                cRotatingPrivateKey,
                cRotatingPrivateKey.count,
                timestampMs
            )
        )
        
        return try Network.PreparedRequest(
            request: try Request<GetProProofRequest, Endpoint>(
                method: .post,
                endpoint: .getProProof,
                body: GetProProofRequest(
                    masterPublicKey: masterKeyPair.publicKey,
                    rotatingPublicKey: rotatingKeyPair.publicKey,
                    timestampMs: timestampMs,
                    signatures: signatures
                )
            ),
            responseType: AddProPaymentOrGetProProofResponse.self,
            using: dependencies
        )
    }
    
    static func getProStatus(
        includeHistory: Bool = false,
        masterKeyPair: KeyPair,
        using dependencies: Dependencies
    ) throws -> Network.PreparedRequest<GetProStatusResponse> {
        let cMasterPrivateKey: [UInt8] = masterKeyPair.secretKey
        let timestampMs: UInt64 = dependencies[cache: .snodeAPI].currentOffsetTimestampMs()
        let signature: Signature = try Signature(
            session_pro_backend_get_pro_status_request_build_sig(
                Network.SessionPro.apiVersion,
                cMasterPrivateKey,
                cMasterPrivateKey.count,
                timestampMs,
                includeHistory
            )
        )
        
        return try Network.PreparedRequest(
            request: try Request<GetProStatusRequest, Endpoint>(
                method: .post,
                endpoint: .getProStatus,
                body: GetProStatusRequest(
                    masterPublicKey: masterKeyPair.publicKey,
                    timestampMs: timestampMs,
                    includeHistory: includeHistory,
                    signature: signature
                )
            ),
            responseType: GetProStatusResponse.self,
            using: dependencies
        )
    }
}
