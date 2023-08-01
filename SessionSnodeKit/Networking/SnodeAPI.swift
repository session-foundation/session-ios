// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import Sodium
import GRDB
import SessionUtilitiesKit

public extension Network.RequestType {
    static func message(
        _ message: SnodeMessage,
        in namespace: SnodeAPI.Namespace,
        using dependencies: Dependencies = Dependencies()
    ) -> Network.RequestType<SendMessagesResponse> {
        return Network.RequestType(id: "snodeAPI.sendMessage", args: [message, namespace]) {
            SnodeAPI.sendMessage(message, in: namespace, using: dependencies)
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
    
    private static let maxRetryCount: Int = 8
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
    
    private static func loadSwarmIfNeeded(for publicKey: String) {
        guard !loadedSwarms.wrappedValue.contains(publicKey) else { return }
        
        let updatedCacheForKey: Set<Snode> = Storage.shared
           .read { db in try Snode.fetchSet(db, publicKey: publicKey) }
           .defaulting(to: [])
        
        swarmCache.mutate { $0[publicKey] = updatedCacheForKey }
        loadedSwarms.mutate { $0.insert(publicKey) }
    }
    
    private static func setSwarm(to newValue: Set<Snode>, for publicKey: String, persist: Bool = true) {
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

    // MARK: - Public API
    
    public static func hasCachedSnodesInclusingExpired() -> Bool {
        loadSnodePoolIfNeeded()
        
        return !hasInsufficientSnodes
    }
    
    public static func getSnodePool(
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
                            .getRandomSnode()
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
                                                sodium: sodium.wrappedValue,
                                                nameBytes: nameAsData,
                                                nameHashBytes: nameHash
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
    
    public static func getSwarm(
        for publicKey: String,
        using dependencies: Dependencies = Dependencies()
    ) -> AnyPublisher<Set<Snode>, Error> {
        loadSwarmIfNeeded(for: publicKey)
        
        if let cachedSwarm = swarmCache.wrappedValue[publicKey], cachedSwarm.count >= minSwarmSnodeCount {
            return Just(cachedSwarm)
                .setFailureType(to: Error.self)
                .eraseToAnyPublisher()
        }
        
        SNLog("Getting swarm for: \((publicKey == getUserHexEncodedPublicKey()) ? "self" : publicKey).")
        
        return getRandomSnode()
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
            .map { _, responseData in parseSnodes(from: responseData) }
            .handleEvents(
                receiveOutput: { swarm in setSwarm(to: swarm, for: publicKey) }
            )
            .eraseToAnyPublisher()
    }

    // MARK: - Retrieve
    
    public static func poll(
        namespaces: [SnodeAPI.Namespace],
        refreshingConfigHashes: [String] = [],
        from snode: Snode,
        associatedWith publicKey: String,
        using dependencies: Dependencies = Dependencies()
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
                            associatedWith: publicKey,
                            using: dependencies
                        )
                        
                        result[namespace] = SnodeReceivedMessageInfo
                            .fetchLastNotExpired(
                                for: snode,
                                namespace: namespace,
                                associatedWith: publicKey,
                                using: dependencies
                            )?
                            .hash
                    }
            }
            .flatMap { namespaceLastHash -> AnyPublisher<[SnodeAPI.Namespace: (info: ResponseInfoType, data: (messages: [SnodeReceivedMessage], lastHash: String?)?)], Error> in
                var requests: [SnodeAPI.BatchRequest.Info] = []

                // If we have any config hashes to refresh TTLs then add those requests first
                if !refreshingConfigHashes.isEmpty {
                    requests.append(
                        BatchRequest.Info(
                            request: SnodeRequest(
                                endpoint: .expire,
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
                            responseType: UpdateExpiryResponse.self
                        )
                    )
                }
                
                // Determine the maxSize each namespace in the request should take up
                let namespaceMaxSizeMap: [SnodeAPI.Namespace: Int64] = SnodeAPI.Namespace.maxSizeMap(for: namespaces)
                let fallbackSize: Int64 = (namespaceMaxSizeMap.values.min() ?? 1)

                // Add the various 'getMessages' requests
                requests.append(
                    contentsOf: namespaces.map { namespace -> SnodeAPI.BatchRequest.Info in
                        // Check if this namespace requires authentication
                        guard namespace.requiresReadAuthentication else {
                            return BatchRequest.Info(
                                request: SnodeRequest(
                                    endpoint: .getMessages,
                                    body: LegacyGetMessagesRequest(
                                        pubkey: publicKey,
                                        lastHash: (namespaceLastHash[namespace] ?? ""),
                                        namespace: namespace,
                                        maxCount: nil,
                                        maxSize: namespaceMaxSizeMap[namespace]
                                            .defaulting(to: fallbackSize)
                                    )
                                ),
                                responseType: GetMessagesResponse.self
                            )
                        }

                        return BatchRequest.Info(
                            request: SnodeRequest(
                                endpoint: .getMessages,
                                body: GetMessagesRequest(
                                    lastHash: (namespaceLastHash[namespace] ?? ""),
                                    namespace: namespace,
                                    pubkey: publicKey,
                                    subkey: nil,    // TODO: Need to get this
                                    timestampMs: UInt64(SnodeAPI.currentOffsetTimestampMs()),
                                    ed25519PublicKey: userED25519KeyPair.publicKey,
                                    ed25519SecretKey: userED25519KeyPair.secretKey,
                                    maxSize: namespaceMaxSizeMap[namespace]
                                        .defaulting(to: fallbackSize)
                                )
                            ),
                            responseType: GetMessagesResponse.self
                        )
                    }
                )

                // Actually send the request
                let responseTypes = requests.map { $0.responseType }

                return SnodeAPI
                    .send(
                        request: SnodeRequest(
                            endpoint: .batch,
                            body: BatchRequest(requests: requests)
                        ),
                        to: snode,
                        associatedWith: publicKey,
                        using: dependencies
                    )
                    .decoded(as: responseTypes, using: dependencies)
                    .map { (batchResponse: HTTP.BatchResponse) -> [SnodeAPI.Namespace: (info: ResponseInfoType, data: (messages: [SnodeReceivedMessage], lastHash: String?)?)] in
                        let messageResponses: [HTTP.BatchSubResponse<GetMessagesResponse>] = batchResponse.responses
                            .compactMap { $0 as? HTTP.BatchSubResponse<GetMessagesResponse> }
                        
                        /// Since we have extended the TTL for a number of messages we need to make sure we update the local
                        /// `SnodeReceivedMessageInfo.expirationDateMs` values so we don't end up deleting them
                        /// incorrectly before they actually expire on the swarm
                        if
                            !refreshingConfigHashes.isEmpty,
                            let refreshTTLSubReponse: HTTP.BatchSubResponse<UpdateExpiryResponse> = batchResponse
                                .responses
                                .first(where: { $0 is HTTP.BatchSubResponse<UpdateExpiryResponse> })
                                .asType(HTTP.BatchSubResponse<UpdateExpiryResponse>.self),
                            let refreshTTLResponse: UpdateExpiryResponse = refreshTTLSubReponse.body,
                            let validResults: [String: [(hash: String, expiry: UInt64)]] = try? refreshTTLResponse.validResultMap(
                                sodium: sodium.wrappedValue,
                                userX25519PublicKey: getUserHexEncodedPublicKey(),
                                validationData: refreshingConfigHashes
                            ),
                            let groupedExpiryResult: [UInt64: [String]] = validResults[snode.ed25519PublicKey]?
                                .grouped(by: \.expiry)
                                .mapValues({ groupedResults in groupedResults.map { $0.hash } })
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
                                    info: next.1.responseInfo,
                                    data: (
                                        messages: messageResponse.messages
                                            .compactMap { rawMessage -> SnodeReceivedMessage? in
                                                SnodeReceivedMessage(
                                                    snode: snode,
                                                    publicKey: publicKey,
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
        associatedWith publicKey: String,
        using dependencies: Dependencies = Dependencies()
    ) -> AnyPublisher<(info: ResponseInfoType, data: (messages: [SnodeReceivedMessage], lastHash: String?)?), Error> {
        return Deferred {
            Future<String?, Error> { resolver in
                // Prune expired message hashes for this namespace on this service node
                SnodeReceivedMessageInfo.pruneExpiredMessageHashInfo(
                    for: snode,
                    namespace: namespace,
                    associatedWith: publicKey,
                    using: dependencies
                )
                
                let maybeLastHash: String? = SnodeReceivedMessageInfo
                    .fetchLastNotExpired(
                        for: snode,
                        namespace: namespace,
                        associatedWith: publicKey,
                        using: dependencies
                    )?
                    .hash
                
                resolver(Result.success(maybeLastHash))
            }
        }
        .tryFlatMap { lastHash -> AnyPublisher<(info: ResponseInfoType, data: GetMessagesResponse?, lastHash: String?), Error> in
            
            guard namespace.requiresReadAuthentication else {
                return SnodeAPI
                    .send(
                        request: SnodeRequest(
                            endpoint: .getMessages,
                            body: LegacyGetMessagesRequest(
                                pubkey: publicKey,
                                lastHash: (lastHash ?? ""),
                                namespace: namespace,
                                maxCount: nil,
                                maxSize: nil
                            )
                        ),
                        to: snode,
                        associatedWith: publicKey,
                        using: dependencies
                    )
                    .decoded(as: GetMessagesResponse.self, using: dependencies)
                    .map { info, data in (info, data, lastHash) }
                    .eraseToAnyPublisher()
            }
            
            guard let userED25519KeyPair: KeyPair = Storage.shared.read({ db in Identity.fetchUserEd25519KeyPair(db) }) else {
                throw SnodeAPIError.noKeyPair
            }
            
            return SnodeAPI
                .send(
                    request: SnodeRequest(
                        endpoint: .getMessages,
                        body: GetMessagesRequest(
                            lastHash: (lastHash ?? ""),
                            namespace: namespace,
                            pubkey: publicKey,
                            subkey: nil,
                            timestampMs: UInt64(SnodeAPI.currentOffsetTimestampMs()),
                            ed25519PublicKey: userED25519KeyPair.publicKey,
                            ed25519SecretKey: userED25519KeyPair.secretKey
                        )
                    ),
                    to: snode,
                    associatedWith: publicKey,
                    using: dependencies
                )
                .decoded(as: GetMessagesResponse.self, using: dependencies)
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
                                    publicKey: publicKey,
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
    
    // MARK: - Store
    
    public static func sendMessage(
        _ message: SnodeMessage,
        in namespace: Namespace,
        using dependencies: Dependencies
    ) -> AnyPublisher<(ResponseInfoType, SendMessagesResponse), Error> {
        let publicKey: String = message.recipient
        let userX25519PublicKey: String = getUserHexEncodedPublicKey()
        let sendTimestamp: UInt64 = UInt64(SnodeAPI.currentOffsetTimestampMs())
        
        // Create a convenience method to send a message to an individual Snode
        func sendMessage(to snode: Snode) throws -> AnyPublisher<(any ResponseInfoType, SendMessagesResponse), Error> {
            guard namespace.requiresWriteAuthentication else {
                return SnodeAPI
                    .send(
                        request: SnodeRequest(
                            endpoint: .sendMessage,
                            body: LegacySendMessagesRequest(
                                message: message,
                                namespace: namespace
                            )
                        ),
                        to: snode,
                        associatedWith: publicKey,
                        using: dependencies
                    )
                    .decoded(as: SendMessagesResponse.self, using: dependencies)
                    .eraseToAnyPublisher()
            }
                    
            guard let userED25519KeyPair: KeyPair = Storage.shared.read({ db in Identity.fetchUserEd25519KeyPair(db) }) else {
                throw SnodeAPIError.noKeyPair
            }
            
            return SnodeAPI
                .send(
                    request: SnodeRequest(
                        endpoint: .sendMessage,
                        body: SendMessageRequest(
                            message: message,
                            namespace: namespace,
                            subkey: nil,
                            timestampMs: sendTimestamp,
                            ed25519PublicKey: userED25519KeyPair.publicKey,
                            ed25519SecretKey: userED25519KeyPair.secretKey
                        )
                    ),
                    to: snode,
                    associatedWith: publicKey,
                    using: dependencies
                )
                .decoded(as: SendMessagesResponse.self, using: dependencies)
                .eraseToAnyPublisher()
        }
        
        return getSwarm(for: publicKey)
            .tryFlatMapWithRandomSnode(retry: maxRetryCount) { snode -> AnyPublisher<(ResponseInfoType, SendMessagesResponse), Error> in
                try sendMessage(to: snode)
                    .tryMap { info, response -> (ResponseInfoType, SendMessagesResponse) in
                        try response.validateResultMap(
                            sodium: sodium.wrappedValue,
                            userX25519PublicKey: userX25519PublicKey
                        )
                        
                        return (info, response)
                    }
                    .eraseToAnyPublisher()
            }
    }
    
    public static func sendConfigMessages(
        _ messages: [(message: SnodeMessage, namespace: Namespace)],
        allObsoleteHashes: [String],
        using dependencies: Dependencies = Dependencies()
    ) -> AnyPublisher<HTTP.BatchResponse, Error> {
        guard
            !messages.isEmpty,
            let recipient: String = messages.first?.message.recipient
        else {
            return Fail(error: SnodeAPIError.generic)
                .eraseToAnyPublisher()
        }
        // TODO: Need to get either the closed group subKey or the userEd25519 key for auth
        guard let userED25519KeyPair = Identity.fetchUserEd25519KeyPair() else {
            return Fail(error: SnodeAPIError.noKeyPair)
                .eraseToAnyPublisher()
        }
        
        let userX25519PublicKey: String = getUserHexEncodedPublicKey()
        let publicKey: String = recipient
        var requests: [SnodeAPI.BatchRequest.Info] = messages
            .map { message, namespace in
                // Check if this namespace requires authentication
                guard namespace.requiresWriteAuthentication else {
                    return BatchRequest.Info(
                        request: SnodeRequest(
                            endpoint: .sendMessage,
                            body: LegacySendMessagesRequest(
                                message: message,
                                namespace: namespace
                            )
                        ),
                        responseType: SendMessagesResponse.self
                    )
                }
                
                return BatchRequest.Info(
                    request: SnodeRequest(
                        endpoint: .sendMessage,
                        body: SendMessageRequest(
                            message: message,
                            namespace: namespace,
                            subkey: nil,    // TODO: Need to get this
                            timestampMs: UInt64(SnodeAPI.currentOffsetTimestampMs()),
                            ed25519PublicKey: userED25519KeyPair.publicKey,
                            ed25519SecretKey: userED25519KeyPair.secretKey
                        )
                    ),
                    responseType: SendMessagesResponse.self
                )
            }
        
        // If we had any previous config messages then we should delete them
        if !allObsoleteHashes.isEmpty {
            requests.append(
                BatchRequest.Info(
                    request: SnodeRequest(
                        endpoint: .deleteMessages,
                        body: DeleteMessagesRequest(
                            messageHashes: allObsoleteHashes,
                            requireSuccessfulDeletion: false,
                            pubkey: userX25519PublicKey,
                            ed25519PublicKey: userED25519KeyPair.publicKey,
                            ed25519SecretKey: userED25519KeyPair.secretKey
                        )
                    ),
                    responseType: DeleteMessagesResponse.self
                )
            )
        }
        
        let responseTypes = requests.map { $0.responseType }
        
        return getSwarm(for: publicKey)
            .tryFlatMapWithRandomSnode(retry: maxRetryCount) { snode -> AnyPublisher<HTTP.BatchResponse, Error> in
                SnodeAPI
                    .send(
                        request: SnodeRequest(
                            endpoint: .sequence,
                            body: BatchRequest(requests: requests)
                        ),
                        to: snode,
                        associatedWith: publicKey,
                        using: dependencies
                    )
                    .eraseToAnyPublisher()
                    .decoded(as: responseTypes, requireAllResults: false, using: dependencies)
                    .eraseToAnyPublisher()
            }
    }
    
    // MARK: - Edit
    
    public static func updateExpiry(
        publicKey: String,
        serverHashes: [String],
        updatedExpiryMs: UInt64,
        using dependencies: Dependencies = Dependencies()
    ) -> AnyPublisher<[String: [(hash: String, expiry: UInt64)]], Error> {
        guard let userED25519KeyPair = Identity.fetchUserEd25519KeyPair() else {
            return Fail(error: SnodeAPIError.noKeyPair)
                .eraseToAnyPublisher()
        }
        
        return getSwarm(for: publicKey)
            .tryFlatMapWithRandomSnode(retry: maxRetryCount) { snode -> AnyPublisher<[String: [(hash: String, expiry: UInt64)]], Error> in
                SnodeAPI
                    .send(
                        request: SnodeRequest(
                            endpoint: .expire,
                            body: UpdateExpiryRequest(
                                messageHashes: serverHashes,
                                expiryMs: updatedExpiryMs,
                                pubkey: publicKey,
                                ed25519PublicKey: userED25519KeyPair.publicKey,
                                ed25519SecretKey: userED25519KeyPair.secretKey,
                                subkey: nil
                            )
                        ),
                        to: snode,
                        associatedWith: publicKey,
                        using: dependencies
                    )
                    .decoded(as: UpdateExpiryResponse.self, using: dependencies)
                    .tryMap { _, response -> [String: [(hash: String, expiry: UInt64)]] in
                        try response.validResultMap(
                            sodium: sodium.wrappedValue,
                            userX25519PublicKey: getUserHexEncodedPublicKey(),
                            validationData: serverHashes
                        )
                    }
                    .eraseToAnyPublisher()
            }
    }
    
    public static func revokeSubkey(
        publicKey: String,
        subkeyToRevoke: String,
        using dependencies: Dependencies = Dependencies()
    ) -> AnyPublisher<Void, Error> {
        guard let userED25519KeyPair = Identity.fetchUserEd25519KeyPair() else {
            return Fail(error: SnodeAPIError.noKeyPair)
                .eraseToAnyPublisher()
        }
        
        return getSwarm(for: publicKey)
            .tryFlatMapWithRandomSnode(retry: maxRetryCount) { snode -> AnyPublisher<Void, Error> in
                SnodeAPI
                    .send(
                        request: SnodeRequest(
                            endpoint: .revokeSubkey,
                            body: RevokeSubkeyRequest(
                                subkeyToRevoke: subkeyToRevoke,
                                pubkey: publicKey,
                                ed25519PublicKey: userED25519KeyPair.publicKey,
                                ed25519SecretKey: userED25519KeyPair.secretKey
                            )
                        ),
                        to: snode,
                        associatedWith: publicKey,
                        using: dependencies
                    )
                    .decoded(as: RevokeSubkeyResponse.self, using: dependencies)
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
    }
    
    // MARK: Delete
    
    public static func deleteMessages(
        publicKey: String,
        serverHashes: [String],
        using dependencies: Dependencies = Dependencies()
    ) -> AnyPublisher<[String: Bool], Error> {
        guard let userED25519KeyPair = Identity.fetchUserEd25519KeyPair() else {
            return Fail(error: SnodeAPIError.noKeyPair)
                .eraseToAnyPublisher()
        }
        
        let userX25519PublicKey: String = getUserHexEncodedPublicKey(using: dependencies)
        
        return getSwarm(for: publicKey)
            .tryFlatMapWithRandomSnode(retry: maxRetryCount) { snode -> AnyPublisher<[String: Bool], Error> in
                SnodeAPI
                    .send(
                        request: SnodeRequest(
                            endpoint: .deleteMessages,
                            body: DeleteMessagesRequest(
                                messageHashes: serverHashes,
                                requireSuccessfulDeletion: false,
                                pubkey: userX25519PublicKey,
                                ed25519PublicKey: userED25519KeyPair.publicKey,
                                ed25519SecretKey: userED25519KeyPair.secretKey
                            )
                        ),
                        to: snode,
                        associatedWith: publicKey,
                        using: dependencies
                    )
                    .decoded(as: DeleteMessagesResponse.self, using: dependencies)
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
        
        return getSwarm(for: userX25519PublicKey)
            .tryFlatMapWithRandomSnode(retry: maxRetryCount) { snode -> AnyPublisher<[String: Bool], Error> in
                getNetworkTime(from: snode)
                    .flatMap { timestampMs -> AnyPublisher<[String: Bool], Error> in
                        SnodeAPI
                            .send(
                                request: SnodeRequest(
                                    endpoint: .deleteAll,
                                    body: DeleteAllMessagesRequest(
                                        namespace: namespace,
                                        pubkey: userX25519PublicKey,
                                        timestampMs: timestampMs,
                                        ed25519PublicKey: userED25519KeyPair.publicKey,
                                        ed25519SecretKey: userED25519KeyPair.secretKey
                                    )
                                ),
                                to: snode,
                                associatedWith: nil,
                                using: dependencies
                            )
                            .decoded(as: DeleteAllMessagesResponse.self, using: dependencies)
                            .tryMap { _, response -> [String: Bool] in
                                try response.validResultMap(
                                    sodium: sodium.wrappedValue,
                                    userX25519PublicKey: userX25519PublicKey,
                                    validationData: timestampMs
                                )
                            }
                            .eraseToAnyPublisher()
                    }
                    .eraseToAnyPublisher()
            }
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
        
        return getSwarm(for: userX25519PublicKey)
            .tryFlatMapWithRandomSnode(retry: maxRetryCount) { snode -> AnyPublisher<[String: Bool], Error> in
                getNetworkTime(from: snode)
                    .flatMap { timestampMs -> AnyPublisher<[String: Bool], Error> in
                        SnodeAPI
                            .send(
                                request: SnodeRequest(
                                    endpoint: .deleteAllBefore,
                                    body: DeleteAllBeforeRequest(
                                        beforeMs: beforeMs,
                                        namespace: namespace,
                                        pubkey: userX25519PublicKey,
                                        timestampMs: timestampMs,
                                        ed25519PublicKey: userED25519KeyPair.publicKey,
                                        ed25519SecretKey: userED25519KeyPair.secretKey
                                    )
                                ),
                                to: snode,
                                associatedWith: nil,
                                using: dependencies
                            )
                            .decoded(as: DeleteAllBeforeResponse.self, using: dependencies)
                            .tryMap { _, response -> [String: Bool] in
                                try response.validResultMap(
                                    sodium: sodium.wrappedValue,
                                    userX25519PublicKey: userX25519PublicKey,
                                    validationData: beforeMs
                                )
                            }
                            .eraseToAnyPublisher()
                    }
                    .eraseToAnyPublisher()
            }
    }
    
    // MARK: - Internal API
    
    private static func getNetworkTime(
        from snode: Snode,
        using dependencies: Dependencies = Dependencies()
    ) -> AnyPublisher<UInt64, Error> {
        return SnodeAPI
            .send(
                request: SnodeRequest<[String: String]>(
                    endpoint: .getInfo,
                    body: [:]
                ),
                to: snode,
                associatedWith: nil,
                using: dependencies
            )
            .decoded(as: GetNetworkTimestampResponse.self, using: dependencies)
            .map { _, response in response.timestamp }
            .eraseToAnyPublisher()
    }
    
    internal static func getRandomSnode() -> AnyPublisher<Snode, Error> {
        // randomElement() uses the system's default random generator, which is cryptographically secure
        return getSnodePool()
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
        guard let payload: Data = try? JSONEncoder().encode(request) else {
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
        guard let payload: Data = try? JSONEncoder().encode(request) else {
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
                            return (SnodeAPI.handleError(withStatusCode: statusCode, data: data, forSnode: snode, associatedWith: publicKey) ?? error)
                            
                        default: return error
                    }
                }
                .eraseToAnyPublisher()
        }
        
        return dependencies.network
            .send(.onionRequest(payload, to: snode))
            .mapError { error in
                switch error {
                    case HTTPError.httpRequestFailed(let statusCode, let data):
                        return (SnodeAPI.handleError(withStatusCode: statusCode, data: data, forSnode: snode, associatedWith: publicKey) ?? error)
                        
                    default: return error
                }
            }
            .handleEvents(
                receiveOutput: { _, maybeData in
                    // Extract and store hard fork information if returned
                    guard
                        let data: Data = maybeData,
                        let snodeResponse: SnodeResponse = try? JSONDecoder()
                            .decode(SnodeResponse.self, from: data)
                    else { return }
                    
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
                }
            )
            .eraseToAnyPublisher()
    }
    
    // MARK: - Parsing
    
    // The parsing utilities below use a best attempt approach to parsing; they warn for parsing
    // failures but don't throw exceptions.

    private static func parseSnodes(from responseData: Data?) -> Set<Snode> {
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
            let swarmSnodes: [SwarmSnode] = try? JSONDecoder().decode([Failable<SwarmSnode>].self, from: snodeData).compactMap({ $0.value }),
            !swarmSnodes.isEmpty
        {
            return swarmSnodes.map { $0.toSnode() }.asSet()
        }
        
        return ((try? JSONDecoder().decode([Failable<Snode>].self, from: snodeData)) ?? [])
            .compactMap { $0.value }
            .asSet()
    }

    // MARK: - Error Handling
    
    @discardableResult
    internal static func handleError(
        withStatusCode statusCode: UInt,
        data: Data?,
        forSnode snode: Snode,
        associatedWith publicKey: String? = nil
    ) -> Error? {
        func handleBadSnode() {
            let oldFailureCount = (SnodeAPI.snodeFailureCount.wrappedValue[snode] ?? 0)
            let newFailureCount = oldFailureCount + 1
            SnodeAPI.snodeFailureCount.mutate { $0[snode] = newFailureCount }
            SNLog("Couldn't reach snode at: \(snode); setting failure count to \(newFailureCount).")
            if newFailureCount >= SnodeAPI.snodeFailureThreshold {
                SNLog("Failure threshold reached for: \(snode); dropping it.")
                if let publicKey = publicKey {
                    SnodeAPI.dropSnodeFromSwarmIfNeeded(snode, publicKey: publicKey)
                }
                SnodeAPI.dropSnodeFromSnodePool(snode)
                SNLog("Snode pool count: \(snodePool.wrappedValue.count).")
                SnodeAPI.snodeFailureCount.mutate { $0[snode] = 0 }
            }
        }
        
        switch statusCode {
            case 500, 502, 503:
                // The snode is unreachable
                handleBadSnode()
                
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
                        SnodeAPI.dropSnodeFromSwarmIfNeeded(snode, publicKey: publicKey)
                    }
                    
                    if let data: Data = data {
                        let snodes = parseSnodes(from: data)
                        
                        if !snodes.isEmpty {
                            setSwarm(to: snodes, for: publicKey)
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
                handleBadSnode()
                SNLog("Unhandled response code: \(statusCode).")
        }
        
        return nil
    }
}

@objc(SNSnodeAPI)
public final class SNSnodeAPI: NSObject {
    @objc(currentOffsetTimestampMs)
    public static func currentOffsetTimestampMs() -> UInt64 {
        return UInt64(SnodeAPI.currentOffsetTimestampMs())
    }
}

// MARK: - Convenience

public extension Publisher where Output == Set<Snode> {
    func tryFlatMapWithRandomSnode<T, P>(
        maxPublishers: Subscribers.Demand = .unlimited,
        retry retries: Int = 0,
        _ transform: @escaping (Snode) throws -> P
    ) -> AnyPublisher<T, Error> where T == P.Output, P: Publisher, P.Failure == Error {
        return self
            .mapError { $0 }
            .flatMap(maxPublishers: maxPublishers) { swarm -> AnyPublisher<T, Error> in
                var remainingSnodes: Set<Snode> = swarm
                
                return Just(())
                    .setFailureType(to: Error.self)
                    .tryFlatMap(maxPublishers: maxPublishers) { _ -> AnyPublisher<T, Error> in
                        let snode: Snode = try remainingSnodes.popRandomElement() ?? { throw SnodeAPIError.generic }()
                        
                        return try transform(snode)
                            .eraseToAnyPublisher()
                    }
                    .retry(retries)
                    .eraseToAnyPublisher()
            }
            .eraseToAnyPublisher()
    }
}
