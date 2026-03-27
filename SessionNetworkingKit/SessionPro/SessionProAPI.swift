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
            do {
                let addProProofRequest = try? Network.SessionPro.addProPayment(
                    transactionId: "12345678",
                    masterKeyPair: masterKeyPair,
                    rotatingKeyPair: rotatingKeyPair,
                    overallTimeout: 5,
                    using: dependencies
                )
                let addProProofResponse: AddProPaymentOrGenerateProProofResponse? = try await addProProofRequest?
                    .send(using: dependencies)
                
                let proProofRequest = try? Network.SessionPro.generateProProof(
                    masterKeyPair: masterKeyPair,
                    rotatingKeyPair: rotatingKeyPair,
                    using: dependencies
                )
                let proProofResponse: AddProPaymentOrGenerateProProofResponse? = try await proProofRequest?
                    .send(using: dependencies)
                
                let proDetailsRequest = try? Network.SessionPro.getProDetails(
                    masterKeyPair: masterKeyPair,
                    using: dependencies
                )
                let proDetailsResponse: GetProDetailsResponse? = try await proDetailsRequest?
                    .send(using: dependencies)
                
                let proRevocationsRequest = try? Network.SessionPro.getProRevocations(
                    ticket: 0,
                    using: dependencies
                )
                let proRevocationsResponse: GetProRevocationsResponse? = try await proRevocationsRequest?
                    .send(using: dependencies)
                
                await MainActor.run {
                    let tmp1 = addProProofResponse
                    let tmp2 = proProofResponse
                    let tmp3 = proDetailsResponse
                    let tmp4 = proRevocationsResponse
                    print("RAWR Test Success")
                }
            }
            catch {
                print("RAWR Test Error")
            }
        }
    }
    
    static func addProPayment(
        transactionId: String,
        masterKeyPair: KeyPair,
        rotatingKeyPair: KeyPair,
        overallTimeout: TimeInterval,
        using dependencies: Dependencies
    ) throws -> Network.PreparedRequest<AddProPaymentOrGenerateProProofResponse> {
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
                cTransactionId.count,
                [], /// The `order_id` is only needed for Google transactions
                0
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
                        paymentId: transactionId,
                        orderId: "" /// The `order_id` is only needed for Google transactions
                    ),
                    signatures: signatures
                ),
                overallTimeout: overallTimeout,
                using: dependencies
            ),
            responseType: AddProPaymentOrGenerateProProofResponse.self,
            using: dependencies
        )
    }
    
    /// Generate a pro proof for the provided `rotatingKeyPair`
    ///
    /// **Note:** If the user doesn't currently have an active Session Pro subscription then this will return an error
    static func generateProProof(
        masterKeyPair: KeyPair,
        rotatingKeyPair: KeyPair,
        using dependencies: Dependencies
    ) throws -> Network.PreparedRequest<AddProPaymentOrGenerateProProofResponse> {
        let cMasterPrivateKey: [UInt8] = masterKeyPair.secretKey
        let cRotatingPrivateKey: [UInt8] = rotatingKeyPair.secretKey
        let timestampMs: UInt64 = dependencies.networkOffsetTimestampMs()
        let signatures: Signatures = try Signatures(
            session_pro_backend_generate_pro_proof_request_build_sigs(
                Network.SessionPro.apiVersion,
                cMasterPrivateKey,
                cMasterPrivateKey.count,
                cRotatingPrivateKey,
                cRotatingPrivateKey.count,
                timestampMs
            )
        )
        
        return try Network.PreparedRequest(
            request: try Request<GenerateProProofRequest, Endpoint>(
                method: .post,
                endpoint: .generateProProof,
                body: GenerateProProofRequest(
                    masterPublicKey: masterKeyPair.publicKey,
                    rotatingPublicKey: rotatingKeyPair.publicKey,
                    timestampMs: timestampMs,
                    signatures: signatures
                ),
                using: dependencies
            ),
            responseType: AddProPaymentOrGenerateProProofResponse.self,
            using: dependencies
        )
    }
    
    static func getProDetails(
        count: UInt32 = 1,
        masterKeyPair: KeyPair,
        using dependencies: Dependencies
    ) throws -> Network.PreparedRequest<GetProDetailsResponse> {
        let cMasterPrivateKey: [UInt8] = masterKeyPair.secretKey
        let timestampMs: UInt64 = dependencies.networkOffsetTimestampMs()
        let signature: Signature = try Signature(
            session_pro_backend_get_pro_details_request_build_sig(
                Network.SessionPro.apiVersion,
                cMasterPrivateKey,
                cMasterPrivateKey.count,
                timestampMs,
                count
            )
        )
        
        return try Network.PreparedRequest(
            request: try Request<GetProDetailsRequest, Endpoint>(
                method: .post,
                endpoint: .getProDetails,
                body: GetProDetailsRequest(
                    masterPublicKey: masterKeyPair.publicKey,
                    timestampMs: timestampMs,
                    count: count,
                    signature: signature
                ),
                using: dependencies
            ),
            responseType: GetProDetailsResponse.self,
            using: dependencies
        )
    }
    
    static func getProRevocations(
        ticket: UInt32,
        using dependencies: Dependencies
    ) throws -> Network.PreparedRequest<GetProRevocationsResponse> {
        return try Network.PreparedRequest(
            request: try Request<GetProRevocationsRequest, Endpoint>(
                method: .post,
                endpoint: .getProRevocations,
                body: GetProRevocationsRequest(
                    ticket: ticket
                ),
                using: dependencies
            ),
            responseType: GetProRevocationsResponse.self,
            using: dependencies
        )
    }
    
    static func setPaymentRefundRequested(
        transactionId: String,
        refundRequestedTimestampMs: UInt64,
        masterKeyPair: KeyPair,
        using dependencies: Dependencies
    ) throws -> Network.PreparedRequest<SetPaymentRefundRequestedResponse> {
        let cMasterPrivateKey: [UInt8] = masterKeyPair.secretKey
        let timestampMs: UInt64 = dependencies.networkOffsetTimestampMs()
        let cTransactionId: [UInt8] = Array(transactionId.utf8)
        let signature: Signature = try Signature(
            session_pro_backend_set_payment_refund_requested_request_build_sigs(
                Network.SessionPro.apiVersion,
                cMasterPrivateKey,
                cMasterPrivateKey.count,
                timestampMs,
                refundRequestedTimestampMs,
                PaymentProvider.appStore.libSessionValue,
                cTransactionId,
                cTransactionId.count,
                [], /// The `order_id` is only needed for Google transactions
                0
            )
        )
        
        return try Network.PreparedRequest(
            request: try Request<SetPaymentRefundRequestedRequest, Endpoint>(
                method: .post,
                endpoint: .getProRevocations,
                body: SetPaymentRefundRequestedRequest(
                    masterPublicKey: masterKeyPair.publicKey,
                    masterSignature: signature,
                    timestampMs: timestampMs,
                    refundRequestedTimestampMs: refundRequestedTimestampMs,
                    transaction: UserTransaction(
                        provider: .appStore,
                        paymentId: transactionId,
                        orderId: "" /// The `order_id` is only needed for Google transactions
                    )
                ),
                using: dependencies
            ),
            responseType: SetPaymentRefundRequestedResponse.self,
            using: dependencies
        )
    }
}
