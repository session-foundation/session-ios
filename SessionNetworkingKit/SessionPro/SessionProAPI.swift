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
                cMasterPrivateKey,
                cMasterPrivateKey.count,
                cRotatingPrivateKey,
                cRotatingPrivateKey.count,
                PaymentProvider.appStore.code,
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
                        /// App Store transaction id is the opaque `payment_id` verbatim (single-part provider)
                        providerCode: PaymentProvider.appStore.code,
                        paymentId: transactionId
                    ),
                    signatures: signatures
                ),
                overallTimeout: overallTimeout,
                using: dependencies
            ),
            responseType: Data.self,
            using: dependencies
        )
        /// Fetch the response as RAW bytes and let libsession parse them — no Codable/JSON on our side
        .map { _, data in AddProPaymentOrGenerateProProofResponse(parsing: data) }
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
        /// The wire carries whole-second timestamps; libsession signs the same value we serialise
        let timestampSeconds: Int64 = Int64(dependencies.networkOffsetTimestampMs() / 1000)
        let signatures: Signatures = try Signatures(
            session_pro_backend_generate_pro_proof_request_build_sigs(
                cMasterPrivateKey,
                cMasterPrivateKey.count,
                cRotatingPrivateKey,
                cRotatingPrivateKey.count,
                timestampSeconds
            )
        )

        return try Network.PreparedRequest(
            request: try Request<GenerateProProofRequest, Endpoint>(
                method: .post,
                endpoint: .generateProProof,
                body: GenerateProProofRequest(
                    masterPublicKey: masterKeyPair.publicKey,
                    rotatingPublicKey: rotatingKeyPair.publicKey,
                    timestampSeconds: timestampSeconds,
                    signatures: signatures
                ),
                using: dependencies
            ),
            responseType: Data.self,
            using: dependencies
        )
        /// Fetch the response as RAW bytes and let libsession parse them — no Codable/JSON on our side
        .map { _, data in AddProPaymentOrGenerateProProofResponse(parsing: data) }
    }
    
    static func getProDetails(
        count: UInt32 = 1,
        masterKeyPair: KeyPair,
        using dependencies: Dependencies
    ) throws -> Network.PreparedRequest<GetProDetailsResponse> {
        let cMasterPrivateKey: [UInt8] = masterKeyPair.secretKey
        let timestampSeconds: Int64 = Int64(dependencies.networkOffsetTimestampMs() / 1000)
        let signature: Signature = try Signature(
            session_pro_backend_get_pro_details_request_build_sig(
                cMasterPrivateKey,
                cMasterPrivateKey.count,
                timestampSeconds,
                count
            )
        )

        return try Network.PreparedRequest(
            request: try Request<GetProDetailsRequest, Endpoint>(
                method: .post,
                endpoint: .getProDetails,
                body: GetProDetailsRequest(
                    masterPublicKey: masterKeyPair.publicKey,
                    timestampSeconds: timestampSeconds,
                    count: count,
                    signature: signature
                ),
                overallTimeout: Network.defaultTimeout,
                using: dependencies
            ),
            responseType: Data.self,
            using: dependencies
        )
        .map { _, data in GetProDetailsResponse(parsing: data) }
    }
    
    static func getProRevocations(
        ticket: Int64,
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
            responseType: Data.self,
            using: dependencies
        )
        .map { _, data in GetProRevocationsResponse(parsing: data) }
    }
    
    static func setPaymentRefundRequested(
        transactionId: String,
        refundRequestedTimestampMs: UInt64,
        masterKeyPair: KeyPair,
        using dependencies: Dependencies
    ) throws -> Network.PreparedRequest<SetPaymentRefundRequestedResponse> {
        let cMasterPrivateKey: [UInt8] = masterKeyPair.secretKey
        let timestampSeconds: Int64 = Int64(dependencies.networkOffsetTimestampMs() / 1000)
        let refundRequestedTimestampSeconds: Int64 = Int64(refundRequestedTimestampMs / 1000)
        let cTransactionId: [UInt8] = Array(transactionId.utf8)
        let signature: Signature = try Signature(
            session_pro_backend_set_payment_refund_requested_request_build_sigs(
                cMasterPrivateKey,
                cMasterPrivateKey.count,
                timestampSeconds,
                refundRequestedTimestampSeconds,
                PaymentProvider.appStore.code,
                cTransactionId,
                cTransactionId.count
            )
        )

        return try Network.PreparedRequest(
            request: try Request<SetPaymentRefundRequestedRequest, Endpoint>(
                method: .post,
                endpoint: .setPaymentRefundRequested,
                body: SetPaymentRefundRequestedRequest(
                    masterPublicKey: masterKeyPair.publicKey,
                    masterSignature: signature,
                    timestampSeconds: timestampSeconds,
                    refundRequestedTimestampSeconds: refundRequestedTimestampSeconds,
                    transaction: UserTransaction(
                        providerCode: PaymentProvider.appStore.code,
                        paymentId: transactionId
                    )
                ),
                using: dependencies
            ),
            responseType: Data.self,
            using: dependencies
        )
        .map { _, data in SetPaymentRefundRequestedResponse(parsing: data) }
    }
}
