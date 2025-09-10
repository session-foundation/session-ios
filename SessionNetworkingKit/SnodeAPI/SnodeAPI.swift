// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import Punycode
import SessionUtilitiesKit

public final class SnodeAPI {
    // MARK: - Settings
    
    public static let maxRetryCount: Int = 8

    // MARK: - Batching & Polling
    
    public typealias PollResponse = [SnodeAPI.Namespace: (info: ResponseInfoType, data: PreparedGetMessagesResponse?)]

    public static func preparedPoll(
        namespaces: [SnodeAPI.Namespace],
        lastHashes: [SnodeAPI.Namespace: String],
        refreshingConfigHashes: [String] = [],
        from snode: LibSession.Snode,
        authMethod: AuthenticationMethod,
        using dependencies: Dependencies
    ) throws -> Network.PreparedRequest<PollResponse> {
        // Determine the maxSize each namespace in the request should take up
        var requests: [any ErasedPreparedRequest] = []
        let namespaceMaxSizeMap: [SnodeAPI.Namespace: Int64] = SnodeAPI.Namespace.maxSizeMap(for: namespaces)
        let fallbackSize: Int64 = (namespaceMaxSizeMap.values.min() ?? 1)

        // If we have any config hashes to refresh TTLs then add those requests first
        if !refreshingConfigHashes.isEmpty {
            let updatedExpiryMS: Int64 = (
                dependencies[cache: .snodeAPI].currentOffsetTimestampMs() +
                (30 * 24 * 60 * 60 * 1000) // 30 days
            )
            requests.append(
                try SnodeAPI.preparedUpdateExpiry(
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
                try SnodeAPI.preparedGetMessages(
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
        .map { (_: ResponseInfoType, batchResponse: Network.BatchResponse) -> [SnodeAPI.Namespace: (info: ResponseInfoType, data: PreparedGetMessagesResponse?)] in
            let messageResponses: [Network.BatchSubResponse<PreparedGetMessagesResponse>] = batchResponse
                .compactMap { $0 as? Network.BatchSubResponse<PreparedGetMessagesResponse> }
            
            return zip(namespaces, messageResponses)
                .reduce(into: [:]) { result, next in
                    guard let messageResponse: PreparedGetMessagesResponse = next.1.body else { return }
                    
                    result[next.0] = (next.1, messageResponse)
                }
        }
    }
    
    public static func preparedBatch(
        requests: [any ErasedPreparedRequest],
        requireAllBatchResponses: Bool,
        snode: LibSession.Snode? = nil,
        swarmPublicKey: String,
        requestTimeout: TimeInterval = Network.defaultTimeout,
        overallTimeout: TimeInterval? = nil,
        using dependencies: Dependencies
    ) throws -> Network.PreparedRequest<Network.BatchResponse> {
        return try SnodeAPI
            .prepareRequest(
                request: {
                    switch snode {
                        case .none:
                            return try Request(
                                endpoint: .batch,
                                swarmPublicKey: swarmPublicKey,
                                body: Network.BatchRequest(requestsKey: .requests, requests: requests),
                                requestTimeout: requestTimeout,
                                overallTimeout: overallTimeout
                            )
                        
                        case .some(let snode):
                            return try Request(
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
    
    public static func preparedSequence(
        requests: [any ErasedPreparedRequest],
        requireAllBatchResponses: Bool,
        swarmPublicKey: String,
        requestTimeout: TimeInterval = Network.defaultTimeout,
        overallTimeout: TimeInterval? = nil,
        using dependencies: Dependencies
    ) throws -> Network.PreparedRequest<Network.BatchResponse> {
        return try SnodeAPI
            .prepareRequest(
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
    
    public typealias PreparedGetMessagesResponse = (messages: [SnodeReceivedMessage], lastHash: String?)
    
    public static func preparedGetMessages(
        namespace: SnodeAPI.Namespace,
        snode: LibSession.Snode,
        lastHash: String? = nil,
        maxSize: Int64? = nil,
        authMethod: AuthenticationMethod,
        using dependencies: Dependencies
    ) throws -> Network.PreparedRequest<PreparedGetMessagesResponse> {
        let preparedRequest: Network.PreparedRequest<GetMessagesResponse> = try {
            // Check if this namespace requires authentication
            guard namespace.requiresReadAuthentication else {
                return try SnodeAPI.prepareRequest(
                    request: Request(
                        endpoint: .getMessages,
                        swarmPublicKey: try authMethod.swarmPublicKey,
                        body: LegacyGetMessagesRequest(
                            pubkey: try authMethod.swarmPublicKey,
                            lastHash: (lastHash ?? ""),
                            namespace: namespace,
                            maxCount: nil,
                            maxSize: maxSize
                        )
                    ),
                    responseType: GetMessagesResponse.self,
                    using: dependencies
                )
            }

            return try SnodeAPI.prepareRequest(
                request: Request(
                    endpoint: .getMessages,
                    swarmPublicKey: try authMethod.swarmPublicKey,
                    body: GetMessagesRequest(
                        lastHash: (lastHash ?? ""),
                        namespace: namespace,
                        authMethod: authMethod,
                        timestampMs: dependencies[cache: .snodeAPI].currentOffsetTimestampMs(),
                        maxSize: maxSize
                    )
                ),
                responseType: GetMessagesResponse.self,
                using: dependencies
            )
        }()
        
        return preparedRequest
            .tryMap { _, response -> (messages: [SnodeReceivedMessage], lastHash: String?) in
                return (
                    try response.messages.compactMap { rawMessage -> SnodeReceivedMessage? in
                        SnodeReceivedMessage(
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
    
    public static func getSessionID(
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
        else { throw SnodeAPIError.onsHashingFailed }
        
        // Ask 3 different snodes for the Session ID associated with the given name hash
        let base64EncodedNameHash = nameHash.toBase64()
        let nodes: Set<LibSession.Snode> = try await dependencies[singleton: .network]
            .getRandomNodes(count: validationCount)
        let results: [String] = try await withThrowingTaskGroup { [dependencies] group in
            for node in nodes {
                group.addTask { [dependencies] in
                    let request: Network.PreparedRequest<ONSResolveResponse> = try SnodeAPI.prepareRequest(
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
            throw SnodeAPIError.onsValidationFailed
        }
        
        return results[0]
    }
    
    public static func preparedGetExpiries(
        of serverHashes: [String],
        authMethod: AuthenticationMethod,
        using dependencies: Dependencies
    ) throws -> Network.PreparedRequest<GetExpiriesResponse> {
        return try SnodeAPI
            .prepareRequest(
                request: Request(
                    endpoint: .getExpiries,
                    swarmPublicKey: try authMethod.swarmPublicKey,
                    body: GetExpiriesRequest(
                        messageHashes: serverHashes,
                        authMethod: authMethod,
                        timestampMs: dependencies[cache: .snodeAPI].currentOffsetTimestampMs()
                    )
                ),
                responseType: GetExpiriesResponse.self,
                using: dependencies
            )
    }
    
    // MARK: - Store
    
    public static func preparedSendMessage(
        message: SnodeMessage,
        in namespace: Namespace,
        authMethod: AuthenticationMethod,
        using dependencies: Dependencies
    ) throws -> Network.PreparedRequest<SendMessagesResponse> {
        let request: Network.PreparedRequest<SendMessagesResponse> = try {
            // Check if this namespace requires authentication
            guard namespace.requiresWriteAuthentication else {
                return try SnodeAPI.prepareRequest(
                    request: Request(
                        endpoint: .sendMessage,
                        swarmPublicKey: try authMethod.swarmPublicKey,
                        body: LegacySendMessagesRequest(
                            message: message,
                            namespace: namespace
                        ),
                        overallTimeout: Network.defaultTimeout
                    ),
                    responseType: SendMessagesResponse.self,
                    using: dependencies
                )
            }
            
            return try SnodeAPI.prepareRequest(
                request: Request(
                    endpoint: .sendMessage,
                    swarmPublicKey: try authMethod.swarmPublicKey,
                    body: SendMessageRequest(
                        message: message,
                        namespace: namespace,
                        authMethod: authMethod,
                        timestampMs: dependencies[cache: .snodeAPI].currentOffsetTimestampMs()
                    ),
                    overallTimeout: Network.defaultTimeout
                ),
                responseType: SendMessagesResponse.self,
                using: dependencies
            )
        }()
        
        return request
            .tryMap { _, response -> SendMessagesResponse in
                try response.validateResultMap(
                    swarmPublicKey: try authMethod.swarmPublicKey,
                    using: dependencies
                )

                return response
            }
    }
    
    // MARK: - Edit
    
    public static func preparedUpdateExpiry(
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
        
        return try SnodeAPI
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
    
    public static func preparedRevokeSubaccounts(
        subaccountsToRevoke: [[UInt8]],
        authMethod: AuthenticationMethod,
        using dependencies: Dependencies
    ) throws -> Network.PreparedRequest<Void> {
        let timestampMs: UInt64 = dependencies[cache: .snodeAPI].currentOffsetTimestampMs()
        
        return try SnodeAPI
            .prepareRequest(
                request: Request(
                    endpoint: .revokeSubaccount,
                    swarmPublicKey: try authMethod.swarmPublicKey,
                    body: RevokeSubaccountRequest(
                        subaccountsToRevoke: subaccountsToRevoke,
                        authMethod: authMethod,
                        timestampMs: timestampMs
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
    
    public static func preparedUnrevokeSubaccounts(
        subaccountsToUnrevoke: [[UInt8]],
        authMethod: AuthenticationMethod,
        using dependencies: Dependencies
    ) throws -> Network.PreparedRequest<Void> {
        let timestampMs: UInt64 = dependencies[cache: .snodeAPI].currentOffsetTimestampMs()
        
        return try SnodeAPI
            .prepareRequest(
                request: Request(
                    endpoint: .unrevokeSubaccount,
                    swarmPublicKey: try authMethod.swarmPublicKey,
                    body: UnrevokeSubaccountRequest(
                        subaccountsToUnrevoke: subaccountsToUnrevoke,
                        authMethod: authMethod,
                        timestampMs: timestampMs
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
    
    public static func preparedDeleteMessages(
        serverHashes: [String],
        requireSuccessfulDeletion: Bool,
        authMethod: AuthenticationMethod,
        using dependencies: Dependencies
    ) throws -> Network.PreparedRequest<[String: Bool]> {
        return try SnodeAPI
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
    public static func preparedDeleteAllMessages(
        namespace: SnodeAPI.Namespace,
        snode: LibSession.Snode,
        requestTimeout: TimeInterval = Network.defaultTimeout,
        overallTimeout: TimeInterval? = nil,
        authMethod: AuthenticationMethod,
        using dependencies: Dependencies
    ) throws -> Network.PreparedRequest<[String: Bool]> {
        return try SnodeAPI
            .prepareRequest(
                request: Request(
                    endpoint: .deleteAll,
                    snode: snode,
                    swarmPublicKey: try authMethod.swarmPublicKey,
                    body: DeleteAllMessagesRequest(
                        namespace: namespace,
                        authMethod: authMethod,
                        timestampMs: dependencies[cache: .snodeAPI].currentOffsetTimestampMs()
                    ),
                    requestTimeout: requestTimeout,
                    overallTimeout: overallTimeout
                ),
                responseType: DeleteAllMessagesResponse.self,
                using: dependencies
            )
            .tryMap { info, response -> [String: Bool] in
                guard let targetInfo: LatestTimestampResponseInfo = info as? LatestTimestampResponseInfo else {
                    throw NetworkError.invalidResponse
                }
                
                return try response.validResultMap(
                    swarmPublicKey: try authMethod.swarmPublicKey,
                    validationData: targetInfo.timestampMs,
                    using: dependencies
                )
            }
    }
    
    // MARK: - Internal API
    
    public static func preparedGetNetworkTime(
        from snode: LibSession.Snode,
        using dependencies: Dependencies
    ) throws -> Network.PreparedRequest<UInt64> {
        return try SnodeAPI
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
                dependencies.mutate(cache: .snodeAPI) { $0.setClockOffsetMs(offset) }

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
                    case let snodeResponse as SnodeResponse:
                        // Update the network offset based on the response so subsequent requests have
                        // the correct network offset time
                        let offset = (Int64(snodeResponse.timeOffset) - Int64(floor(dependencies.dateNow.timeIntervalSince1970 * 1000)))
                        dependencies.mutate(cache: .snodeAPI) {
                            $0.setClockOffsetMs(offset)
                            
                            // Extract and store hard fork information if returned
                            guard snodeResponse.hardForkVersion.count > 1 else { return }
                            
                            if snodeResponse.hardForkVersion[1] > $0.softfork {
                                $0.softfork = snodeResponse.hardForkVersion[1]
                                dependencies[defaults: .standard, key: .softfork] = $0.softfork
                            }
                            
                            if snodeResponse.hardForkVersion[0] > $0.hardfork {
                                $0.hardfork = snodeResponse.hardForkVersion[0]
                                dependencies[defaults: .standard, key: .hardfork] = $0.hardfork
                                $0.softfork = snodeResponse.hardForkVersion[1]
                                dependencies[defaults: .standard, key: .softfork] = $0.softfork
                            }
                        }
                        
                    default: break
                }
            }
        )
    }
}

// MARK: - SnodeAPI Cache

public extension SnodeAPI {
    class Cache: SnodeAPICacheType {
        private let dependencies: Dependencies
        public var hardfork: Int
        public var softfork: Int
        public var clockOffsetMs: Int64 = 0
        
        init(using dependencies: Dependencies) {
            self.dependencies = dependencies
            self.hardfork = dependencies[defaults: .standard, key: .hardfork]
            self.softfork = dependencies[defaults: .standard, key: .softfork]
        }
        
        public func currentOffsetTimestampMs<T: Numeric>() -> T {
            let timestampNowMs: Int64 = (Int64(floor(dependencies.dateNow.timeIntervalSince1970 * 1000)) + clockOffsetMs)
            
            guard let convertedTimestampNowMs: T = T(exactly: timestampNowMs) else {
                Log.critical("[SnodeAPI.Cache] Failed to convert the timestamp to the desired type: \(type(of: T.self)).")
                return 0
            }
            
            return convertedTimestampNowMs
        }
        
        public func setClockOffsetMs(_ clockOffsetMs: Int64) {
            self.clockOffsetMs = clockOffsetMs
        }
    }
}

public extension Cache {
    static let snodeAPI: CacheConfig<SnodeAPICacheType, SnodeAPIImmutableCacheType> = Dependencies.create(
        identifier: "snodeAPI",
        createInstance: { dependencies in SnodeAPI.Cache(using: dependencies) },
        mutableInstance: { $0 },
        immutableInstance: { $0 }
    )
}

// MARK: - SnodeAPICacheType

/// This is a read-only version of the Cache designed to avoid unintentionally mutating the instance in a non-thread-safe way
public protocol SnodeAPIImmutableCacheType: ImmutableCacheType {
    /// The last seen storage server hard fork version.
    var hardfork: Int { get }
    
    /// The last seen storage server soft fork version.
    var softfork: Int { get }

    /// The offset between the user's clock and the Service Node's clock. Used in cases where the
    /// user's clock is incorrect.
    var clockOffsetMs: Int64 { get }
    
    /// Tthe current user clock timestamp in milliseconds offset by the difference between the user's clock and the clock of the most
    /// recent Service Node's that was communicated with.
    func currentOffsetTimestampMs<T: Numeric>() -> T
}

public protocol SnodeAPICacheType: SnodeAPIImmutableCacheType, MutableCacheType {
    /// The last seen storage server hard fork version.
    var hardfork: Int { get set }
    
    /// The last seen storage server soft fork version.
    var softfork: Int { get set }

    /// A function to update the offset between the user's clock and the Service Node's clock.
    func setClockOffsetMs(_ clockOffsetMs: Int64)
}
