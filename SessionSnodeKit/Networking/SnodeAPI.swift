// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import Sodium
import GRDB
import SessionUtilitiesKit

public final class SnodeAPI {
    private static var hasLoadedSnodePool: Atomic<Bool> = Atomic(false)
    private static var loadedSwarms: Atomic<Set<String>> = Atomic([])
    private static var getSnodePoolPublisher: Atomic<AnyPublisher<Set<Snode>, Error>?> = Atomic(nil)
    
    /// - Note: Should only be accessed from `Threading.workQueue` to avoid race conditions.
    internal static var snodeFailureCount: Atomic<[Snode: UInt]> = Atomic([:])
    /// - Note: Should only be accessed from `Threading.workQueue` to avoid race conditions.
    internal static var snodePool: Atomic<Set<Snode>> = Atomic([])

    /// The offset between the user's clock and the Service Node's clock. Used in cases where the
    /// user's clock is incorrect.
    ///
    /// - Note: Should only be accessed from `Threading.workQueue` to avoid race conditions.
    public static var clockOffsetMs: Atomic<Int64> = Atomic(0)
    /// - Note: Should only be accessed from `Threading.workQueue` to avoid race conditions.
    public static var swarmCache: Atomic<[String: Set<Snode>]> = Atomic([:])
    
    // MARK: - Hardfork version
    
    public static var hardfork: Int = Dependencies()[defaults: .standard, key: .hardfork]
    public static var softfork: Int = Dependencies()[defaults: .standard, key: .softfork]

    // MARK: - Settings
    
    internal static let maxRetryCount: Int = 8
    private static let minSwarmSnodeCount: Int = 3
    private static let seedNodePool: Set<String> = {
        guard !Features.useTestnet else {
            return [ "http://public.loki.foundation:38157" ]
        }
        
        return [
            "https://seed1.getsession.org:4432",
            "https://seed2.getsession.org:4432",
            "https://seed3.getsession.org:4432"
        ]
    }()
    private static let snodeFailureThreshold: Int = 3
    private static let minSnodePoolCount: Int = 12
    
    public static func currentOffsetTimestampMs(using dependencies: Dependencies = Dependencies()) -> Int64 {
        let clockOffsetMs: Int64 = SnodeAPI.clockOffsetMs.wrappedValue
        
        return (Int64(floor(dependencies.dateNow.timeIntervalSince1970 * 1000)) + clockOffsetMs)
    }

    // MARK: - Snode Pool Interaction
    
    private static var hasInsufficientSnodes: Bool { snodePool.wrappedValue.count < minSnodePoolCount }
    
    private static func loadSnodePoolIfNeeded(
        using dependencies: Dependencies = Dependencies()
    ) {
        guard !hasLoadedSnodePool.wrappedValue else { return }
        
        let fetchedSnodePool: Set<Snode> = dependencies[singleton: .storage]
            .read { db in try Snode.fetchSet(db) }
            .defaulting(to: [])
        
        snodePool.mutate { $0 = fetchedSnodePool }
        hasLoadedSnodePool.mutate { $0 = true }
    }
    
    private static func setSnodePool(
        _ db: Database? = nil,
        to newValue: Set<Snode>,
        using dependencies: Dependencies = Dependencies()
    ) {
        guard let db: Database = db else {
            dependencies[singleton: .storage].write { db in setSnodePool(db, to: newValue, using: dependencies) }
            return
        }
        
        snodePool.mutate { $0 = newValue }
        
        _ = try? Snode.deleteAll(db)
        newValue.forEach { try? $0.save(db) }
    }
    
    private static func dropSnodeFromSnodePool(_ snode: Snode) {
        var snodePool = SnodeAPI.snodePool.wrappedValue
        snodePool.remove(snode)
        setSnodePool(to: snodePool)
    }
    
    @objc public static func clearSnodePool() {
        snodePool.mutate { $0.removeAll() }
        
        Threading.workQueue.async {
            setSnodePool(to: [])
        }
    }
    
    // MARK: - Swarm Interaction
    
    private static func loadSwarmIfNeeded(
        for publicKey: String,
        using dependencies: Dependencies = Dependencies()
    ) {
        guard !loadedSwarms.wrappedValue.contains(publicKey) else { return }
        
        let updatedCacheForKey: Set<Snode> = dependencies[singleton: .storage]
           .read { db in try Snode.fetchSet(db, publicKey: publicKey) }
           .defaulting(to: [])
        
        swarmCache.mutate { $0[publicKey] = updatedCacheForKey }
        loadedSwarms.mutate { $0.insert(publicKey) }
    }
    
    private static func setSwarm(
        to newValue: Set<Snode>,
        for publicKey: String,
        persist: Bool = true,
        using dependencies: Dependencies
    ) {
        swarmCache.mutate { $0[publicKey] = newValue }
        
        guard persist else { return }
        
        dependencies[singleton: .storage].write { db in
            try? newValue.save(db, key: publicKey)
        }
    }
    
    public static func dropSnodeFromSwarmIfNeeded(
        _ snode: Snode,
        publicKey: String,
        using dependencies: Dependencies = Dependencies()
    ) {
        let swarmOrNil = swarmCache.wrappedValue[publicKey]
        guard var swarm = swarmOrNil, let index = swarm.firstIndex(of: snode) else { return }
        swarm.remove(at: index)
        setSwarm(to: swarm, for: publicKey, using: dependencies)
    }

    // MARK: - Snode API
    
    public static func hasCachedSnodesIncludingExpired(
        using dependencies: Dependencies = Dependencies()
    ) -> Bool {
        loadSnodePoolIfNeeded(using: dependencies)
        
        return !hasInsufficientSnodes
    }
    
    public static func getSnodePool(
        using dependencies: Dependencies = Dependencies()
    ) -> AnyPublisher<Set<Snode>, Error> {
        loadSnodePoolIfNeeded(using: dependencies)
        
        let now: Date = Date()
        let hasSnodePoolExpired: Bool = dependencies[singleton: .storage, key: .lastSnodePoolRefreshDate]
            .map { now.timeIntervalSince($0) > 2 * 60 * 60 }
            .defaulting(to: true)
        let snodePool: Set<Snode> = SnodeAPI.snodePool.wrappedValue
        
        guard hasInsufficientSnodes || hasSnodePoolExpired else {
            return Just(snodePool)
                .setFailureType(to: Error.self)
                .eraseToAnyPublisher()
        }
        
        if let getSnodePoolPublisher: AnyPublisher<Set<Snode>, Error> = getSnodePoolPublisher.wrappedValue {
            return getSnodePoolPublisher
        }
        
        return getSnodePoolPublisher.mutate { result in
            /// It was possible for multiple threads to call this at the same time resulting in duplicate promises getting created, while
            /// this should no longer be possible (as the `wrappedValue` should now properly be blocked) this is a sanity check
            /// to make sure we don't create an additional promise when one already exists
            if let previouslyBlockedPublisher: AnyPublisher<Set<Snode>, Error> = result {
                return previouslyBlockedPublisher
            }
            
            let targetPublisher: AnyPublisher<Set<Snode>, Error> = {
                guard snodePool.count >= minSnodePoolCount else { return getSnodePoolFromSeedNode(using: dependencies) }
                
                return getSnodePoolFromSnode(using: dependencies)
                    .catch { _ in getSnodePoolFromSeedNode(using: dependencies) }
                    .eraseToAnyPublisher()
            }()
            
            /// Need to include the post-request code and a `shareReplay` within the publisher otherwise it can still be executed
            /// multiple times as a result of multiple subscribers
            let publisher: AnyPublisher<Set<Snode>, Error> = targetPublisher
                .tryFlatMap { snodePool -> AnyPublisher<Set<Snode>, Error> in
                    guard !snodePool.isEmpty else { throw SnodeAPIError.snodePoolUpdatingFailed }
                    
                    return dependencies[singleton: .storage]
                        .writePublisher { db in
                            db[.lastSnodePoolRefreshDate] = now
                            setSnodePool(db, to: snodePool, using: dependencies)
                            
                            return snodePool
                        }
                        .eraseToAnyPublisher()
                }
                .handleEvents(
                    receiveCompletion: { _ in getSnodePoolPublisher.mutate { $0 = nil } }
                )
                .shareReplay(1)
                .eraseToAnyPublisher()

            /// Actually assign the atomic value
            result = publisher
            
            return publisher
                
        }
    }
    
    public static func getSwarm(
        for publicKey: String,
        using dependencies: Dependencies = Dependencies()
    ) -> AnyPublisher<Set<Snode>, Error> {
        loadSwarmIfNeeded(for: publicKey, using: dependencies)
        
        if let cachedSwarm = swarmCache.wrappedValue[publicKey], cachedSwarm.count >= minSwarmSnodeCount {
            return Just(cachedSwarm)
                .setFailureType(to: Error.self)
                .eraseToAnyPublisher()
        }
        
        let currentUserSessionId: SessionId = getUserSessionId(using: dependencies)
        SNLog("Getting swarm for: \((publicKey == currentUserSessionId.hexString) ? "self" : publicKey).")
        
        return getRandomSnode(using: dependencies)
            .flatMap { snode in
                SnodeAPI.send(
                    request: SnodeRequest(
                        endpoint: .getSwarm,
                        body: GetSwarmRequest(pubkey: publicKey)
                    ),
                    to: snode,
                    associatedWith: publicKey,
                    using: dependencies
                )
                .retry(4)
                .eraseToAnyPublisher()
            }
            .map { _, responseData in parseSnodes(from: responseData, using: dependencies) }
            .handleEvents(
                receiveOutput: { swarm in setSwarm(to: swarm, for: publicKey, using: dependencies) }
            )
            .eraseToAnyPublisher()
    }
    
    // MARK: - Batching & Polling
    
    public typealias PollResponse = [SnodeAPI.Namespace: (info: ResponseInfoType, data: PreparedGetMessagesResponse?)]

    public static func preparedPoll(
        _ db: Database,
        namespaces: [SnodeAPI.Namespace],
        refreshingConfigHashes: [String] = [],
        from snode: Snode,
        authInfo: SnodeAPI.AuthenticationInfo,
        using dependencies: Dependencies = Dependencies()
    ) throws -> HTTP.PreparedRequest<PollResponse> {
        // Determine the maxSize each namespace in the request should take up
        var requests: [any ErasedPreparedRequest] = []
        let namespaceMaxSizeMap: [SnodeAPI.Namespace: Int64] = SnodeAPI.Namespace.maxSizeMap(for: namespaces)
        let fallbackSize: Int64 = (namespaceMaxSizeMap.values.min() ?? 1)

        // If we have any config hashes to refresh TTLs then add those requests first
        if !refreshingConfigHashes.isEmpty {
            requests.append(
                try SnodeAPI.prepareRequest(
                    request: Request(
                        endpoint: .expire,
                        publicKey: authInfo.sessionId.hexString,
                        body: UpdateExpiryRequest(
                            messageHashes: refreshingConfigHashes,
                            expiryMs: UInt64(
                                SnodeAPI.currentOffsetTimestampMs() +
                                (30 * 24 * 60 * 60 * 1000) // 30 days
                            ),
                            extend: true,
                            authInfo: authInfo
                        )
                    ),
                    responseType: UpdateExpiryResponse.self
                )
            )
        }

        // Add the various 'getMessages' requests
        requests.append(
            contentsOf: try namespaces.map { namespace -> any ErasedPreparedRequest in
                try SnodeAPI.preparedGetMessages(
                    db,
                    in: namespace,
                    snode: snode,
                    maxSize: namespaceMaxSizeMap[namespace]
                        .defaulting(to: fallbackSize),
                    authInfo: authInfo,
                    using: dependencies
                )
            }
        )

        return try preparedBatch(
            db,
            requests: requests,
            requireAllBatchResponses: true,
            associatedWith: authInfo.sessionId.hexString,
            using: dependencies
        )
        .map { (_: ResponseInfoType, batchResponse: HTTP.BatchResponse) -> [SnodeAPI.Namespace: (info: ResponseInfoType, data: PreparedGetMessagesResponse?)] in
            let messageResponses: [HTTP.BatchSubResponse<PreparedGetMessagesResponse>] = batchResponse
                .compactMap { $0 as? HTTP.BatchSubResponse<PreparedGetMessagesResponse> }
            
            /// Since we have extended the TTL for a number of messages we need to make sure we update the local
            /// `SnodeReceivedMessageInfo.expirationDateMs` values so we don't end up deleting them
            /// incorrectly before they actually expire on the swarm
            if
                !refreshingConfigHashes.isEmpty,
                let refreshTTLSubReponse: HTTP.BatchSubResponse<UpdateExpiryResponse> = batchResponse
                    .first(where: { $0 is HTTP.BatchSubResponse<UpdateExpiryResponse> })
                    .asType(HTTP.BatchSubResponse<UpdateExpiryResponse>.self),
                let refreshTTLResponse: UpdateExpiryResponse = refreshTTLSubReponse.body,
                let validResults: [String: UpdateExpiryResponseResult] = try? refreshTTLResponse.validResultMap(
                    publicKey: authInfo.sessionId.hexString,
                    validationData: refreshingConfigHashes,
                    using: dependencies
                ),
                let targetResult: UpdateExpiryResponseResult = validResults[snode.ed25519PublicKey],
                let groupedExpiryResult: [UInt64: [String]] = targetResult.changed
                    .updated(with: targetResult.unchanged)
                    .groupedByValue()
                    .nullIfEmpty()
            {
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
            
            return zip(namespaces, messageResponses)
                .reduce(into: [:]) { result, next in
                    guard let messageResponse: PreparedGetMessagesResponse = next.1.body else { return }
                    
                    result[next.0] = (next.1, messageResponse)
                }
        }
    }
    
    private static func preparedBatch(
        _ db: Database,
        requests: [any ErasedPreparedRequest],
        requireAllBatchResponses: Bool,
        associatedWith publicKey: String,
        using dependencies: Dependencies
    ) throws -> HTTP.PreparedRequest<HTTP.BatchResponse> {
        return try SnodeAPI
            .prepareRequest(
                request: Request(
                    endpoint: .batch,
                    publicKey: publicKey,
                    body: HTTP.BatchRequest(requestsKey: .requests, requests: requests)
                ),
                responseType: HTTP.BatchResponse.self,
                requireAllBatchResponses: requireAllBatchResponses,
                using: dependencies
            )
    }
    
    public static func preparedSequence(
        _ db: Database,
        requests: [any ErasedPreparedRequest],
        requireAllBatchResponses: Bool,
        associatedWith publicKey: String,
        using dependencies: Dependencies
    ) throws -> HTTP.PreparedRequest<HTTP.BatchResponse> {
        return try SnodeAPI
            .prepareRequest(
                request: Request(
                    endpoint: .sequence,
                    publicKey: publicKey,
                    body: HTTP.BatchRequest(requestsKey: .requests, requests: requests)
                ),
                responseType: HTTP.BatchResponse.self,
                requireAllBatchResponses: requireAllBatchResponses,
                using: dependencies
            )
    }
    
    // MARK: - Retrieve
    
    public typealias PreparedGetMessagesResponse = (messages: [SnodeReceivedMessage], lastHash: String?)
    
    public static func preparedGetMessages(
        _ db: Database,
        in namespace: SnodeAPI.Namespace,
        snode: Snode,
        maxSize: Int64? = nil,
        authInfo: AuthenticationInfo,
        using dependencies: Dependencies = Dependencies()
    ) throws -> HTTP.PreparedRequest<PreparedGetMessagesResponse> {
        // Prune expired message hashes for this namespace on this service node
        try SnodeReceivedMessageInfo.pruneExpiredMessageHashInfo(
            db,
            for: snode,
            namespace: namespace,
            associatedWith: authInfo.sessionId.hexString,
            using: dependencies
        )

        let maybeLastHash: String? = try SnodeReceivedMessageInfo
            .fetchLastNotExpired(
                db,
                for: snode,
                namespace: namespace,
                associatedWith: authInfo.sessionId.hexString,
                using: dependencies
            )?
            .hash
        let preparedRequest: HTTP.PreparedRequest<GetMessagesResponse> = try {
            // Check if this namespace requires authentication
            guard namespace.requiresReadAuthentication else {
                return try SnodeAPI.prepareRequest(
                    request: Request(
                        endpoint: .getMessages,
                        publicKey: authInfo.sessionId.hexString,
                        body: LegacyGetMessagesRequest(
                            pubkey: authInfo.sessionId.hexString,
                            lastHash: (maybeLastHash ?? ""),
                            namespace: namespace,
                            maxCount: nil,
                            maxSize: maxSize
                        )
                    ),
                    responseType: GetMessagesResponse.self
                )
            }

            return try SnodeAPI.prepareRequest(
                request: Request(
                    endpoint: .getMessages,
                    publicKey: authInfo.sessionId.hexString,
                    body: GetMessagesRequest(
                        lastHash: (maybeLastHash ?? ""),
                        namespace: namespace,
                        authInfo: authInfo,
                        timestampMs: UInt64(SnodeAPI.currentOffsetTimestampMs(using: dependencies)),
                        maxSize: maxSize
                    )
                ),
                responseType: GetMessagesResponse.self
            )
        }()
        
        return preparedRequest
            .map { _, response -> (messages: [SnodeReceivedMessage], lastHash: String?) in
                return (
                    response.messages.compactMap { rawMessage -> SnodeReceivedMessage? in
                        SnodeReceivedMessage(
                            snode: snode,
                            publicKey: authInfo.sessionId.hexString,
                            namespace: namespace,
                            rawMessage: rawMessage
                        )
                    },
                    maybeLastHash
                )
            }
    }
    
    public static func getSessionID(
        for onsName: String,
        using dependencies: Dependencies = Dependencies()
    ) -> AnyPublisher<String, Error> {
        let validationCount = 3
        
        // The name must be lowercased
        let onsName = onsName.lowercased()
        
        // Hash the ONS name using BLAKE2b
        let nameAsData = [UInt8](onsName.data(using: String.Encoding.utf8)!)
        
        guard let nameHash = try? dependencies[singleton: .crypto].perform(.hash(message: nameAsData)) else {
            return Fail(error: SnodeAPIError.hashingFailed)
                .eraseToAnyPublisher()
        }
        
        // Ask 3 different snodes for the Session ID associated with the given name hash
        let base64EncodedNameHash = nameHash.toBase64()
        
        return Publishers
            .MergeMany(
                (0..<validationCount)
                    .map { _ in
                        SnodeAPI
                            .getRandomSnode(using: dependencies)
                            .flatMap { snode -> AnyPublisher<String, Error> in
                                SnodeAPI
                                    .send(
                                        request: SnodeRequest(
                                            endpoint: .oxenDaemonRPCCall,
                                            body: OxenDaemonRPCRequest(
                                                endpoint: .daemonOnsResolve,
                                                body: ONSResolveRequest(
                                                    type: 0, // type 0 means Session
                                                    base64EncodedNameHash: base64EncodedNameHash
                                                )
                                            )
                                        ),
                                        to: snode,
                                        associatedWith: nil,
                                        using: dependencies
                                    )
                                    .decoded(as: ONSResolveResponse.self)
                                    .tryMap { _, response -> String in
                                        try response.sessionId(
                                            nameBytes: nameAsData,
                                            nameHashBytes: nameHash,
                                            using: dependencies
                                        )
                                    }
                                    .retry(4)
                                    .eraseToAnyPublisher()
                            }
                    }
            )
            .collect()
            .tryMap { results -> String in
                guard results.count == validationCount, Set(results).count == 1 else {
                    throw SnodeAPIError.validationFailed
                }
                
                return results[0]
            }
            .eraseToAnyPublisher()
    }
    
    public static func preparedGetExpiries(
        of serverHashes: [String],
        authInfo: AuthenticationInfo,
        using dependencies: Dependencies = Dependencies()
    ) throws -> HTTP.PreparedRequest<GetExpiriesResponse> {
        // FIXME: There is a bug on SS now that a single-hash lookup is not working. Remove it when the bug is fixed
        let serverHashes: [String] = serverHashes.appending("fakehash")
        
        return try SnodeAPI
            .prepareRequest(
                request: Request(
                    endpoint: .getExpiries,
                    publicKey: authInfo.sessionId.hexString,
                    body: GetExpiriesRequest(
                        messageHashes: serverHashes,
                        authInfo: authInfo,
                        timestampMs: UInt64(SnodeAPI.currentOffsetTimestampMs(using: dependencies))
                    )
                ),
                responseType: GetExpiriesResponse.self
            )
    }
    
    // MARK: - Store
    
    public static func preparedSendMessage(
        _ db: Database,
        message: SnodeMessage,
        in namespace: Namespace,
        authInfo: AuthenticationInfo,
        using dependencies: Dependencies
    ) throws -> HTTP.PreparedRequest<SendMessagesResponse> {
        let request: HTTP.PreparedRequest<SendMessagesResponse> = try {
            // Check if this namespace requires authentication
            guard namespace.requiresWriteAuthentication else {
                return try SnodeAPI.prepareRequest(
                    request: Request(
                        endpoint: .sendMessage,
                        publicKey: authInfo.sessionId.hexString,
                        body: LegacySendMessagesRequest(
                            message: message,
                            namespace: namespace
                        )
                    ),
                    responseType: SendMessagesResponse.self
                )
            }
            
            return try SnodeAPI.prepareRequest(
                request: Request(
                    endpoint: .sendMessage,
                    publicKey: authInfo.sessionId.hexString,
                    body: SendMessageRequest(
                        message: message,
                        namespace: namespace,
                        authInfo: authInfo,
                        timestampMs: UInt64(SnodeAPI.currentOffsetTimestampMs(using: dependencies))
                    )
                ),
                responseType: SendMessagesResponse.self
            )
        }()
        
        return request
            .tryMap { _, response -> SendMessagesResponse in
                try response.validateResultMap(
                    publicKey: authInfo.sessionId.hexString,
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
        authInfo: AuthenticationInfo,
        using dependencies: Dependencies = Dependencies()
    ) throws -> HTTP.PreparedRequest<[String: UpdateExpiryResponseResult]> {
        // ShortenOnly and extendOnly cannot be true at the same time
        guard shortenOnly == nil || extendOnly == nil else { throw SnodeAPIError.generic }
        
        return try SnodeAPI
            .prepareRequest(
                request: Request(
                    endpoint: .expire,
                    publicKey: authInfo.sessionId.hexString,
                    body: UpdateExpiryRequest(
                        messageHashes: serverHashes,
                        expiryMs: UInt64(updatedExpiryMs),
                        shorten: shortenOnly,
                        extend: extendOnly,
                        authInfo: authInfo
                    )
                ),
                responseType: UpdateExpiryResponse.self
            )
            .tryMap { _, response -> [String: UpdateExpiryResponseResult] in
                try response.validResultMap(
                    publicKey: authInfo.sessionId.hexString,
                    validationData: serverHashes,
                    using: dependencies
                )
            }
    }
    
    public static func preparedRevokeSubkey(
        subkeyToRevoke: String,
        authInfo: AuthenticationInfo,
        using dependencies: Dependencies = Dependencies()
    ) throws -> HTTP.PreparedRequest<Void> {
        return try SnodeAPI
            .prepareRequest(
                request: Request(
                    endpoint: .revokeSubkey,
                    publicKey: authInfo.sessionId.hexString,
                    body: RevokeSubkeyRequest(
                        subkeyToRevoke: subkeyToRevoke,
                        authInfo: authInfo
                    )
                ),
                responseType: RevokeSubkeyResponse.self
            )
            .tryMap { _, response -> Void in
                try response.validateResultMap(
                    publicKey: authInfo.sessionId.hexString,
                    validationData: subkeyToRevoke,
                    using: dependencies
                )
                
                return ()
            }
    }
    
    // MARK: - Delete
    
    public static func preparedDeleteMessages(
        serverHashes: [String],
        requireSuccessfulDeletion: Bool,
        authInfo: AuthenticationInfo,
        using dependencies: Dependencies = Dependencies()
    ) throws -> HTTP.PreparedRequest<[String: Bool]> {
        return try SnodeAPI
            .prepareRequest(
                request: Request(
                    endpoint: .deleteMessages,
                    publicKey: authInfo.sessionId.hexString,
                    body: DeleteMessagesRequest(
                        messageHashes: serverHashes,
                        requireSuccessfulDeletion: requireSuccessfulDeletion,
                        authInfo: authInfo
                    )
                ),
                responseType: DeleteMessagesResponse.self
            )
            .tryMap { _, response -> [String: Bool] in
                let validResultMap: [String: Bool] = try response.validResultMap(
                    publicKey: authInfo.sessionId.hexString,
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
        authInfo: AuthenticationInfo,
        using dependencies: Dependencies = Dependencies()
    ) throws -> HTTP.PreparedRequest<[String: Bool]> {
        return try SnodeAPI
            .prepareRequest(
                request: Request(
                    endpoint: .deleteAll,
                    publicKey: authInfo.sessionId.hexString,
                    requiresLatestNetworkTime: true,
                    body: DeleteAllMessagesRequest(
                        namespace: namespace,
                        authInfo: authInfo,
                        timestampMs: UInt64(SnodeAPI.currentOffsetTimestampMs(using: dependencies))
                    )
                ),
                responseType: DeleteAllMessagesResponse.self,
                retryCount: maxRetryCount
            )
            .tryMap { info, response -> [String: Bool] in
                guard let targetInfo: LatestTimestampResponseInfo = info as? LatestTimestampResponseInfo else {
                    throw HTTPError.invalidResponse
                }
                
                return try response.validResultMap(
                    publicKey: authInfo.sessionId.hexString,
                    validationData: targetInfo.timestampMs,
                    using: dependencies
                )
            }
    }
    
    /// Clears all the user's data from their swarm. Returns a dictionary of snode public key to deletion confirmation.
    public static func preparedDeleteAllMessages(
        beforeMs: UInt64,
        namespace: SnodeAPI.Namespace,
        authInfo: AuthenticationInfo,
        using dependencies: Dependencies = Dependencies()
    ) throws -> HTTP.PreparedRequest<[String: Bool]> {
        return try SnodeAPI
            .prepareRequest(
                request: Request(
                    endpoint: .deleteAllBefore,
                    publicKey: authInfo.sessionId.hexString,
                    requiresLatestNetworkTime: true,
                    body: DeleteAllBeforeRequest(
                        beforeMs: beforeMs,
                        namespace: namespace,
                        authInfo: authInfo,
                        timestampMs: UInt64(SnodeAPI.currentOffsetTimestampMs(using: dependencies))
                    )
                ),
                responseType: DeleteAllMessagesResponse.self,
                retryCount: maxRetryCount
            )
            .tryMap { _, response -> [String: Bool] in
                try response.validResultMap(
                    publicKey: authInfo.sessionId.hexString,
                    validationData: beforeMs,
                    using: dependencies
                )
            }
    }
    
    // MARK: - Internal API
    
    public static func preparedGetNetworkTime(
        from snode: Snode,
        using dependencies: Dependencies = Dependencies()
    ) throws -> HTTP.PreparedRequest<UInt64> {
        return try SnodeAPI
            .prepareRequest(
                request: Request<SnodeRequest<[String: String]>, Endpoint>(
                    endpoint: .getInfo,
                    snode: snode,
                    body: [:]
                ),
                responseType: GetNetworkTimestampResponse.self
            )
            .map { _, response in
                // Assume we've fetched the networkTime in order to send a message to the specified snode, in
                // which case we want to update the 'clockOffsetMs' value for subsequent requests
                let offset = (Int64(response.timestamp) - Int64(floor(dependencies.dateNow.timeIntervalSince1970 * 1000)))
                SnodeAPI.clockOffsetMs.mutate { $0 = offset }

                return response.timestamp
            }
    }
    
    internal static func getRandomSnode(
        using dependencies: Dependencies
    ) -> AnyPublisher<Snode, Error> {
        // randomElement() uses the system's default random generator, which is cryptographically secure
        return getSnodePool(using: dependencies)
            .map { $0.randomElement()! }
            .eraseToAnyPublisher()
    }
    
    private static func getSnodePoolFromSeedNode(
        using dependencies: Dependencies
    ) -> AnyPublisher<Set<Snode>, Error> {
        let request: SnodeRequest = SnodeRequest(
            endpoint: .jsonGetNServiceNodes,
            body: GetServiceNodesRequest(
                activeOnly: true,
                limit: 256,
                fields: GetServiceNodesRequest.Fields(
                    publicIp: true,
                    storagePort: true,
                    pubkeyEd25519: true,
                    pubkeyX25519: true
                )
            )
        )
        
        guard let target: String = seedNodePool.randomElement() else {
            return Fail(error: SnodeAPIError.snodePoolUpdatingFailed)
                .eraseToAnyPublisher()
        }
        guard let payload: Data = try? JSONEncoder(using: dependencies).encode(request) else {
            return Fail(error: HTTPError.invalidJSON)
                .eraseToAnyPublisher()
        }
        
        SNLog("Populating snode pool using seed node: \(target).")
        
        return HTTP
            .execute(
                .post,
                "\(target)/json_rpc",
                body: payload,
                useSeedNodeURLSession: true
            )
            .decoded(as: SnodePoolResponse.self, using: dependencies)
            .mapError { error in
                switch error {
                    case HTTPError.parsingFailed: return SnodeAPIError.snodePoolUpdatingFailed
                    default: return error
                }
            }
            .map { snodePool -> Set<Snode> in
                snodePool.result
                    .serviceNodeStates
                    .compactMap { $0.value }
                    .asSet()
            }
            .retry(2)
            .handleEvents(
                receiveCompletion: { result in
                    switch result {
                        case .finished: SNLog("Got snode pool from seed node: \(target).")
                        case .failure: SNLog("Failed to contact seed node at: \(target).")
                    }
                }
            )
            .eraseToAnyPublisher()
    }
    
    private static func getSnodePoolFromSnode(
        using dependencies: Dependencies
    ) -> AnyPublisher<Set<Snode>, Error> {
        var snodePool = SnodeAPI.snodePool.wrappedValue
        var snodes: Set<Snode> = []
        (0..<3).forEach { _ in
            guard let snode = snodePool.randomElement() else { return }
            
            snodePool.remove(snode)
            snodes.insert(snode)
        }
        
        return Publishers
            .MergeMany(
                snodes
                    .map { snode -> AnyPublisher<Set<Snode>, Error> in
                        // Don't specify a limit in the request. Service nodes return a shuffled
                        // list of nodes so if we specify a limit the 3 responses we get might have
                        // very little overlap.
                        SnodeAPI
                            .send(
                                request: SnodeRequest(
                                    endpoint: .oxenDaemonRPCCall,
                                    body: OxenDaemonRPCRequest(
                                        endpoint: .daemonGetServiceNodes,
                                        body: GetServiceNodesRequest(
                                            activeOnly: true,
                                            limit: nil,
                                            fields: GetServiceNodesRequest.Fields(
                                                publicIp: true,
                                                storagePort: true,
                                                pubkeyEd25519: true,
                                                pubkeyX25519: true
                                            )
                                        )
                                    )
                                ),
                                to: snode,
                                associatedWith: nil,
                                using: dependencies
                            )
                            .decoded(as: SnodePoolResponse.self, using: dependencies)
                            .mapError { error -> Error in
                                switch error {
                                    case HTTPError.parsingFailed:
                                        return SnodeAPIError.snodePoolUpdatingFailed
                                        
                                    default: return error
                                }
                            }
                            .map { _, snodePool -> Set<Snode> in
                                snodePool.result
                                    .serviceNodeStates
                                    .compactMap { $0.value }
                                    .asSet()
                            }
                            .retry(4)
                            .eraseToAnyPublisher()
                    }
            )
            .collect()
            .tryMap { results -> Set<Snode> in
                let result: Set<Snode> = results.reduce(Set()) { prev, next in prev.intersection(next) }
                
                // We want the snodes to agree on at least this many snodes
                guard result.count > 24 else { throw SnodeAPIError.inconsistentSnodePools }
                
                // Limit the snode pool size to 256 so that we don't go too long without
                // refreshing it
                return Set(result.prefix(256))
            }
            .eraseToAnyPublisher()
    }
    
    private static func send<T: Encodable>(
        request: SnodeRequest<T>,
        to snode: Snode,
        associatedWith publicKey: String?,
        using dependencies: Dependencies
    ) -> AnyPublisher<(ResponseInfoType, Data?), Error> {
        guard let payload: Data = try? JSONEncoder(using: dependencies).encode(request) else {
            return Fail(error: HTTPError.invalidJSON)
                .eraseToAnyPublisher()
        }
        
        guard Features.useOnionRequests else {
            return HTTP
                .execute(
                    .post,
                    "\(snode.address):\(snode.port)/storage_rpc/v1",
                    body: payload
                )
                .map { response in (HTTP.ResponseInfo(code: -1, headers: [:]), response) }
                .mapError { error in
                    switch error {
                        case HTTPError.httpRequestFailed(let statusCode, let data):
                            return SnodeAPI
                                .handleError(
                                    withStatusCode: statusCode,
                                    data: data,
                                    forSnode: snode,
                                    associatedWith: publicKey,
                                    using: dependencies
                                )
                                .defaulting(to: error)
                            
                        default: return error
                    }
                }
                .eraseToAnyPublisher()
        }
        
        return dependencies[singleton: .network]
            .send(.onionRequest(payload, to: snode))
            .mapError { error in
                switch error {
                    case HTTPError.httpRequestFailed(let statusCode, let data):
                        return SnodeAPI
                            .handleError(
                                withStatusCode: statusCode,
                                data: data,
                                forSnode: snode,
                                associatedWith: publicKey,
                                using: dependencies
                            )
                            .defaulting(to: error)
                        
                    default: return error
                }
            }
            .handleEvents(
                receiveOutput: { _, maybeData in
                    // Extract and store hard fork information if returned
                    guard
                        let data: Data = maybeData,
                        let snodeResponse: SnodeResponse = try? JSONDecoder(using: dependencies)
                            .decode(SnodeResponse.self, from: data)
                    else { return }
                    
                    if snodeResponse.hardFork[1] > softfork {
                        softfork = snodeResponse.hardFork[1]
                        dependencies[defaults: .standard, key: .softfork] = softfork
                    }
                    
                    if snodeResponse.hardFork[0] > hardfork {
                        hardfork = snodeResponse.hardFork[0]
                        dependencies[defaults: .standard, key: .hardfork] = hardfork
                        softfork = snodeResponse.hardFork[1]
                        dependencies[defaults: .standard, key: .softfork] = softfork
                    }
                }
            )
            .eraseToAnyPublisher()
    }
    
    // MARK: - Parsing
    
    // The parsing utilities below use a best attempt approach to parsing; they warn for parsing
    // failures but don't throw exceptions.

    private static func parseSnodes(
        from responseData: Data?,
        using dependencies: Dependencies
    ) -> Set<Snode> {
        guard
            let responseData: Data = responseData,
            let responseJson: JSON = try? JSONSerialization.jsonObject(
                with: responseData,
                options: [ .fragmentsAllowed ]
            ) as? JSON
        else {
            SNLog("Failed to parse snodes from response data.")
            return []
        }
        guard let rawSnodes = responseJson["snodes"] as? [JSON] else {
            SNLog("Failed to parse snodes from: \(responseJson).")
            return []
        }
        
        guard let snodeData: Data = try? JSONSerialization.data(withJSONObject: rawSnodes, options: []) else {
            return []
        }
        
        // FIXME: Hopefully at some point this different Snode structure will be deprecated and can be removed
        if
            let swarmSnodes: [SwarmSnode] = try? JSONDecoder(using: dependencies)
                .decode([Failable<SwarmSnode>].self, from: snodeData)
                .compactMap({ $0.value }),
            !swarmSnodes.isEmpty
        {
            return swarmSnodes.map { $0.toSnode() }.asSet()
        }
        
        return ((try? JSONDecoder(using: dependencies).decode([Failable<Snode>].self, from: snodeData)) ?? [])
            .compactMap { $0.value }
            .asSet()
    }

    // MARK: - Error Handling
    
    @discardableResult
    internal static func handleError(
        withStatusCode statusCode: UInt,
        data: Data?,
        forSnode snode: Snode,
        associatedWith publicKey: String? = nil,
        using dependencies: Dependencies
    ) -> Error? {
        func handleBadSnode(using dependencies: Dependencies) {
            let oldFailureCount = (SnodeAPI.snodeFailureCount.wrappedValue[snode] ?? 0)
            let newFailureCount = oldFailureCount + 1
            SnodeAPI.snodeFailureCount.mutate { $0[snode] = newFailureCount }
            SNLog("Couldn't reach snode at: \(snode); setting failure count to \(newFailureCount).")
            if newFailureCount >= SnodeAPI.snodeFailureThreshold {
                SNLog("Failure threshold reached for: \(snode); dropping it.")
                if let publicKey = publicKey {
                    SnodeAPI.dropSnodeFromSwarmIfNeeded(snode, publicKey: publicKey, using: dependencies)
                }
                SnodeAPI.dropSnodeFromSnodePool(snode)
                SNLog("Snode pool count: \(snodePool.wrappedValue.count).")
                SnodeAPI.snodeFailureCount.mutate { $0[snode] = 0 }
            }
        }
        
        switch statusCode {
            case 500, 502, 503:
                // The snode is unreachable
                handleBadSnode(using: dependencies)
                
            case 404:
                // May caused by invalid open groups
                SNLog("Can't reach the server.")
                
            case 406:
                SNLog("The user's clock is out of sync with the service node network.")
                return SnodeAPIError.clockOutOfSync
                
            case 421:
                // The snode isn't associated with the given public key anymore
                if let publicKey = publicKey {
                    func invalidateSwarm() {
                        SNLog("Invalidating swarm for: \(publicKey).")
                        SnodeAPI.dropSnodeFromSwarmIfNeeded(snode, publicKey: publicKey, using: dependencies)
                    }
                    
                    if let data: Data = data {
                        let snodes = parseSnodes(from: data, using: dependencies)
                        
                        if !snodes.isEmpty {
                            setSwarm(to: snodes, for: publicKey, using: dependencies)
                        }
                        else {
                            invalidateSwarm()
                        }
                    }
                    else {
                        invalidateSwarm()
                    }
                }
                else {
                    SNLog("Got a 421 without an associated public key.")
                }
                
            default:
                handleBadSnode(using: dependencies)
                let message: String = {
                    if let data: Data = data, let stringFromData = String(data: data, encoding: .utf8) {
                        return stringFromData
                    }
                    return "Empty data."
                }()
                SNLog("Unhandled response code: \(statusCode), messasge: \(message)")
        }
        
        return nil
    }
    
    // MARK: - Convenience
    
    private static func prepareRequest<T: Encodable, R: Decodable>(
        request: Request<T, Endpoint>,
        responseType: R.Type,
        requireAllBatchResponses: Bool = true,
        retryCount: Int = 0,
        timeout: TimeInterval = HTTP.defaultTimeout,
        using dependencies: Dependencies = Dependencies()
    ) throws -> HTTP.PreparedRequest<R> {
        return HTTP.PreparedRequest<R>(
            request: request,
            urlRequest: try request.generateUrlRequest(using: dependencies),
            responseType: responseType,
            requireAllBatchResponses: requireAllBatchResponses,
            retryCount: retryCount,
            timeout: timeout
        )
    }
}

@objc(SNSnodeAPI)
public final class SNSnodeAPI: NSObject {
    @objc(currentOffsetTimestampMs)
    public static func currentOffsetTimestampMs() -> UInt64 {
        return UInt64(SnodeAPI.currentOffsetTimestampMs())
    }
}

// MARK: - Publisher Convenience

public extension Publisher where Output == Set<Snode> {
    func tryFlatMapWithRandomSnode<T, P>(
        maxPublishers: Subscribers.Demand = .unlimited,
        retry retries: Int = 0,
        drainBehaviour: Atomic<SwarmDrainBehaviour> = .alwaysRandom,
        _ transform: @escaping (Snode) throws -> P
    ) -> AnyPublisher<T, Error> where T == P.Output, P: Publisher, P.Failure == Error {
        return self
            .mapError { $0 }
            .flatMap(maxPublishers: maxPublishers) { swarm -> AnyPublisher<T, Error> in
                // If we don't want to reuse a specific snode multiple times then just grab a
                // random one from the swarm every time
                var remainingSnodes: Set<Snode> = {
                    switch drainBehaviour.wrappedValue {
                        case .alwaysRandom: return swarm
                        case .limitedReuse(_, let targetSnode, _, let usedSnodes):
                            // If we've used all of the snodes then reset the used list
                            guard targetSnode != nil || usedSnodes != swarm else {
                                drainBehaviour.mutate { $0 = $0.reset() }
                                return swarm
                            }
                            
                            return swarm.subtracting(usedSnodes)
                    }
                }()
                
                return Just(())
                    .setFailureType(to: Error.self)
                    .tryFlatMap(maxPublishers: maxPublishers) { _ -> AnyPublisher<T, Error> in
                        let snode: Snode = try {
                            switch drainBehaviour.wrappedValue {
                                case .limitedReuse(_, .some(let targetSnode), _, _): return targetSnode
                                default: break
                            }
                            
                            // Select the next snode
                            return try remainingSnodes.popRandomElement() ?? { throw SnodeAPIError.generic }()
                        }()
                        drainBehaviour.mutate { $0 = $0.use(snode: snode) }
                        
                        return try transform(snode)
                            .eraseToAnyPublisher()
                    }
                    .retry(retries)
                    .eraseToAnyPublisher()
            }
            .eraseToAnyPublisher()
    }
}

// MARK: - Snode Convenience

private extension Snode {
    var server: String { "\(address):\(port)" }
    var urlString: String { "\(address):\(port)/storage_rpc/v1" }
}

// MARK: - Request<T, EndpointType> Convenience

private extension Request {
    init<B: Encodable>(
        endpoint: SnodeAPI.Endpoint,
        publicKey: String,
        body: B
    ) where T == SnodeRequest<B>, Endpoint == SnodeAPI.Endpoint {
        self = Request(
            method: .post,
            endpoint: endpoint,
            publicKey: publicKey,
            body: SnodeRequest<B>(
                endpoint: endpoint,
                body: body
            )
        )
    }
    
    init<B: Encodable>(
        endpoint: SnodeAPI.Endpoint,
        snode: Snode,
        body: B
    ) where T == SnodeRequest<B>, Endpoint == SnodeAPI.Endpoint {
        self = Request(
            method: .post,
            endpoint: endpoint,
            snode: snode,
            body: SnodeRequest<B>(
                endpoint: endpoint,
                body: body
            )
        )
    }
    
    init<B>(
        endpoint: SnodeAPI.Endpoint,
        publicKey: String,
        requiresLatestNetworkTime: Bool,
        body: B
    ) where T == SnodeRequest<B>, Endpoint == SnodeAPI.Endpoint, B: Encodable & UpdatableTimestamp {
        self = Request(
            method: .post,
            endpoint: endpoint,
            publicKey: publicKey,
            requiresLatestNetworkTime: requiresLatestNetworkTime,
            body: SnodeRequest<B>(
                endpoint: endpoint,
                body: body
            )
        )
    }
}
