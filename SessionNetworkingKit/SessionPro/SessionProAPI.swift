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
                let proProofRequest = try? Network.SessionPro.generateProProof(
                    masterKeyPair: masterKeyPair,
                    rotatingKeyPair: rotatingKeyPair,
                    using: dependencies
                )
                let proProofResponse: GenerateProProofResponse? = try await proProofRequest?
                    .send(using: dependencies)

                let proStatusRequest = try? Network.SessionPro.getProStatus(
                    masterKeyPair: masterKeyPair,
                    using: dependencies
                )
                let proStatusResponse: GetProStatusResponse? = try await proStatusRequest?
                    .send(using: dependencies)
                
                let proRevocationsRequest = try? Network.SessionPro.getProRevocations(
                    ticket: 0,
                    using: dependencies
                )
                let proRevocationsResponse: GetProRevocationsResponse? = try await proRevocationsRequest?
                    .send(using: dependencies)
                
                await MainActor.run {
                    let tmp2 = proProofResponse
                    let tmp3 = proStatusResponse
                    let tmp4 = proRevocationsResponse
                    print("RAWR Test Success")
                }
            }
            catch {
                print("RAWR Test Error")
            }
        }
    }
    
    /// Generate a pro proof for the provided `rotatingKeyPair`.
    ///
    /// Redemption is implicit: the Pro backend binds the account's unbound payments on any master-signed
    /// request, so after a purchase the client simply requests a proof here (there's no `/add_pro_payment`).
    ///
    /// **Note:** If the user doesn't currently have an active Session Pro subscription (and no in-flight
    /// payment to bind) then this will return an error.
    static func generateProProof(
        masterKeyPair: KeyPair,
        rotatingKeyPair: KeyPair,
        using dependencies: Dependencies
    ) throws -> Network.PreparedRequest<GenerateProProofResponse> {
        let masterPrivateKey: [UInt8] = masterKeyPair.secretKey
        let rotatingPrivateKey: [UInt8] = rotatingKeyPair.secretKey
        let timestampSeconds: Int64 = Int64(dependencies.networkOffsetTimestampMs() / 1000)
        let proRequest: ProRequest = try ProRequest {
            session_pro_backend_generate_pro_proof_request_build(
                masterPrivateKey,
                masterPrivateKey.count,
                rotatingPrivateKey,
                rotatingPrivateKey.count,
                timestampSeconds
            )
        }

        return try Network.PreparedRequest(
            request: try Request<Data, Endpoint>(
                method: .post,
                endpoint: proRequest.endpoint,
                headers: [.contentType: proRequest.contentType],
                body: proRequest.body,
                using: dependencies
            ),
            responseType: Data.self,
            using: dependencies
        )
        .map { _, data in GenerateProProofResponse(parsing: data) }
    }

    static func getProStatus(
        masterKeyPair: KeyPair,
        using dependencies: Dependencies
    ) throws -> Network.PreparedRequest<GetProStatusResponse> {
        let masterPrivateKey: [UInt8] = masterKeyPair.secretKey
        let timestampSeconds: Int64 = Int64(dependencies.networkOffsetTimestampMs() / 1000)
        let proRequest: ProRequest = try ProRequest {
            session_pro_backend_get_pro_status_request_build(
                masterPrivateKey,
                masterPrivateKey.count,
                timestampSeconds
            )
        }

        return try Network.PreparedRequest(
            request: try Request<Data, Endpoint>(
                method: .post,
                endpoint: proRequest.endpoint,
                headers: [.contentType: proRequest.contentType],
                body: proRequest.body,
                overallTimeout: Network.defaultTimeout,
                using: dependencies
            ),
            responseType: Data.self,
            using: dependencies
        )
        .map { _, data in GetProStatusResponse(parsing: data) }
    }

    static func getProRevocations(
        ticket: Int64,
        using dependencies: Dependencies
    ) throws -> Network.PreparedRequest<GetProRevocationsResponse> {
        let proRequest: ProRequest = try ProRequest {
            session_pro_backend_get_pro_revocations_request_build(ticket)
        }

        return try Network.PreparedRequest(
            request: try Request<Data, Endpoint>(
                method: .post,
                endpoint: proRequest.endpoint,
                headers: [.contentType: proRequest.contentType],
                body: proRequest.body,
                using: dependencies
            ),
            responseType: Data.self,
            using: dependencies
        )
        .map { _, data in GetProRevocationsResponse(parsing: data) }
    }
}
