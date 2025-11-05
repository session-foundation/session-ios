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
    static func test(using dependencies: Dependencies) {
        let masterKeyPair: KeyPair = try! dependencies[singleton: .crypto].tryGenerate(.ed25519KeyPair())
        let rotatingKeyPair: KeyPair = try! dependencies[singleton: .crypto].tryGenerate(.ed25519KeyPair())
        
        Task {
            // FIXME: Make this async/await when the refactored networking is merged
            do {
                let addProProofRequest = try? Network.SessionPro.addProPaymentOrGetProProof(
                    transactionId: "12345678",
                    masterKeyPair: masterKeyPair,
                    rotatingKeyPair: rotatingKeyPair,
                    using: dependencies
                )
                let addProProofResponse = try await addProProofRequest
                    .send(using: dependencies)
                    .values
                    .first(where: { _ in true })?.1
                
                let proProofRequest = try? Network.SessionPro.getProProof(
                    masterKeyPair: masterKeyPair,
                    rotatingKeyPair: rotatingKeyPair,
                    using: dependencies
                )
                let proProofResponse = try await proProofRequest
                    .send(using: dependencies)
                    .values
                    .first(where: { _ in true })?.1
                
                let proStatusRequest = try? Network.SessionPro.getProStatus(
                    masterKeyPair: masterKeyPair,
                    using: dependencies
                )
                let proStatusResponse = try await proStatusRequest
                    .send(using: dependencies)
                    .values
                    .first(where: { _ in true })?.1
                
                await MainActor.run {
                    let tmp1 = addProProofResponse
                    let tmp2 = proProofResponse
                    let tmp3 = proStatusResponse
                    print("RAWR Test Success")
                }
            }
            catch {
                print("RAWR Test Error")
            }
        }
    }
    
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
                ),
                using: dependencies
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
                ),
                using: dependencies
            ),
            responseType: AddProPaymentOrGetProProofResponse.self,
            using: dependencies
        )
    }
    
    static func getProStatus(
        count: UInt32 = 1,
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
                count
            )
        )
        
        return try Network.PreparedRequest(
            request: try Request<GetProStatusRequest, Endpoint>(
                method: .post,
                endpoint: .getProStatus,
                body: GetProStatusRequest(
                    masterPublicKey: masterKeyPair.publicKey,
                    timestampMs: timestampMs,
                    count: count,
                    signature: signature
                ),
                using: dependencies
            ),
            responseType: GetProStatusResponse.self,
            using: dependencies
        )
    }
}
