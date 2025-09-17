// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import Combine
import GRDB
import Punycode
import SessionUtilitiesKit

private typealias StorageServer = Network.StorageServer
private typealias Endpoint = Network.StorageServer.Endpoint

public extension Network.StorageServer {
    // MARK: - Batching & Polling
    
    typealias PollResponse = [Namespace: (info: ResponseInfoType, data: PreparedGetMessagesResponse?)]
    
    static func preparedPoll(
        namespaces: [Namespace],
        lastHashes: [Namespace: String],
        refreshingConfigHashes: [String] = [],
        from snode: LibSession.Snode,
        authMethod: AuthenticationMethod,
        using dependencies: Dependencies
    ) throws -> Network.PreparedRequest<PollResponse> {
        // Determine the maxSize each namespace in the request should take up
        var requests: [any ErasedPreparedRequest] = []
        let namespaceMaxSizeMap: [Namespace: Int64] = Namespace.maxSizeMap(for: namespaces)
        let fallbackSize: Int64 = (namespaceMaxSizeMap.values.min() ?? 1)
        
        // If we have any config hashes to refresh TTLs then add those requests first
        if !refreshingConfigHashes.isEmpty {
            let updatedExpiryMS: Int64 = (
                dependencies[cache: .storageServer].currentOffsetTimestampMs() +
                (30 * 24 * 60 * 60 * 1000) // 30 days
            )
            requests.append(
                try StorageServer.preparedUpdateExpiry(
                    serverHashes: refreshingConfigHashes,
                    updatedExpiryMs: updatedExpiryMS,
                    extendOnly: true,
                    ignoreValidationFailure: true,
                    explicitTargetNode: snode,
                    authMethod: authMethod,
                    using: dependencies
                )
            )
        }
        
        // Add the various 'getMessages' requests
        requests.append(
            contentsOf: try namespaces.map { namespace -> any ErasedPreparedRequest in
                try StorageServer.preparedGetMessages(
                    namespace: namespace,
                    snode: snode,
                    lastHash: lastHashes[namespace],
                    maxSize: namespaceMaxSizeMap[namespace]
                        .defaulting(to: fallbackSize),
                    authMethod: authMethod,
                    using: dependencies
                )
            }
        )
        
        return try preparedBatch(
            requests: requests,
            requireAllBatchResponses: true,
            snode: snode,
            swarmPublicKey: try authMethod.swarmPublicKey,
            using: dependencies
        )
        .map { (_: ResponseInfoType, batchResponse: Network.BatchResponse) -> [Namespace: (info: ResponseInfoType, data: PreparedGetMessagesResponse?)] in
            let messageResponses: [Network.BatchSubResponse<PreparedGetMessagesResponse>] = batchResponse
                .compactMap { $0 as? Network.BatchSubResponse<PreparedGetMessagesResponse> }
            
            return zip(namespaces, messageResponses)
                .reduce(into: [:]) { result, next in
                    guard let messageResponse: PreparedGetMessagesResponse = next.1.body else { return }
                    
                    result[next.0] = (next.1, messageResponse)
                }
        }
    }
    
    static func preparedBatch(
        requests: [any ErasedPreparedRequest],
        requireAllBatchResponses: Bool,
        snode: LibSession.Snode? = nil,
        swarmPublicKey: String,
        requestTimeout: TimeInterval = Network.defaultTimeout,
        overallTimeout: TimeInterval? = nil,
        using dependencies: Dependencies
    ) throws -> Network.PreparedRequest<Network.BatchResponse> {
        return try StorageServer.prepareRequest(
            request: {
                switch snode {
                    case .none:
                        return Request(
                            endpoint: .batch,
                            swarmPublicKey: swarmPublicKey,
                            body: Network.BatchRequest(requestsKey: .requests, requests: requests),
                            requestTimeout: requestTimeout,
                            overallTimeout: overallTimeout
                        )
                        
                    case .some(let snode):
                        return Request(
                            endpoint: .batch,
                            snode: snode,
                            swarmPublicKey: swarmPublicKey,
                            body: Network.BatchRequest(requestsKey: .requests, requests: requests),
                            requestTimeout: requestTimeout,
                            overallTimeout: overallTimeout
                        )
                }
            }(),
            responseType: Network.BatchResponse.self,
            requireAllBatchResponses: requireAllBatchResponses,
            using: dependencies
        )
    }
    
    static func preparedSequence(
        requests: [any ErasedPreparedRequest],
        requireAllBatchResponses: Bool,
        swarmPublicKey: String,
        requestTimeout: TimeInterval = Network.defaultTimeout,
        overallTimeout: TimeInterval? = nil,
        using dependencies: Dependencies
    ) throws -> Network.PreparedRequest<Network.BatchResponse> {
        return try StorageServer.prepareRequest(
            request: Request(
                endpoint: .sequence,
                swarmPublicKey: swarmPublicKey,
                body: Network.BatchRequest(requestsKey: .requests, requests: requests),
                requestTimeout: requestTimeout,
                overallTimeout: overallTimeout
            ),
            responseType: Network.BatchResponse.self,
            requireAllBatchResponses: requireAllBatchResponses,
            using: dependencies
        )
    }
    
    // MARK: - Retrieve
    
    typealias PreparedGetMessagesResponse = (messages: [Message], lastHash: String?)
    
    static func preparedGetMessages(
        namespace: Namespace,
        snode: LibSession.Snode,
        lastHash: String? = nil,
        maxSize: Int64? = nil,
        authMethod: AuthenticationMethod,
        using dependencies: Dependencies
    ) throws -> Network.PreparedRequest<PreparedGetMessagesResponse> {
        let preparedRequest: Network.PreparedRequest<GetMessagesResponse> = try StorageServer.prepareRequest(
            request: Request(
                endpoint: .getMessages,
                swarmPublicKey: try authMethod.swarmPublicKey,
                body: GetMessagesRequest(
                    lastHash: (lastHash ?? ""),
                    namespace: namespace,
                    maxSize: maxSize,
                    timestampMs: dependencies[cache: .storageServer].currentOffsetTimestampMs(),
                    authMethod: authMethod
                )
            ),
            responseType: GetMessagesResponse.self,
            using: dependencies
        )
        
        return preparedRequest
            .tryMap { _, response -> (messages: [Message], lastHash: String?) in
                return (
                    try response.messages.compactMap { rawMessage -> Message? in
                        Message(
                            snode: snode,
                            publicKey: try authMethod.swarmPublicKey,
                            namespace: namespace,
                            rawMessage: rawMessage
                        )
                    },
                    lastHash
                )
            }
    }
    
    static func getSessionID(
        for onsName: String,
        using dependencies: Dependencies
    ) async throws -> String {
        let validationCount = 3
        
        // The name must be lowercased
        let onsName = onsName.lowercased().idnaEncoded ?? onsName.lowercased()
        
        // Hash the ONS name using BLAKE2b
        guard
            let nameHash = dependencies[singleton: .crypto].generate(
                .hash(message: Array(onsName.utf8))
            )
        else { throw StorageServerError.onsHashingFailed }
        
        // Ask 3 different snodes for the Session ID associated with the given name hash
        let base64EncodedNameHash = nameHash.toBase64()
        let nodes: Set<LibSession.Snode> = try await dependencies[singleton: .network]
            .getRandomNodes(count: validationCount)
        let results: [String] = try await withThrowingTaskGroup { [dependencies] group in
            for node in nodes {
                group.addTask { [dependencies] in
                    let request: Network.PreparedRequest<ONSResolveResponse> = try StorageServer.prepareRequest(
                        request: Request(
                            endpoint: .oxenDaemonRPCCall,
                            snode: node,
                            body: OxenDaemonRPCRequest(
                                endpoint: .daemonOnsResolve,
                                body: ONSResolveRequest(
                                    type: 0, // type 0 means Session
                                    base64EncodedNameHash: base64EncodedNameHash
                                )
                            )
                        ),
                        responseType: ONSResolveResponse.self,
                        using: dependencies
                    )
                    
                    let response: ONSResolveResponse = try await request.send(using: dependencies)
                    
                    return try dependencies[singleton: .crypto].tryGenerate(
                        .sessionId(name: onsName, response: response)
                    )
                }
            }
            
            return try await group.reduce(into: []) { result, next in result.append(next) }
        }
        
        guard results.count == validationCount, Set(results).count == 1 else {
            throw StorageServerError.onsValidationFailed
        }
        
        return results[0]
    }
    
    static func preparedGetExpiries(
        of serverHashes: [String],
        authMethod: AuthenticationMethod,
        using dependencies: Dependencies
    ) throws -> Network.PreparedRequest<GetExpiriesResponse> {
        return try StorageServer.prepareRequest(
            request: Request(
                endpoint: .getExpiries,
                swarmPublicKey: try authMethod.swarmPublicKey,
                body: GetExpiriesRequest(
                    messageHashes: serverHashes,
                    timestampMs: dependencies[cache: .storageServer].currentOffsetTimestampMs(),
                    authMethod: authMethod
                )
            ),
            responseType: GetExpiriesResponse.self,
            using: dependencies
        )
    }
    
    // MARK: - Store
    
    static func preparedSendMessage(
        request: SendMessageRequest,
        using dependencies: Dependencies
    ) throws -> Network.PreparedRequest<SendMessagesResponse> {
        let preparedRequest: Network.PreparedRequest<SendMessagesResponse> = try StorageServer.prepareRequest(
            request: Request(
                endpoint: .sendMessage,
                swarmPublicKey: try request.authMethod.swarmPublicKey,
                body: request,
                overallTimeout: Network.defaultTimeout
            ),
            responseType: SendMessagesResponse.self,
            using: dependencies
        )
        
        return preparedRequest.tryMap { _, response -> SendMessagesResponse in
            try response.validateResultMap(
                swarmPublicKey: try request.authMethod.swarmPublicKey,
                using: dependencies
            )
            
            return response
        }
    }
    
    // MARK: - Edit
    
    static func preparedUpdateExpiry(
        serverHashes: [String],
        updatedExpiryMs: Int64,
        shortenOnly: Bool? = nil,
        extendOnly: Bool? = nil,
        ignoreValidationFailure: Bool = false,
        explicitTargetNode: LibSession.Snode? = nil,
        authMethod: AuthenticationMethod,
        using dependencies: Dependencies
    ) throws -> Network.PreparedRequest<[String: UpdateExpiryResponseResult]> {
        // ShortenOnly and extendOnly cannot be true at the same time
        guard shortenOnly == nil || extendOnly == nil else { throw NetworkError.invalidPreparedRequest }
        
        return try StorageServer
            .prepareRequest(
                request: Request(
                    endpoint: .expire,
                    swarmPublicKey: try authMethod.swarmPublicKey,
                    body: UpdateExpiryRequest(
                        messageHashes: serverHashes,
                        expiryMs: UInt64(updatedExpiryMs),
                        shorten: shortenOnly,
                        extend: extendOnly,
                        authMethod: authMethod
                    )
                ),
                responseType: UpdateExpiryResponse.self,
                using: dependencies
            )
            .tryMap { _, response -> [String: UpdateExpiryResponseResult] in
                do {
                    return try response.validResultMap(
                        swarmPublicKey: try authMethod.swarmPublicKey,
                        validationData: serverHashes,
                        using: dependencies
                    )
                }
                catch {
                    guard ignoreValidationFailure else { throw error }
                    
                    return [:]
                }
            }
            .handleEvents(
                receiveOutput: { _, result in
                    /// Since we have updated the TTL we need to make sure we also update the local
                    /// `SnodeReceivedMessageInfo.expirationDateMs` values so they match the updated swarm, if
                    /// we had a specific `snode` we we're sending the request to then we should use those values, otherwise
                    /// we can just grab the first value from the response and use that
                    let maybeTargetResult: UpdateExpiryResponseResult? = {
                        guard let snode: LibSession.Snode = explicitTargetNode else {
                            return result.first?.value
                        }
                        
                        return result[snode.ed25519PubkeyHex]
                    }()
                    guard
                        let targetResult: UpdateExpiryResponseResult = maybeTargetResult,
                        let groupedExpiryResult: [UInt64: [String]] = targetResult.changed
                            .updated(with: targetResult.unchanged)
                            .groupedByValue()
                            .nullIfEmpty
                    else { return }
                    
                    dependencies[singleton: .storage].writeAsync { db in
                        try groupedExpiryResult.forEach { updatedExpiry, hashes in
                            try SnodeReceivedMessageInfo
                                .filter(hashes.contains(SnodeReceivedMessageInfo.Columns.hash))
                                .updateAll(
                                    db,
                                    SnodeReceivedMessageInfo.Columns.expirationDateMs
                                        .set(to: updatedExpiry)
                                )
                        }
                    }
                }
            )
    }
    
    static func preparedRevokeSubaccounts(
        subaccountsToRevoke: [[UInt8]],
        authMethod: AuthenticationMethod,
        using dependencies: Dependencies
    ) throws -> Network.PreparedRequest<Void> {
        let timestampMs: UInt64 = dependencies[cache: .storageServer].currentOffsetTimestampMs()
        
        return try StorageServer
            .prepareRequest(
                request: Request(
                    endpoint: .revokeSubaccount,
                    swarmPublicKey: try authMethod.swarmPublicKey,
                    body: RevokeSubaccountRequest(
                        subaccountsToRevoke: subaccountsToRevoke,
                        timestampMs: timestampMs,
                        authMethod: authMethod
                    )
                ),
                responseType: RevokeSubaccountResponse.self,
                using: dependencies
            )
            .tryMap { _, response -> Void in
                try response.validateResultMap(
                    swarmPublicKey: try authMethod.swarmPublicKey,
                    validationData: (subaccountsToRevoke, timestampMs),
                    using: dependencies
                )
                
                return ()
            }
    }
    
    static func preparedUnrevokeSubaccounts(
        subaccountsToUnrevoke: [[UInt8]],
        authMethod: AuthenticationMethod,
        using dependencies: Dependencies
    ) throws -> Network.PreparedRequest<Void> {
        let timestampMs: UInt64 = dependencies[cache: .storageServer].currentOffsetTimestampMs()
        
        return try StorageServer
            .prepareRequest(
                request: Request(
                    endpoint: .unrevokeSubaccount,
                    swarmPublicKey: try authMethod.swarmPublicKey,
                    body: UnrevokeSubaccountRequest(
                        subaccountsToUnrevoke: subaccountsToUnrevoke,
                        timestampMs: timestampMs,
                        authMethod: authMethod
                    )
                ),
                responseType: UnrevokeSubaccountResponse.self,
                using: dependencies
            )
            .tryMap { _, response -> Void in
                try response.validateResultMap(
                    swarmPublicKey: try authMethod.swarmPublicKey,
                    validationData: (subaccountsToUnrevoke, timestampMs),
                    using: dependencies
                )
                
                return ()
            }
    }
    
    // MARK: - Delete
    
    static func preparedDeleteMessages(
        serverHashes: [String],
        requireSuccessfulDeletion: Bool,
        authMethod: AuthenticationMethod,
        using dependencies: Dependencies
    ) throws -> Network.PreparedRequest<[String: Bool]> {
        return try StorageServer
            .prepareRequest(
                request: Request(
                    endpoint: .deleteMessages,
                    swarmPublicKey: try authMethod.swarmPublicKey,
                    body: DeleteMessagesRequest(
                        messageHashes: serverHashes,
                        requireSuccessfulDeletion: requireSuccessfulDeletion,
                        authMethod: authMethod
                    )
                ),
                responseType: DeleteMessagesResponse.self,
                using: dependencies
            )
            .tryMap { _, response -> [String: Bool] in
                let validResultMap: [String: Bool] = try response.validResultMap(
                    swarmPublicKey: try authMethod.swarmPublicKey,
                    validationData: serverHashes,
                    using: dependencies
                )
                
                // If `validResultMap` didn't throw then at least one service node
                // deleted successfully so we should mark the hash as invalid so we
                // don't try to fetch updates using that hash going forward (if we
                // do we would end up re-fetching all old messages)
                dependencies[singleton: .storage].writeAsync { db in
                    try? SnodeReceivedMessageInfo.handlePotentialDeletedOrInvalidHash(
                        db,
                        potentiallyInvalidHashes: serverHashes
                    )
                }
                
                return validResultMap
            }
    }
    
    /// Clears all the user's data from their swarm. Returns a dictionary of snode public key to deletion confirmation.
    static func preparedDeleteAllMessages(
        namespace: Namespace,
        snode: LibSession.Snode,
        requestTimeout: TimeInterval = Network.defaultTimeout,
        overallTimeout: TimeInterval? = nil,
        authMethod: AuthenticationMethod,
        using dependencies: Dependencies
    ) throws -> Network.PreparedRequest<[String: Bool]> {
        let timestampMs: UInt64 = dependencies[cache: .storageServer].currentOffsetTimestampMs()
        
        return try StorageServer
            .prepareRequest(
                request: Request(
                    endpoint: .deleteAll,
                    snode: snode,
                    swarmPublicKey: try authMethod.swarmPublicKey,
                    body: DeleteAllMessagesRequest(
                        namespace: namespace,
                        timestampMs: dependencies[cache: .storageServer].currentOffsetTimestampMs(),
                        authMethod: authMethod
                    ),
                    requestTimeout: requestTimeout,
                    overallTimeout: overallTimeout
                ),
                responseType: DeleteAllMessagesResponse.self,
                using: dependencies
            )
            .tryMap { info, response -> [String: Bool] in
                return try response.validResultMap(
                    swarmPublicKey: try authMethod.swarmPublicKey,
                    validationData: timestampMs,
                    using: dependencies
                )
            }
    }
    
    // MARK: - Internal API
    
    static func preparedGetNetworkTime(
        from snode: LibSession.Snode,
        using dependencies: Dependencies
    ) throws -> Network.PreparedRequest<UInt64> {
        return try StorageServer
            .prepareRequest(
                request: Request<[String: String], Endpoint>(
                    endpoint: .getInfo,
                    snode: snode,
                    body: [:]
                ),
                responseType: GetNetworkTimestampResponse.self,
                using: dependencies
            )
            .map { _, response in
                // Assume we've fetched the networkTime in order to send a message to the specified snode, in
                // which case we want to update the 'clockOffsetMs' value for subsequent requests
                let offset = (Int64(response.timestamp) - Int64(floor(dependencies.dateNow.timeIntervalSince1970 * 1000)))
                dependencies.mutate(cache: .storageServer) { $0.setClockOffsetMs(offset) }
                
                return response.timestamp
            }
    }
    
    // MARK: - Convenience
    
    private static func prepareRequest<T: Encodable, R: Decodable>(
        request: Request<T, Endpoint>,
        responseType: R.Type,
        requireAllBatchResponses: Bool = true,
        using dependencies: Dependencies
    ) throws -> Network.PreparedRequest<R> {
        return try Network.PreparedRequest<R>(
            request: request,
            responseType: responseType,
            requireAllBatchResponses: requireAllBatchResponses,
            using: dependencies
        )
        .handleEvents(
            receiveOutput: { _, response in
                switch response {
                    case let baseResponse as BaseResponse:
                        // Update the network offset based on the response so subsequent requests have
                        // the correct network offset time
                        let offset = (Int64(baseResponse.timeOffset) - Int64(floor(dependencies.dateNow.timeIntervalSince1970 * 1000)))
                        dependencies.mutate(cache: .storageServer) {
                            $0.setClockOffsetMs(offset)
                            
                            // Extract and store hard fork information if returned
                            guard baseResponse.hardForkVersion.count > 1 else { return }
                            
                            if baseResponse.hardForkVersion[1] > $0.softfork {
                                $0.softfork = baseResponse.hardForkVersion[1]
                                dependencies[defaults: .standard, key: .softfork] = $0.softfork
                            }
                            
                            if baseResponse.hardForkVersion[0] > $0.hardfork {
                                $0.hardfork = baseResponse.hardForkVersion[0]
                                dependencies[defaults: .standard, key: .hardfork] = $0.hardfork
                                $0.softfork = baseResponse.hardForkVersion[1]
                                dependencies[defaults: .standard, key: .softfork] = $0.softfork
                            }
                        }
                        
                    default: break
                }
            }
        )
    }
}
