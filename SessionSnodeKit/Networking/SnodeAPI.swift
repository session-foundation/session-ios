// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import Combine
import Sodium
import GRDB
import SessionUtilitiesKit

public extension Network.RequestType {
    static func message(
        _ message: SnodeMessage,
        in namespace: SnodeAPI.Namespace
    ) -> Network.RequestType<SendMessagesResponse> {
        return Network.RequestType(id: "snodeAPI.sendMessage", args: [message, namespace]) {
            SnodeAPI.sendMessage(message, in: namespace, using: $0)
        }
    }
}

public final class SnodeAPI {
    internal static let sodium: Atomic<Sodium> = Atomic(Sodium())
    
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
    
    public static var hardfork = UserDefaults.standard[.hardfork]
    public static var softfork = UserDefaults.standard[.softfork]

    // MARK: - Settings
    
    internal static let maxRetryCount: Int = 8
    private static let minSwarmSnodeCount: Int = 3
    private static let seedNodePool: Set<Snode> = {
        guard !Features.useTestnet else {
            return [
                Snode(
                    ip: "144.76.164.202",
                    lmqPort: 35400,
                    x25519PublicKey: "80adaead94db3b0402a6057869bdbe63204a28e93589fd95a035480ed6c03b45",
                    ed25519PublicKey: "decaf007f26d3d6f9b845ad031ffdf6d04638c25bb10b8fffbbe99135303c4b9"
                )
            ]
        }
        
        return [
            Snode(
                ip: "144.76.164.202",
                lmqPort: 20200,
                x25519PublicKey: "be83fe1221fdd85e4d9d2b62e2a34ba82eaf73da45700185d25aff4575ec6018",
                ed25519PublicKey: "1f000f09a7b07828dcb72af7cd16857050c10c02bd58afb0e38111fb6cda1fef"
            ),
            Snode(
                ip: "88.99.102.229",
                lmqPort: 20201,
                x25519PublicKey: "05c8c236cf6c4013b8ca930a343fdc62c413ba038a16bb12e75632e0179d404a",
                ed25519PublicKey: "1f101f0acee4db6f31aaa8b4df134e85ca8a4878efaef7f971e88ab144c1a7ce"
            ),
            Snode(
                ip: "195.16.73.17",
                lmqPort: 20202,
                x25519PublicKey: "22ced8efd4e5faf15531e9b9244b2c1de299342892b97d19268c4db69ab6350f",
                ed25519PublicKey: "1f202f00f4d2d4acc01e20773999a291cf3e3136c325474d159814e06199919f"
            ),
            Snode(
                ip: "104.194.11.120",
                lmqPort: 20203,
                x25519PublicKey: "330ad0d67b58f39a6f46fbeaf5c3622860dfa584e9d787f70c3702031712767a",
                ed25519PublicKey: "1f303f1d7523c46fa5398826740d13282d26b5de90fbae5749442f66afb6d78b"
            ),
            Snode(
                ip: "104.194.8.115",
                lmqPort: 20204,
                x25519PublicKey: "929c5fc60efa1834a2d4a77a4a33387c1c3d5afc2b192c2ba0e040b29388b216",
                ed25519PublicKey: "1f604f1c858a121a681d8f9b470ef72e6946ee1b9c5ad15a35e16b50c28db7b0"
            )
        ]
    }()
    private static let snodeFailureThreshold: Int = 3
    private static let minSnodePoolCount: Int = 12
    
    public static func currentOffsetTimestampMs() -> Int64 {
        return Int64(
            Int64(floor(Date().timeIntervalSince1970 * 1000)) +
            SnodeAPI.clockOffsetMs.wrappedValue
        )
    }

    // MARK: Snode Pool Interaction
    
    private static var hasInsufficientSnodes: Bool { snodePool.wrappedValue.count < minSnodePoolCount }
    
    private static func loadSnodePoolIfNeeded() {
        guard !hasLoadedSnodePool.wrappedValue else { return }
        
        let fetchedSnodePool: Set<Snode> = Storage.shared
            .read { db in try Snode.fetchSet(db) }
            .defaulting(to: [])
        
        snodePool.mutate { $0 = fetchedSnodePool }
        hasLoadedSnodePool.mutate { $0 = true }
    }
    
    private static func setSnodePool(_ db: Database? = nil, to newValue: Set<Snode>) {
        guard let db: Database = db else {
            Storage.shared.write { db in setSnodePool(db, to: newValue) }
            return
        }
        
        snodePool.mutate { $0 = newValue }
        
        _ = try? Snode.deleteAll(db)
        newValue.forEach { try? $0.save(db) }
    }
    
    internal static func dropSnodeFromSnodePool(_ snode: Snode) {
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
    
    private static func loadSwarmIfNeeded(for publicKey: String) {
        guard !loadedSwarms.wrappedValue.contains(publicKey) else { return }
        
        let updatedCacheForKey: Set<Snode> = Storage.shared
           .read { db in try Snode.fetchSet(db, publicKey: publicKey) }
           .defaulting(to: [])
        
        swarmCache.mutate { $0[publicKey] = updatedCacheForKey }
        loadedSwarms.mutate { $0.insert(publicKey) }
    }
    
    internal static func setSwarm(to newValue: Set<Snode>, for publicKey: String, persist: Bool = true) {
        swarmCache.mutate { $0[publicKey] = newValue }
        
        guard persist else { return }
        
        Storage.shared.write { db in
            try? newValue.save(db, key: publicKey)
        }
    }
    
    public static func dropSnodeFromSwarmIfNeeded(_ snode: Snode, publicKey: String) {
        let swarmOrNil = swarmCache.wrappedValue[publicKey]
        guard var swarm = swarmOrNil, let index = swarm.firstIndex(of: snode) else { return }
        swarm.remove(at: index)
        setSwarm(to: swarm, for: publicKey)
    }

    // MARK: - Snode API
    
    public static func hasCachedSnodesIncludingExpired() -> Bool {
        loadSnodePoolIfNeeded()
        
        return !hasInsufficientSnodes
    }
    
    public static func getSnodePool(
        ed25519SecretKey: [UInt8]? = nil,
        using dependencies: Dependencies = Dependencies()
    ) -> AnyPublisher<Set<Snode>, Error> {
        loadSnodePoolIfNeeded()
        
        let now: Date = Date()
        let hasSnodePoolExpired: Bool = dependencies.storage[.lastSnodePoolRefreshDate]
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
                guard snodePool.count >= minSnodePoolCount else { return getSnodePoolFromSeedNode(ed25519SecretKey: ed25519SecretKey, using: dependencies) }
                
                return getSnodePoolFromSnode(using: dependencies)
                    .catch { _ in getSnodePoolFromSeedNode(ed25519SecretKey: ed25519SecretKey, using: dependencies) }
                    .eraseToAnyPublisher()
            }()
            
            /// Need to include the post-request code and a `shareReplay` within the publisher otherwise it can still be executed
            /// multiple times as a result of multiple subscribers
            let publisher: AnyPublisher<Set<Snode>, Error> = targetPublisher
                .tryFlatMap { snodePool -> AnyPublisher<Set<Snode>, Error> in
                    guard !snodePool.isEmpty else { throw SnodeAPIError.snodePoolUpdatingFailed }
                    
                    return Storage.shared
                        .writePublisher { db in
                            db[.lastSnodePoolRefreshDate] = now
                            setSnodePool(db, to: snodePool)
                            
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
        for swarmPublicKey: String,
        using dependencies: Dependencies = Dependencies()
    ) -> AnyPublisher<Set<Snode>, Error> {
        loadSwarmIfNeeded(for: swarmPublicKey)
        
        if let cachedSwarm = swarmCache.wrappedValue[swarmPublicKey], cachedSwarm.count >= minSwarmSnodeCount {
            return Just(cachedSwarm)
                .setFailureType(to: Error.self)
                .eraseToAnyPublisher()
        }
        
        SNLog("Getting swarm for: \((swarmPublicKey == getUserHexEncodedPublicKey()) ? "self" : swarmPublicKey).")
        
        return getRandomSnode()
            .tryFlatMap { snode in
                try SnodeAPI
                    .prepareRequest(
                        request: Request(
                            endpoint: .getSwarm,
                            snode: snode,
                            swarmPublicKey: swarmPublicKey,
                            body: GetSwarmRequest(pubkey: swarmPublicKey)
                        ),
                        responseType: GetSwarmResponse.self,
                        using: dependencies
                    )
                    .send(using: dependencies)
                    .retry(4)
                    .map { _, response in response.snodes }
                    .handleEvents(
                        receiveOutput: { snodes in setSwarm(to: snodes, for: swarmPublicKey) }
                    )
                    .eraseToAnyPublisher()
            }
    }

    // MARK: - Batching & Polling
    
    public static func poll(
        namespaces: [SnodeAPI.Namespace],
        refreshingConfigHashes: [String] = [],
        from snode: Snode,
        swarmPublicKey: String,
        using dependencies: Dependencies
    ) -> AnyPublisher<[SnodeAPI.Namespace: (info: ResponseInfoType, data: (messages: [SnodeReceivedMessage], lastHash: String?)?)], Error> {
        guard let userED25519KeyPair = Identity.fetchUserEd25519KeyPair() else {
            return Fail(error: SnodeAPIError.noKeyPair)
                .eraseToAnyPublisher()
        }
        
        let userX25519PublicKey: String = getUserHexEncodedPublicKey(using: dependencies)
        
        return Just(())
            .setFailureType(to: Error.self)
            .map { _ -> [SnodeAPI.Namespace: String] in
                namespaces
                    .reduce(into: [:]) { result, namespace in
                        guard namespace.shouldFetchSinceLastHash else { return }
                        
                        // Prune expired message hashes for this namespace on this service node
                        SnodeReceivedMessageInfo.pruneExpiredMessageHashInfo(
                            for: snode,
                            namespace: namespace,
                            associatedWith: swarmPublicKey,
                            using: dependencies
                        )
                        
                        result[namespace] = SnodeReceivedMessageInfo
                            .fetchLastNotExpired(
                                for: snode,
                                namespace: namespace,
                                associatedWith: swarmPublicKey,
                                using: dependencies
                            )?
                            .hash
                    }
            }
            .tryFlatMap { namespaceLastHash -> AnyPublisher<[SnodeAPI.Namespace: (info: ResponseInfoType, data: (messages: [SnodeReceivedMessage], lastHash: String?)?)], Error> in
                var requests: [any ErasedPreparedRequest] = []
                
                // If we have any config hashes to refresh TTLs then add those requests first
                if !refreshingConfigHashes.isEmpty {
                    requests.append(
                        try SnodeAPI.prepareRequest(
                            request: Request(
                                endpoint: .expire,
                                swarmPublicKey: swarmPublicKey,
                                body: UpdateExpiryRequest(
                                    messageHashes: refreshingConfigHashes,
                                    expiryMs: UInt64(
                                        SnodeAPI.currentOffsetTimestampMs() +
                                        (30 * 24 * 60 * 60 * 1000) // 30 days
                                    ),
                                    extend: true,
                                    pubkey: userX25519PublicKey,
                                    ed25519PublicKey: userED25519KeyPair.publicKey,
                                    ed25519SecretKey: userED25519KeyPair.secretKey,
                                    subkey: nil    // TODO: Need to get this
                                )
                            ),
                            responseType: UpdateExpiryResponse.self,
                            using: dependencies
                        )
                    )
                }
                
                // Determine the maxSize each namespace in the request should take up
                let namespaceMaxSizeMap: [SnodeAPI.Namespace: Int64] = SnodeAPI.Namespace.maxSizeMap(for: namespaces)
                let fallbackSize: Int64 = (namespaceMaxSizeMap.values.min() ?? 1)
                
                // Add the various 'getMessages' requests
                requests.append(
                    contentsOf: try namespaces.map { namespace -> any ErasedPreparedRequest in
                        // Check if this namespace requires authentication
                        guard namespace.requiresReadAuthentication else {
                            return try SnodeAPI.prepareRequest(
                                request: Request(
                                    endpoint: .getMessages,
                                    swarmPublicKey: swarmPublicKey,
                                    body: LegacyGetMessagesRequest(
                                        pubkey: swarmPublicKey,
                                        lastHash: (namespaceLastHash[namespace] ?? ""),
                                        namespace: namespace,
                                        maxCount: nil,
                                        maxSize: namespaceMaxSizeMap[namespace]
                                            .defaulting(to: fallbackSize)
                                    )
                                ),
                                responseType: GetMessagesResponse.self,
                                using: dependencies
                            )
                        }
                        
                        return try SnodeAPI.prepareRequest(
                            request: Request(
                                endpoint: .getMessages,
                                swarmPublicKey: swarmPublicKey,
                                body: GetMessagesRequest(
                                    lastHash: (namespaceLastHash[namespace] ?? ""),
                                    namespace: namespace,
                                    pubkey: swarmPublicKey,
                                    subkey: nil,    // TODO: Need to get this
                                    timestampMs: UInt64(SnodeAPI.currentOffsetTimestampMs()),
                                    ed25519PublicKey: userED25519KeyPair.publicKey,
                                    ed25519SecretKey: userED25519KeyPair.secretKey,
                                    maxSize: namespaceMaxSizeMap[namespace]
                                        .defaulting(to: fallbackSize)
                                )
                            ),
                            responseType: GetMessagesResponse.self,
                            using: dependencies
                        )
                    }
                )
                
                // Actually send the request
                return try SnodeAPI
                    .prepareRequest(
                        request: Request(
                            endpoint: .batch,
                            swarmPublicKey: swarmPublicKey,
                            body: Network.BatchRequest(requestsKey: .requests, requests: requests)
                        ),
                        responseType: Network.BatchResponse.self,
                        requireAllBatchResponses: true,
                        using: dependencies
                    )
                    .send(using: dependencies)
                    .map { (_: ResponseInfoType, batchResponse: Network.BatchResponse) -> [SnodeAPI.Namespace: (info: ResponseInfoType, data: (messages: [SnodeReceivedMessage], lastHash: String?)?)] in
                        let messageResponses: [Network.BatchSubResponse<GetMessagesResponse>] = batchResponse
                            .compactMap { $0 as? Network.BatchSubResponse<GetMessagesResponse> }
                        
                        /// Since we have extended the TTL for a number of messages we need to make sure we update the local
                        /// `SnodeReceivedMessageInfo.expirationDateMs` values so we don't end up deleting them
                        /// incorrectly before they actually expire on the swarm
                        if
                            !refreshingConfigHashes.isEmpty,
                            let refreshTTLSubReponse: Network.BatchSubResponse<UpdateExpiryResponse> = batchResponse
                                .first(where: { $0 is Network.BatchSubResponse<UpdateExpiryResponse> })
                                .asType(Network.BatchSubResponse<UpdateExpiryResponse>.self),
                            let refreshTTLResponse: UpdateExpiryResponse = refreshTTLSubReponse.body,
                            let validResults: [String: UpdateExpiryResponseResult] = try? refreshTTLResponse.validResultMap(
                                sodium: sodium.wrappedValue,
                                userX25519PublicKey: getUserHexEncodedPublicKey(),
                                validationData: refreshingConfigHashes
                            ),
                            let targetResult: UpdateExpiryResponseResult = validResults[snode.ed25519PublicKey],
                            let groupedExpiryResult: [UInt64: [String]] = targetResult.changed
                                .updated(with: targetResult.unchanged)
                                .groupedByValue()
                                .nullIfEmpty()
                        {
                            dependencies.storage.writeAsync { db in
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
                                guard let messageResponse: GetMessagesResponse = next.1.body else { return }
                                
                                let namespace: SnodeAPI.Namespace = next.0
                                
                                result[namespace] = (
                                    info: next.1,
                                    data: (
                                        messages: messageResponse.messages
                                            .compactMap { rawMessage -> SnodeReceivedMessage? in
                                                SnodeReceivedMessage(
                                                    snode: snode,
                                                    publicKey: swarmPublicKey,
                                                    namespace: namespace,
                                                    rawMessage: rawMessage
                                                )
                                            },
                                        lastHash: namespaceLastHash[namespace]
                                    )
                                )
                            }
                    }
                    .eraseToAnyPublisher()
        }
        .eraseToAnyPublisher()
    }
    
    /// **Note:** This is the direct request to retrieve messages so should be retrieved automatically from the `poll()` method, in order to call
    /// this directly remove the `@available` line
    @available(*, unavailable, message: "Avoid using this directly, use the pre-built `poll()` method instead")
    public static func getMessages(
        in namespace: SnodeAPI.Namespace,
        from snode: Snode,
        swarmPublicKey: String,
        using dependencies: Dependencies = Dependencies()
    ) -> AnyPublisher<(info: ResponseInfoType, data: (messages: [SnodeReceivedMessage], lastHash: String?)?), Error> {
        return Deferred {
            Future<String?, Error> { resolver in
                // Prune expired message hashes for this namespace on this service node
                SnodeReceivedMessageInfo.pruneExpiredMessageHashInfo(
                    for: snode,
                    namespace: namespace,
                    associatedWith: swarmPublicKey,
                    using: dependencies
                )
                
                let maybeLastHash: String? = SnodeReceivedMessageInfo
                    .fetchLastNotExpired(
                        for: snode,
                        namespace: namespace,
                        associatedWith: swarmPublicKey,
                        using: dependencies
                    )?
                    .hash
                
                resolver(Result.success(maybeLastHash))
            }
        }
        .tryFlatMap { lastHash -> AnyPublisher<(info: ResponseInfoType, data: GetMessagesResponse?, lastHash: String?), Error> in
            guard namespace.requiresReadAuthentication else {
                return try SnodeAPI
                    .prepareRequest(
                        request: Request(
                            endpoint: .getMessages,
                            snode: snode,
                            swarmPublicKey: swarmPublicKey,
                            body: LegacyGetMessagesRequest(
                                pubkey: swarmPublicKey,
                                lastHash: (lastHash ?? ""),
                                namespace: namespace,
                                maxCount: nil,
                                maxSize: nil
                            )
                        ),
                        responseType: GetMessagesResponse.self,
                        using: dependencies
                    )
                    .send(using: dependencies)
                    .map { info, data in (info, data, lastHash) }
                    .eraseToAnyPublisher()
            }
            
            guard let userED25519KeyPair: KeyPair = Storage.shared.read({ db in Identity.fetchUserEd25519KeyPair(db) }) else {
                throw SnodeAPIError.noKeyPair
            }
            
            return try SnodeAPI
                .prepareRequest(
                    request: Request(
                        endpoint: .getMessages,
                        snode: snode,
                        swarmPublicKey: swarmPublicKey,
                        body: GetMessagesRequest(
                            lastHash: (lastHash ?? ""),
                            namespace: namespace,
                            pubkey: swarmPublicKey,
                            subkey: nil,
                            timestampMs: UInt64(SnodeAPI.currentOffsetTimestampMs()),
                            ed25519PublicKey: userED25519KeyPair.publicKey,
                            ed25519SecretKey: userED25519KeyPair.secretKey
                        )
                    ),
                    responseType: GetMessagesResponse.self,
                    using: dependencies
                )
                .send(using: dependencies)
                .map { info, data in (info, data, lastHash) }
                .eraseToAnyPublisher()
        }
        .map { info, data, lastHash -> (info: ResponseInfoType, data: (messages: [SnodeReceivedMessage], lastHash: String?)?) in
            return (
                info: info,
                data: data.map { messageResponse -> (messages: [SnodeReceivedMessage], lastHash: String?) in
                    return (
                        messages: messageResponse.messages
                            .compactMap { rawMessage -> SnodeReceivedMessage? in
                                SnodeReceivedMessage(
                                    snode: snode,
                                    publicKey: swarmPublicKey,
                                    namespace: namespace,
                                    rawMessage: rawMessage
                                )
                            },
                        lastHash: lastHash
                    )
                }
            )
        }
        .eraseToAnyPublisher()
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
        
        guard let nameHash = sodium.wrappedValue.genericHash.hash(message: nameAsData) else {
            return Fail(error: SnodeAPIError.onsHashingFailed)
                .eraseToAnyPublisher()
        }
        
        // Ask 3 different snodes for the Session ID associated with the given name hash
        let base64EncodedNameHash = nameHash.toBase64()
        
        return Publishers
            .MergeMany(
                (0..<validationCount)
                    .map { _ in
                        SnodeAPI
                            .getRandomSnode()
                            .tryFlatMap { snode -> AnyPublisher<String, Error> in
                                try SnodeAPI
                                    .prepareRequest(
                                        request: Request(
                                            endpoint: .oxenDaemonRPCCall,
                                            snode: snode,
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
                                    .tryMap { _, response -> String in
                                        try response.sessionId(
                                            sodium: sodium.wrappedValue,
                                            nameBytes: nameAsData,
                                            nameHashBytes: nameHash
                                        )
                                    }
                                    .send(using: dependencies)
                                    .retry(4)
                                    .map { _, sessionId in sessionId }
                                    .eraseToAnyPublisher()
                            }
                    }
            )
            .collect()
            .tryMap { results -> String in
                guard results.count == validationCount, Set(results).count == 1 else {
                    throw SnodeAPIError.onsValidationFailed
                }
                
                return results[0]
            }
            .eraseToAnyPublisher()
    }
    
    public static func getExpiries(
        from snode: Snode,
        swarmPublicKey: String,
        of serverHashes: [String],
        using dependencies: Dependencies = Dependencies()
    ) -> AnyPublisher<(ResponseInfoType, GetExpiriesResponse), Error> {
        guard let userED25519KeyPair = Identity.fetchUserEd25519KeyPair() else {
            return Fail(error: SnodeAPIError.noKeyPair)
                .eraseToAnyPublisher()
        }
        
        let sendTimestamp: UInt64 = UInt64(SnodeAPI.currentOffsetTimestampMs())
        
        // FIXME: There is a bug on SS now that a single-hash lookup is not working. Remove it when the bug is fixed
        let serverHashes: [String] = serverHashes.appending("///////////////////////////////////////////") // Fake hash with valid length
        
        do {
            return try SnodeAPI
                .prepareRequest(
                    request: Request(
                        endpoint: .getExpiries,
                        snode: snode,
                        swarmPublicKey: swarmPublicKey,
                        body: GetExpiriesRequest(
                            messageHashes: serverHashes,
                            pubkey: swarmPublicKey,
                            subkey: nil,
                            timestampMs: sendTimestamp,
                            ed25519PublicKey: userED25519KeyPair.publicKey,
                            ed25519SecretKey: userED25519KeyPair.secretKey
                        )
                    ),
                    responseType: GetExpiriesResponse.self,
                    using: dependencies
                )
                .send(using: dependencies)
        }
        catch { return Fail(error: error).eraseToAnyPublisher() }
    }
    
    // MARK: - Store
    
    public static func sendMessage(
        _ message: SnodeMessage,
        in namespace: Namespace,
        using dependencies: Dependencies
    ) -> AnyPublisher<(ResponseInfoType, SendMessagesResponse), Error> {
        let swarmPublicKey: String = message.recipient
        let userX25519PublicKey: String = getUserHexEncodedPublicKey()
        
        do {
            let request: Network.PreparedRequest<SendMessagesResponse> = try {
                // Check if this namespace requires authentication
                guard namespace.requiresWriteAuthentication else {
                    return try SnodeAPI.prepareRequest(
                        request: Request(
                            endpoint: .sendMessage,
                            swarmPublicKey: swarmPublicKey,
                            body: LegacySendMessagesRequest(
                                message: message,
                                namespace: namespace
                            )
                        ),
                        responseType: SendMessagesResponse.self,
                        using: dependencies
                    )
                }
                
                guard let userED25519KeyPair: KeyPair = Storage.shared.read({ db in Identity.fetchUserEd25519KeyPair(db) }) else {
                    throw SnodeAPIError.noKeyPair
                }
                
                return try SnodeAPI.prepareRequest(
                    request: Request(
                        endpoint: .sendMessage,
                        swarmPublicKey: swarmPublicKey,
                        body: SendMessageRequest(
                            message: message,
                            namespace: namespace,
                            subkey: nil,
                            timestampMs: UInt64(SnodeAPI.currentOffsetTimestampMs()),
                            ed25519PublicKey: userED25519KeyPair.publicKey,
                            ed25519SecretKey: userED25519KeyPair.secretKey
                        )
                    ),
                    responseType: SendMessagesResponse.self,
                    using: dependencies
                )
            }()
            
            return request
                .tryMap { info, response -> SendMessagesResponse in
                    try response.validateResultMap(
                        sodium: sodium.wrappedValue,
                        userX25519PublicKey: userX25519PublicKey
                    )
                    
                    return response
                }
                .send(using: dependencies)
        }
        catch { return Fail(error: error).eraseToAnyPublisher() }
    }
    
    public static func sendConfigMessages(
        _ messages: [(message: SnodeMessage, namespace: Namespace)],
        allObsoleteHashes: [String],
        using dependencies: Dependencies = Dependencies()
    ) -> AnyPublisher<Network.BatchResponse, Error> {
        guard
            !messages.isEmpty,
            let recipient: String = messages.first?.message.recipient
        else {
            return Fail(error: NetworkError.invalidPreparedRequest)
                .eraseToAnyPublisher()
        }
        // TODO: Need to get either the closed group subKey or the userEd25519 key for auth
        guard let userED25519KeyPair = Identity.fetchUserEd25519KeyPair() else {
            return Fail(error: SnodeAPIError.noKeyPair)
                .eraseToAnyPublisher()
        }
        
        do {
            let userX25519PublicKey: String = getUserHexEncodedPublicKey()
            let swarmPublicKey: String = recipient
            var requests: [any ErasedPreparedRequest] = try messages
                .map { message, namespace in
                    // Check if this namespace requires authentication
                    guard namespace.requiresWriteAuthentication else {
                        return try SnodeAPI.prepareRequest(
                            request: Request(
                                endpoint: .sendMessage,
                                swarmPublicKey: swarmPublicKey,
                                body: LegacySendMessagesRequest(
                                    message: message,
                                    namespace: namespace
                                )
                            ),
                            responseType: SendMessagesResponse.self,
                            using: dependencies
                        )
                    }
                    
                    return try SnodeAPI.prepareRequest(
                        request: Request(
                            endpoint: .sendMessage,
                            swarmPublicKey: swarmPublicKey,
                            body: SendMessageRequest(
                                message: message,
                                namespace: namespace,
                                subkey: nil,    // TODO: Need to get this
                                timestampMs: UInt64(SnodeAPI.currentOffsetTimestampMs()),
                                ed25519PublicKey: userED25519KeyPair.publicKey,
                                ed25519SecretKey: userED25519KeyPair.secretKey
                            )
                        ),
                        responseType: SendMessagesResponse.self,
                        using: dependencies
                    )
                }
            
            // If we had any previous config messages then we should delete them
            if !allObsoleteHashes.isEmpty {
                requests.append(
                    try SnodeAPI.prepareRequest(
                        request: Request(
                            endpoint: .deleteMessages,
                            swarmPublicKey: swarmPublicKey,
                            body: DeleteMessagesRequest(
                                messageHashes: allObsoleteHashes,
                                requireSuccessfulDeletion: false,
                                pubkey: userX25519PublicKey,
                                ed25519PublicKey: userED25519KeyPair.publicKey,
                                ed25519SecretKey: userED25519KeyPair.secretKey
                            )
                        ),
                        responseType: DeleteMessagesResponse.self,
                        using: dependencies
                    )
                )
            }
            
            return try SnodeAPI
                .prepareRequest(
                    request: Request(
                        endpoint: .sequence,
                        swarmPublicKey: swarmPublicKey,
                        body: Network.BatchRequest(requestsKey: .requests, requests: requests)
                    ),
                    responseType: Network.BatchResponse.self,
                    requireAllBatchResponses: false,
                    using: dependencies
                )
                .send(using: dependencies)
                .map { _, response in response }
                .eraseToAnyPublisher()
        }
        catch { return Fail(error: error).eraseToAnyPublisher() }
    }
    
    // MARK: - Edit
    
    public static func updateExpiry(
        swarmPublicKey: String,
        serverHashes: [String],
        updatedExpiryMs: Int64,
        shortenOnly: Bool? = nil,
        extendOnly: Bool? = nil,
        using dependencies: Dependencies = Dependencies()
    ) -> AnyPublisher<[String: UpdateExpiryResponseResult], Error> {
        guard let userED25519KeyPair = Identity.fetchUserEd25519KeyPair() else {
            return Fail(error: SnodeAPIError.noKeyPair)
                .eraseToAnyPublisher()
        }
        
        // ShortenOnly and extendOnly cannot be true at the same time
        guard shortenOnly == nil || extendOnly == nil else {
            return Fail(error: NetworkError.invalidPreparedRequest)
                .eraseToAnyPublisher()
        }
        
        // FIXME: There is a bug on SS now that a single-hash lookup is not working. Remove it when the bug is fixed
        let serverHashes: [String] = serverHashes.appending("///////////////////////////////////////////") // Fake hash with valid length
        
        do {
            return try SnodeAPI
                .prepareRequest(
                    request: Request(
                        endpoint: .expire,
                        swarmPublicKey: swarmPublicKey,
                        body: UpdateExpiryRequest(
                            messageHashes: serverHashes,
                            expiryMs: UInt64(updatedExpiryMs),
                            shorten: shortenOnly,
                            extend: extendOnly,
                            pubkey: swarmPublicKey,
                            ed25519PublicKey: userED25519KeyPair.publicKey,
                            ed25519SecretKey: userED25519KeyPair.secretKey,
                            subkey: nil
                        )
                    ),
                    responseType: UpdateExpiryResponse.self,
                    using: dependencies
                )
                .send(using: dependencies)
                .tryMap { _, response -> [String: UpdateExpiryResponseResult] in
                    try response.validResultMap(
                        sodium: sodium.wrappedValue,
                        userX25519PublicKey: getUserHexEncodedPublicKey(),
                        validationData: serverHashes
                    )
                }
                .eraseToAnyPublisher()
        }
        catch { return Fail(error: error).eraseToAnyPublisher() }
    }
    
    public static func revokeSubkey(
        swarmPublicKey: String,
        subkeyToRevoke: String,
        using dependencies: Dependencies = Dependencies()
    ) -> AnyPublisher<Void, Error> {
        guard let userED25519KeyPair = Identity.fetchUserEd25519KeyPair() else {
            return Fail(error: SnodeAPIError.noKeyPair)
                .eraseToAnyPublisher()
        }
        
        do {
            return try SnodeAPI
                .prepareRequest(
                    request: Request(
                        endpoint: .revokeSubaccount,
                        swarmPublicKey: swarmPublicKey,
                        body: RevokeSubkeyRequest(
                            subkeyToRevoke: subkeyToRevoke,
                            pubkey: swarmPublicKey,
                            ed25519PublicKey: userED25519KeyPair.publicKey,
                            ed25519SecretKey: userED25519KeyPair.secretKey
                        )
                    ),
                    responseType: RevokeSubkeyResponse.self,
                    using: dependencies
                )
                .send(using: dependencies)
                .tryMap { _, response -> Void in
                    try response.validateResultMap(
                        sodium: sodium.wrappedValue,
                        userX25519PublicKey: getUserHexEncodedPublicKey(),
                        validationData: subkeyToRevoke
                    )
                    
                    return ()
                }
                .eraseToAnyPublisher()
        }
        catch { return Fail(error: error).eraseToAnyPublisher() }
    }
    
    // MARK: Delete
    
    public static func deleteMessages(
        swarmPublicKey: String,
        serverHashes: [String],
        using dependencies: Dependencies = Dependencies()
    ) -> AnyPublisher<[String: Bool], Error> {
        guard let userED25519KeyPair = Identity.fetchUserEd25519KeyPair() else {
            return Fail(error: SnodeAPIError.noKeyPair)
                .eraseToAnyPublisher()
        }
        
        let userX25519PublicKey: String = getUserHexEncodedPublicKey(using: dependencies)
        
        do {
            return try SnodeAPI
                .prepareRequest(
                    request: Request(
                        endpoint: .deleteMessages,
                        swarmPublicKey: swarmPublicKey,
                        body: DeleteMessagesRequest(
                            messageHashes: serverHashes,
                            requireSuccessfulDeletion: false,
                            pubkey: userX25519PublicKey,
                            ed25519PublicKey: userED25519KeyPair.publicKey,
                            ed25519SecretKey: userED25519KeyPair.secretKey
                        )
                    ),
                    responseType: DeleteMessagesResponse.self,
                    using: dependencies
                )
                .send(using: dependencies)
                .tryMap { _, response -> [String: Bool] in
                    let validResultMap: [String: Bool] = try response.validResultMap(
                        sodium: sodium.wrappedValue,
                        userX25519PublicKey: userX25519PublicKey,
                        validationData: serverHashes
                    )
                    
                    // If `validResultMap` didn't throw then at least one service node
                    // deleted successfully so we should mark the hash as invalid so we
                    // don't try to fetch updates using that hash going forward (if we
                    // do we would end up re-fetching all old messages)
                    Storage.shared.writeAsync { db in
                        try? SnodeReceivedMessageInfo.handlePotentialDeletedOrInvalidHash(
                            db,
                            potentiallyInvalidHashes: serverHashes
                        )
                    }
                    
                    return validResultMap
                }
                .eraseToAnyPublisher()
        }
        catch { return Fail(error: error).eraseToAnyPublisher() }
    }
    
    /// Clears all the user's data from their swarm. Returns a dictionary of snode public key to deletion confirmation.
    public static func deleteAllMessages(
        namespace: SnodeAPI.Namespace,
        using dependencies: Dependencies = Dependencies()
    ) -> AnyPublisher<[String: Bool], Error> {
        guard let userED25519KeyPair = Identity.fetchUserEd25519KeyPair() else {
            return Fail(error: SnodeAPIError.noKeyPair)
                .eraseToAnyPublisher()
        }
        
        let userX25519PublicKey: String = getUserHexEncodedPublicKey()
        
        do {
            return try SnodeAPI
                .prepareRequest(
                    request: Request(
                        endpoint: .deleteAll,
                        swarmPublicKey: userX25519PublicKey,
                        requiresLatestNetworkTime: true,
                        body: DeleteAllMessagesRequest(
                            namespace: namespace,
                            pubkey: userX25519PublicKey,
                            timestampMs: UInt64(SnodeAPI.currentOffsetTimestampMs()),
                            ed25519PublicKey: userED25519KeyPair.publicKey,
                            ed25519SecretKey: userED25519KeyPair.secretKey
                        )
                    ),
                    responseType: DeleteAllMessagesResponse.self,
                    using: dependencies
                )
                .send(using: dependencies)
                .tryMap { info, response -> [String: Bool] in
                    guard let targetInfo: LatestTimestampResponseInfo = info as? LatestTimestampResponseInfo else {
                        throw NetworkError.invalidResponse
                    }
                    
                    return try response.validResultMap(
                        sodium: sodium.wrappedValue,
                        userX25519PublicKey: userX25519PublicKey,
                        validationData: targetInfo.timestampMs
                    )
                }
                .eraseToAnyPublisher()
        }
        catch { return Fail(error: error).eraseToAnyPublisher() }
    }
    
    /// Clears all the user's data from their swarm. Returns a dictionary of snode public key to deletion confirmation.
    public static func deleteAllMessages(
        beforeMs: UInt64,
        namespace: SnodeAPI.Namespace,
        using dependencies: Dependencies = Dependencies()
    ) -> AnyPublisher<[String: Bool], Error> {
        guard let userED25519KeyPair = Identity.fetchUserEd25519KeyPair() else {
            return Fail(error: SnodeAPIError.noKeyPair)
                .eraseToAnyPublisher()
        }
        
        let userX25519PublicKey: String = getUserHexEncodedPublicKey()
        
        do {
            return try SnodeAPI
                .prepareRequest(
                    request: Request(
                        endpoint: .deleteAllBefore,
                        swarmPublicKey: userX25519PublicKey,
                        requiresLatestNetworkTime: true,
                        body: DeleteAllBeforeRequest(
                            beforeMs: beforeMs,
                            namespace: namespace,
                            pubkey: userX25519PublicKey,
                            timestampMs: UInt64(SnodeAPI.currentOffsetTimestampMs()),
                            ed25519PublicKey: userED25519KeyPair.publicKey,
                            ed25519SecretKey: userED25519KeyPair.secretKey
                        )
                    ),
                    responseType: DeleteAllBeforeResponse.self,
                    using: dependencies
                )
                .send(using: dependencies)
                .tryMap { _, response -> [String: Bool] in
                    try response.validResultMap(
                        sodium: sodium.wrappedValue,
                        userX25519PublicKey: userX25519PublicKey,
                        validationData: beforeMs
                    )
                }
                .eraseToAnyPublisher()
        }
        catch { return Fail(error: error).eraseToAnyPublisher() }
    }
    
    // MARK: - Internal API
    
    public static func getNetworkTime(
        from snode: Snode,
        using dependencies: Dependencies
    ) -> AnyPublisher<UInt64, Error> {
        do {
            return try SnodeAPI
                .prepareRequest(
                    request: Request(
                        endpoint: .getInfo,
                        snode: snode,
                        body: [String: String]()
                    ),
                    responseType: GetNetworkTimestampResponse.self,
                    using: dependencies
                )
                .send(using: dependencies)
                .map { _, response in
                    // Assume we've fetched the networkTime in order to send a message to the specified snode, in
                    // which case we want to update the 'clockOffsetMs' value for subsequent requests
                    let offset = (Int64(response.timestamp) - Int64(floor(dependencies.dateNow.timeIntervalSince1970 * 1000)))
                    SnodeAPI.clockOffsetMs.mutate { $0 = offset }
                    
                    return response.timestamp
                }
                .eraseToAnyPublisher()
        }
        catch { return Fail(error: error).eraseToAnyPublisher() }
    }
    
    internal static func getRandomSnode() -> AnyPublisher<Snode, Error> {
        // randomElement() uses the system's default random generator, which is cryptographically secure
        return getSnodePool()
            .map { $0.randomElement()! }
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
                        do {
                            return try SnodeAPI
                                .prepareRequest(
                                    request: Request(
                                        endpoint: .oxenDaemonRPCCall,
                                        snode: snode,
                                        body: OxenDaemonRPCRequest(
                                            endpoint: .daemonGetServiceNodes,
                                            body: GetServiceNodesRequest(
                                                activeOnly: true,
                                                limit: nil,
                                                fields: GetServiceNodesRequest.Fields(
                                                    publicIp: true,
                                                    pubkeyEd25519: true,
                                                    pubkeyX25519: true,
                                                    storageLmqPort: true
                                                )
                                            )
                                        )
                                    ),
                                    responseType: SnodePoolResponse.self,
                                    using: dependencies
                                )
                                .send(using: dependencies)
                                .map { _, snodePool -> Set<Snode> in
                                    snodePool.result
                                        .serviceNodeStates
                                        .compactMap { $0.value }
                                        .asSet()
                                }
                                .retry(4)
                                .eraseToAnyPublisher()
                        }
                        catch { return Fail(error: error).eraseToAnyPublisher() }
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
    
    // MARK: - Direct Requests
    
    private static func getSnodePoolFromSeedNode(
        ed25519SecretKey: [UInt8]?,
        using dependencies: Dependencies
    ) -> AnyPublisher<Set<Snode>, Error> {
        guard let targetSeedNode: Snode = seedNodePool.randomElement() else {
            return Fail(error: SnodeAPIError.snodePoolUpdatingFailed)
                .eraseToAnyPublisher()
        }
        
        SNLog("Populating snode pool using seed node: \(targetSeedNode).")

        return LibSession
            .sendDirectRequest(
                endpoint: SnodeAPI.Endpoint.oxenDaemonRPCCall,
                body: OxenDaemonRPCRequest(
                    endpoint: .daemonGetServiceNodes,
                    body: GetServiceNodesRequest(
                        activeOnly: true,
                        limit: 256,
                        fields: GetServiceNodesRequest.Fields(
                            publicIp: true,
                            pubkeyEd25519: true,
                            pubkeyX25519: true,
                            storageLmqPort: true
                        )
                    )
                ),
                snode: targetSeedNode,
                swarmPublicKey: nil,
                ed25519SecretKey: ed25519SecretKey,
                using: dependencies
            )
            .decoded(as: SnodePoolResponse.self, using: dependencies)
            .map { _, snodePool -> Set<Snode> in
                snodePool.result
                    .serviceNodeStates
                    .compactMap { $0.value }
                    .asSet()
            }
            .retry(2)
            .handleEvents(
                receiveCompletion: { result in
                    switch result {
                        case .finished: SNLog("Got snode pool from seed node: \(targetSeedNode).")
                        case .failure: SNLog("Failed to contact seed node at: \(targetSeedNode).")
                    }
                }
            )
            .eraseToAnyPublisher()
    }
    
    /// Tests the given snode. The returned promise errors out if the snode is faulty; the promise is fulfilled otherwise.
    internal static func testSnode(
        snode: Snode,
        ed25519SecretKey: [UInt8]?,
        using dependencies: Dependencies
    ) -> AnyPublisher<Void, Error> {
        return LibSession
            .sendDirectRequest(
                endpoint: SnodeAPI.Endpoint.getInfo,
                body: NoBody.null,
                snode: snode,
                swarmPublicKey: nil,
                ed25519SecretKey: (ed25519SecretKey ?? Identity.fetchUserEd25519KeyPair()?.secretKey),
                using: dependencies
            )
            .decoded(as: SnodeAPI.GetInfoResponse.self, using: dependencies)
            .tryMap { _, response -> Void in
                guard let version: SessionUtilitiesKit.Version = response.version else { throw SnodeAPIError.missingSnodeVersion }
                guard version >= Version(major: 2, minor: 0, patch: 7) else {
                    SNLog("Unsupported snode version: \(version.stringValue).")
                    throw SnodeAPIError.unsupportedSnodeVersion(version.stringValue)
                }
                
                return ()
            }
            .eraseToAnyPublisher()
    }

    // MARK: - Convenience
    
    private static func prepareRequest<T: Encodable, R: Decodable>(
        request: Request<T, Endpoint>,
        responseType: R.Type,
        requireAllBatchResponses: Bool = true,
        retryCount: Int = 0,
        timeout: TimeInterval = Network.defaultTimeout,
        using dependencies: Dependencies
    ) throws -> Network.PreparedRequest<R> {
        return Network.PreparedRequest<R>(
            request: request,
            urlRequest: try request.generateUrlRequest(using: dependencies),
            responseType: responseType,
            requireAllBatchResponses: requireAllBatchResponses,
            retryCount: retryCount,
            timeout: timeout
        )
        .handleEvents(
            receiveOutput: { _, response in
                switch response {
                    // Extract and store hard fork information if returned
                    case let snodeResponse as SnodeResponse:
                        guard snodeResponse.hardFork.count > 1 else { break }
                        
                        if snodeResponse.hardFork[1] > softfork {
                            softfork = snodeResponse.hardFork[1]
                            UserDefaults.standard[.softfork] = softfork
                        }
                        
                        if snodeResponse.hardFork[0] > hardfork {
                            hardfork = snodeResponse.hardFork[0]
                            UserDefaults.standard[.hardfork] = hardfork
                            softfork = snodeResponse.hardFork[1]
                            UserDefaults.standard[.softfork] = softfork
                        }
                        
                    default: break
                }
            }
        )
    }
}

// MARK: - Publisher Convenience

public extension Publisher where Output == Set<Snode> {
    func tryFlatMapWithRandomSnode<T, P>(
        maxPublishers: Subscribers.Demand = .unlimited,
        retry retries: Int = 0,
        drainBehaviour: Atomic<SwarmDrainBehaviour> = .alwaysRandom,
        using dependencies: Dependencies,
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
                        case .limitedReuse(_, let targetSnode, _, let usedSnodes, let swarmHash):
                            // If we've used all of the snodes or the swarm has changed then reset the used list
                            guard swarmHash == swarm.hashValue && (targetSnode != nil || usedSnodes != swarm) else {
                                drainBehaviour.mutate { $0 = $0.reset() }
                                return swarm
                            }
                            
                            return swarm.subtracting(usedSnodes)
                    }
                }()
                var lastError: Error?
                
                return Just(())
                    .setFailureType(to: Error.self)
                    .tryFlatMap(maxPublishers: maxPublishers) { _ -> AnyPublisher<T, Error> in
                        let snode: Snode = try {
                            switch drainBehaviour.wrappedValue {
                                case .limitedReuse(_, .some(let targetSnode), _, _, _): return targetSnode
                                default: break
                            }
                            
                            // Select the next snode
                            return try dependencies.popRandomElement(&remainingSnodes) ?? {
                                throw SnodeAPIError.ranOutOfRandomSnodes(lastError)
                            }()
                        }()
                        drainBehaviour.mutate { $0 = $0.use(snode: snode, from: swarm) }
                        
                        return try transform(snode)
                            .eraseToAnyPublisher()
                    }
                    .mapError { error in
                        // Prevent nesting the 'ranOutOfRandomSnodes' errors
                        switch error {
                            case SnodeAPIError.ranOutOfRandomSnodes: break
                            default: lastError = error
                        }
                        
                        return error
                    }
                    .retry(retries)
                    .eraseToAnyPublisher()
            }
            .eraseToAnyPublisher()
    }
}

// MARK: - Request<T, EndpointType> Convenience

private extension Request {
    init<B: Encodable>(
        endpoint: SnodeAPI.Endpoint,
        swarmPublicKey: String,
        body: B
    ) where T == SnodeRequest<B>, Endpoint == SnodeAPI.Endpoint {
        self = Request(
            method: .post,
            endpoint: endpoint,
            swarmPublicKey: swarmPublicKey,
            body: SnodeRequest<B>(
                endpoint: endpoint,
                body: body
            )
        )
    }
    
    init<B: Encodable>(
        endpoint: SnodeAPI.Endpoint,
        snode: Snode,
        swarmPublicKey: String? = nil,
        body: B
    ) where T == SnodeRequest<B>, Endpoint == SnodeAPI.Endpoint {
        self = Request(
            method: .post,
            endpoint: endpoint,
            snode: snode,
            body: SnodeRequest<B>(
                endpoint: endpoint,
                body: body
            ),
            swarmPublicKey: swarmPublicKey
        )
    }
    
    init<B>(
        endpoint: SnodeAPI.Endpoint,
        swarmPublicKey: String,
        requiresLatestNetworkTime: Bool,
        body: B
    ) where T == SnodeRequest<B>, Endpoint == SnodeAPI.Endpoint, B: Encodable & UpdatableTimestamp {
        self = Request(
            method: .post,
            endpoint: endpoint,
            swarmPublicKey: swarmPublicKey,
            requiresLatestNetworkTime: requiresLatestNetworkTime,
            body: SnodeRequest<B>(
                endpoint: endpoint,
                body: body
            )
        )
    }
}
