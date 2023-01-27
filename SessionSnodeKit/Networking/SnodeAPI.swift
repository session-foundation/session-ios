// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import Sodium
import GRDB
import SessionUtilitiesKit

public final class SnodeAPI {
    public typealias TargetedMessage = (message: SnodeMessage, namespace: Namespace)
    
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
            "https://storage.seed1.loki.network:4433",
            "https://storage.seed3.loki.network:4433",
            "https://public.loki.foundation:4433"
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
    
    private static func setSnodePool(to newValue: Set<Snode>, db: Database? = nil) {
        snodePool.mutate { $0 = newValue }
        
        if let db: Database = db {
            _ = try? Snode.deleteAll(db)
            newValue.forEach { try? $0.save(db) }
        }
        else {
            Storage.shared.write { db in
                _ = try? Snode.deleteAll(db)
                newValue.forEach { try? $0.save(db) }
            }
        }
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
    
    public static func getSnodePool() -> AnyPublisher<Set<Snode>, Error> {
        loadSnodePoolIfNeeded()
        
        let now: Date = Date()
        let hasSnodePoolExpired: Bool = given(Storage.shared[.lastSnodePoolRefreshDate]) {
            now.timeIntervalSince($0) > 2 * 60 * 60
        }.defaulting(to: true)
        let snodePool: Set<Snode> = SnodeAPI.snodePool.wrappedValue
        
        guard hasInsufficientSnodes || hasSnodePoolExpired else {
            return Just(snodePool)
                .setFailureType(to: Error.self)
                .eraseToAnyPublisher()
        }
        
        if let getSnodePoolPublisher: AnyPublisher<Set<Snode>, Error> = getSnodePoolPublisher.wrappedValue {
            return getSnodePoolPublisher
        }
        
        let publisher: AnyPublisher<Set<Snode>, Error>
        if snodePool.count < minSnodePoolCount {
            publisher = getSnodePoolFromSeedNode()
        }
        else {
            publisher = getSnodePoolFromSnode()
                .catch { _ in getSnodePoolFromSeedNode() }
                .eraseToAnyPublisher()
        }
        
        getSnodePoolPublisher.mutate { $0 = publisher }
        
        return publisher
            .flatMap { snodePool -> AnyPublisher<Set<Snode>, Error> in
                guard !snodePool.isEmpty else {
                    return Fail(error: SnodeAPIError.snodePoolUpdatingFailed)
                        .eraseToAnyPublisher()
                }
            
                return Storage.shared
                    .writePublisher { db in
                        db[.lastSnodePoolRefreshDate] = now
                        setSnodePool(to: snodePool, db: db)
                        
                        return snodePool
                    }
                    .eraseToAnyPublisher()
            }
            .handleEvents(
                receiveCompletion: { _ in getSnodePoolPublisher.mutate { $0 = nil } }
            )
            .eraseToAnyPublisher()
    }
    
    public static func getSessionID(for onsName: String) -> AnyPublisher<String, Error> {
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
                                            associatedWith: nil
                                        )
                                        .decoded(as: ONSResolveResponse.self)
                                        .flatMap { _, response -> AnyPublisher<String, Error> in
                                            do {
                                                let result: String = try response.sessionId(
                                                    sodium: sodium.wrappedValue,
                                                    nameBytes: nameAsData,
                                                    nameHashBytes: nameHash
                                                )
                                                
                                                return Just(result)
                                                    .setFailureType(to: Error.self)
                                                    .eraseToAnyPublisher()
                                            }
                                            catch {
                                                return Fail(error: error)
                                                    .eraseToAnyPublisher()
                                            }
                                        }
                                        .retry(4)
                                        .eraseToAnyPublisher()
                                }
                    }
            )
            .subscribe(on: Threading.workQueue)
            .collect()
            .flatMap { results -> AnyPublisher<String, Error> in
                guard results.count == validationCount, Set(results).count == 1 else {
                    return Fail(error: SnodeAPIError.validationFailed)
                        .eraseToAnyPublisher()
                }
                
                return Just(results[0])
                    .setFailureType(to: Error.self)
                    .eraseToAnyPublisher()
            }
            .eraseToAnyPublisher()
    }
    
    public static func getSwarm(
        for publicKey: String,
        using dependencies: SSKDependencies = SSKDependencies()
    ) -> AnyPublisher<Set<Snode>, Error> {
        loadSwarmIfNeeded(for: publicKey)
        
        if let cachedSwarm = swarmCache.wrappedValue[publicKey], cachedSwarm.count >= minSwarmSnodeCount {
            return Just(cachedSwarm)
                .setFailureType(to: Error.self)
                .eraseToAnyPublisher()
        }
        
        SNLog("Getting swarm for: \((publicKey == getUserHexEncodedPublicKey()) ? "self" : publicKey).")
        let targetPublicKey: String = (Features.useTestnet ?
            publicKey.removingIdPrefixIfNeeded() :
            publicKey
        )
        
        return getRandomSnode()
            .flatMap { snode in
                SnodeAPI.send(
                    request: SnodeRequest(
                        endpoint: .getSwarm,
                        body: GetSwarmRequest(pubkey: targetPublicKey)
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
    
    public static func getMessages(
        in namespaces: [SnodeAPI.Namespace],
        from snode: Snode,
        associatedWith publicKey: String,
        using dependencies: SSKDependencies = SSKDependencies()
    ) -> AnyPublisher<[SnodeAPI.Namespace: (info: ResponseInfoType, data: (messages: [SnodeReceivedMessage], lastHash: String?)?)], Error> {
        let targetPublicKey: String = (Features.useTestnet ?
            publicKey.removingIdPrefixIfNeeded() :
            publicKey
        )
        var userED25519KeyPair: Box.KeyPair?
        
        return Just(())
            .setFailureType(to: Error.self)
            .flatMap { _ -> Future<[SnodeAPI.Namespace: String], Error> in
                Future<[SnodeAPI.Namespace: String], Error> { resolver in
                    let namespaceLastHash: [SnodeAPI.Namespace: String] = namespaces
                        .reduce(into: [:]) { result, namespace in
                            // Prune expired message hashes for this namespace on this service node
                            SnodeReceivedMessageInfo.pruneExpiredMessageHashInfo(
                                for: snode,
                                namespace: namespace,
                                associatedWith: publicKey
                            )
                            
                            let maybeLastHash: String? = SnodeReceivedMessageInfo
                                .fetchLastNotExpired(
                                    for: snode,
                                    namespace: namespace,
                                    associatedWith: publicKey
                                )?
                                .hash
                            
                            guard let lastHash: String = maybeLastHash else { return }
                            
                            result[namespace] = lastHash
                        }
                    
                    resolver(Result.success(namespaceLastHash))
                }
            }
            .flatMap { namespaceLastHash -> AnyPublisher<[SnodeAPI.Namespace: (info: ResponseInfoType, data: (messages: [SnodeReceivedMessage], lastHash: String?)?)], Error> in
                let requests: [SnodeAPI.BatchRequest.Info]
                
                do {
                    requests = try namespaces
                        .map { namespace -> SnodeAPI.BatchRequest.Info in
                            // Check if this namespace requires authentication
                            guard namespace.requiresReadAuthentication else {
                                return BatchRequest.Info(
                                    request: SnodeRequest(
                                        endpoint: .getMessages,
                                        body: LegacyGetMessagesRequest(
                                            pubkey: targetPublicKey,
                                            lastHash: (namespaceLastHash[namespace] ?? ""),
                                            namespace: namespace
                                        )
                                    ),
                                    responseType: GetMessagesResponse.self
                                )
                            }
                            
                            // Generate the signature
                            guard let keyPair: Box.KeyPair = (userED25519KeyPair ?? Storage.shared.read { db in Identity.fetchUserEd25519KeyPair(db) }) else {
                                throw SnodeAPIError.signingFailed
                            }
                            
                            userED25519KeyPair = keyPair
                            
                            return BatchRequest.Info(
                                request: SnodeRequest(
                                    endpoint: .getMessages,
                                    body: GetMessagesRequest(
                                        lastHash: (namespaceLastHash[namespace] ?? ""),
                                        namespace: namespace,
                                        pubkey: targetPublicKey,
                                        subkey: nil,
                                        timestampMs: UInt64(SnodeAPI.currentOffsetTimestampMs()),
                                        ed25519PublicKey: keyPair.publicKey,
                                        ed25519SecretKey: keyPair.secretKey
                                    )
                                ),
                                responseType: GetMessagesResponse.self
                            )
                        }
                }
                catch {
                    return Fail(error: error)
                        .eraseToAnyPublisher()
                }
                
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
                    .map { batchResponse -> [SnodeAPI.Namespace: (info: ResponseInfoType, data: (messages: [SnodeReceivedMessage], lastHash: String?)?)] in
                        zip(namespaces, batchResponse.responses)
                            .reduce(into: [:]) { result, next in
                                guard
                                    let subResponse: HTTP.BatchSubResponse<GetMessagesResponse> = (next.1 as?  HTTP.BatchSubResponse<GetMessagesResponse>),
                                    let messageResponse: GetMessagesResponse = subResponse.body
                                else {
                                    return
                                }

                                let namespace: SnodeAPI.Namespace = next.0
                                
                                result[namespace] = (
                                    info: subResponse.responseInfo,
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
    
    // MARK: - Store
    
    public static func sendMessage(
        _ message: SnodeMessage,
        in namespace: Namespace,
        using dependencies: SSKDependencies = SSKDependencies()
    ) -> AnyPublisher<(ResponseInfoType, SendMessagesResponse), Error> {
        let publicKey: String = (Features.useTestnet ?
            message.recipient.removingIdPrefixIfNeeded() :
            message.recipient
        )
        
        // Create a convenience method to send a message to an individual Snode
        func sendMessage(to snode: Snode) -> AnyPublisher<(any ResponseInfoType, SendMessagesResponse), Error> {
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
                    
            guard let userED25519KeyPair: Box.KeyPair = Storage.shared.read({ db in Identity.fetchUserEd25519KeyPair(db) }) else {
                return Fail(error: SnodeAPIError.noKeyPair)
                    .eraseToAnyPublisher()
            }
            
            return SnodeAPI
                .send(
                    request: SnodeRequest(
                        endpoint: .sendMessage,
                        body: SendMessageRequest(
                            message: message,
                            namespace: namespace,
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
                .decoded(as: SendMessagesResponse.self, using: dependencies)
                .eraseToAnyPublisher()
        }
        
        return getSwarm(for: publicKey)
            .subscribe(on: Threading.workQueue)
            .flatMap { swarm -> AnyPublisher<(ResponseInfoType, SendMessagesResponse), Error> in
                guard let snode: Snode = swarm.randomElement() else {
                    return Fail(error: SnodeAPIError.generic)
                        .eraseToAnyPublisher()
                }
                
                return sendMessage(to: snode)
                    .retry(maxRetryCount)
                    .eraseToAnyPublisher()
            }
            .retry(maxRetryCount)
            .eraseToAnyPublisher()
    }
    
    public static func sendConfigMessages(
        _ targetedMessages: [TargetedMessage],
        oldHashes: [String],
        using dependencies: SSKDependencies = SSKDependencies()
    ) -> AnyPublisher<HTTP.BatchResponse, Error> {
        guard
            !targetedMessages.isEmpty,
            let recipient: String = targetedMessages.first?.message.recipient
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
        let publicKey: String = (Features.useTestnet ?
            recipient.removingIdPrefixIfNeeded() :
            recipient
        )
        var requests: [SnodeAPI.BatchRequest.Info] = targetedMessages
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
        if !oldHashes.isEmpty {
            requests.append(
                BatchRequest.Info(
                    request: SnodeRequest(
                        endpoint: .deleteMessages,
                        body: DeleteMessagesRequest(
                            messageHashes: oldHashes,
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
            .subscribe(on: Threading.workQueue)
            .flatMap { swarm -> AnyPublisher<HTTP.BatchResponse, Error> in
                guard let snode: Snode = swarm.randomElement() else {
                    return Fail(error: SnodeAPIError.generic)
                        .eraseToAnyPublisher()
                }
                
                return SnodeAPI
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
            .retry(maxRetryCount)
            .eraseToAnyPublisher()
    }
    
    // MARK: - Edit
    
    public static func updateExpiry(
        publicKey: String,
        serverHashes: [String],
        updatedExpiryMs: UInt64,
        using dependencies: SSKDependencies = SSKDependencies()
    ) -> AnyPublisher<[String: (hashes: [String], expiry: UInt64)], Error> {
        guard let userED25519KeyPair = Identity.fetchUserEd25519KeyPair() else {
            return Fail(error: SnodeAPIError.noKeyPair)
                .eraseToAnyPublisher()
        }
        
        let publicKey: String = (Features.useTestnet ?
            publicKey.removingIdPrefixIfNeeded() :
            publicKey
        )
        
        return getSwarm(for: publicKey)
            .subscribe(on: Threading.workQueue)
            .flatMap { swarm -> AnyPublisher<[String: (hashes: [String], expiry: UInt64)], Error> in
                guard let snode: Snode = swarm.randomElement() else {
                    return Fail(error: SnodeAPIError.generic)
                        .eraseToAnyPublisher()
                }
                
                return SnodeAPI
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
                    .flatMap { _, response -> AnyPublisher<[String: (hashes: [String], expiry: UInt64)], Error> in
                        do {
                            let result: [String: (hashes: [String], expiry: UInt64)] = try response.validResultMap(
                                userX25519PublicKey: getUserHexEncodedPublicKey(),
                                messageHashes: serverHashes,
                                sodium: sodium.wrappedValue
                            )
                            
                            return Just(result)
                                .setFailureType(to: Error.self)
                                .eraseToAnyPublisher()
                        }
                        catch {
                            return Fail(error: error)
                                .eraseToAnyPublisher()
                        }
                    }
                    .retry(maxRetryCount)
                    .eraseToAnyPublisher()
            }
            .retry(maxRetryCount)
            .eraseToAnyPublisher()
    }
    
    public static func revokeSubkey(
        publicKey: String,
        subkeyToRevoke: String,
        using dependencies: SSKDependencies = SSKDependencies()
    ) -> AnyPublisher<Void, Error> {
        guard let userED25519KeyPair = Identity.fetchUserEd25519KeyPair() else {
            return Fail(error: SnodeAPIError.noKeyPair)
                .eraseToAnyPublisher()
        }
        
        let publicKey: String = (Features.useTestnet ?
            publicKey.removingIdPrefixIfNeeded() :
            publicKey
        )
        
        return getSwarm(for: publicKey)
            .subscribe(on: Threading.workQueue)
            .flatMap { swarm -> AnyPublisher<Void, Error> in
                guard let snode: Snode = swarm.randomElement() else {
                    return Fail(error: SnodeAPIError.generic)
                        .eraseToAnyPublisher()
                }
                
                return SnodeAPI
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
                    .flatMap { _, response -> AnyPublisher<Void, Error> in
                        do {
                            try response.validateResult(
                                userX25519PublicKey: getUserHexEncodedPublicKey(),
                                subkeyToRevoke: subkeyToRevoke,
                                sodium: sodium.wrappedValue
                            )
                        }
                        catch {
                            return Fail(error: error)
                                .eraseToAnyPublisher()
                        }
                        
                        return Just(())
                            .setFailureType(to: Error.self)
                            .eraseToAnyPublisher()
                    }
                    .retry(maxRetryCount)
                    .eraseToAnyPublisher()
            }
            .retry(maxRetryCount)
            .eraseToAnyPublisher()
    }
    
    // MARK: Delete
    
    public static func deleteMessages(
        publicKey: String,
        serverHashes: [String],
        using dependencies: SSKDependencies = SSKDependencies()
    ) -> AnyPublisher<[String: Bool], Error> {
        guard let userED25519KeyPair = Identity.fetchUserEd25519KeyPair() else {
            return Fail(error: SnodeAPIError.noKeyPair)
                .eraseToAnyPublisher()
        }
        
        let publicKey: String = (Features.useTestnet ?
            publicKey.removingIdPrefixIfNeeded() :
            publicKey
        )
        let userX25519PublicKey: String = getUserHexEncodedPublicKey()
        
        return getSwarm(for: publicKey)
            .subscribe(on: Threading.workQueue)
            .flatMap { swarm -> AnyPublisher<[String: Bool], Error> in
                Just(())
                    .setFailureType(to: Error.self)
                    .flatMap { _ -> AnyPublisher<Snode, Error> in
                        guard let snode: Snode = swarm.randomElement() else {
                            return Fail(error: SnodeAPIError.generic)
                                .eraseToAnyPublisher()
                        }
                        
                        return Just(snode)
                            .setFailureType(to: Error.self)
                            .eraseToAnyPublisher()
                    }
                    .flatMap { snode -> AnyPublisher<[String: Bool], Error> in
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
                            .subscribe(on: Threading.workQueue)
                            .eraseToAnyPublisher()
                            .decoded(as: DeleteMessagesResponse.self, using: dependencies)
                            .map { _, response -> [String: Bool] in
                                let validResultMap: [String: Bool] = response.validResultMap(
                                    userX25519PublicKey: userX25519PublicKey,
                                    serverHashes: serverHashes,
                                    sodium: sodium.wrappedValue
                                )
                                
                                // If at least one service node deleted successfully then we should
                                // mark the hash as invalid so we don't try to fetch updates using
                                // that hash going forward (if we do we would end up re-fetching
                                // all old messages)
                                if validResultMap.values.contains(true) {
                                    Storage.shared.writeAsync { db in
                                        try? SnodeReceivedMessageInfo.handlePotentialDeletedOrInvalidHash(
                                            db,
                                            potentiallyInvalidHashes: serverHashes
                                        )
                                    }
                                }
                                
                                return validResultMap
                            }
                            .retry(maxRetryCount)
                            .eraseToAnyPublisher()
                    }
                    .eraseToAnyPublisher()
            }
            .retry(maxRetryCount)
            .eraseToAnyPublisher()
    }
    
    /// Clears all the user's data from their swarm. Returns a dictionary of snode public key to deletion confirmation.
    public static func deleteAllMessages(
        namespace: SnodeAPI.Namespace? = nil,
        using dependencies: SSKDependencies = SSKDependencies()
    ) -> AnyPublisher<[String: Bool], Error> {
        guard let userED25519KeyPair = Identity.fetchUserEd25519KeyPair() else {
            return Fail(error: SnodeAPIError.noKeyPair)
                .eraseToAnyPublisher()
        }
        
        let userX25519PublicKey: String = getUserHexEncodedPublicKey()
        
        return getSwarm(for: userX25519PublicKey)
            .subscribe(on: Threading.workQueue)
            .flatMap { swarm -> AnyPublisher<[String: Bool], Error> in
                guard let snode: Snode = swarm.randomElement() else {
                    return Fail(error: SnodeAPIError.generic)
                        .eraseToAnyPublisher()
                }
                
                return getNetworkTime(from: snode)
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
                            .map { _, response in
                                let validResultMap: [String: Bool] = response.validResultMap(
                                    userX25519PublicKey: userX25519PublicKey,
                                    timestampMs: timestampMs,
                                    sodium: sodium.wrappedValue
                                )
                                
                                return validResultMap
                            }
                            .eraseToAnyPublisher()
                    }
                    .retry(maxRetryCount)
                    .eraseToAnyPublisher()
            }
            .retry(maxRetryCount)
            .eraseToAnyPublisher()
    }
    
    /// Clears all the user's data from their swarm. Returns a dictionary of snode public key to deletion confirmation.
    public static func deleteAllMessages(
        beforeMs: UInt64,
        namespace: SnodeAPI.Namespace? = nil,
        using dependencies: SSKDependencies = SSKDependencies()
    ) -> AnyPublisher<[String: Bool], Error> {
        guard let userED25519KeyPair = Identity.fetchUserEd25519KeyPair() else {
            return Fail(error: SnodeAPIError.noKeyPair)
                .eraseToAnyPublisher()
        }
        
        let userX25519PublicKey: String = getUserHexEncodedPublicKey()
        
        return getSwarm(for: userX25519PublicKey)
            .subscribe(on: Threading.workQueue)
            .flatMap { swarm -> AnyPublisher<[String: Bool], Error> in
                guard let snode: Snode = swarm.randomElement() else {
                    return Fail(error: SnodeAPIError.generic)
                        .eraseToAnyPublisher()
                }
                
                return getNetworkTime(from: snode)
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
                            .map { _, response in
                                let validResultMap: [String: Bool] = response.validResultMap(
                                    userX25519PublicKey: userX25519PublicKey,
                                    beforeMs: beforeMs,
                                    sodium: sodium.wrappedValue
                                )
                                
                                return validResultMap
                            }
                            .eraseToAnyPublisher()
                    }
                    .retry(maxRetryCount)
                    .eraseToAnyPublisher()
            }
            .retry(maxRetryCount)
            .eraseToAnyPublisher()
    }
    
    // MARK: - Internal API
    
    private static func getNetworkTime(
        from snode: Snode,
        using dependencies: SSKDependencies = SSKDependencies()
    ) -> AnyPublisher<UInt64, Error> {
        return SnodeAPI
            .send(
                request: SnodeRequest<[String: String]>(
                    endpoint: .getInfo,
                    body: [:]
                ),
                to: snode,
                associatedWith: nil
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
        dependencies: SSKDependencies = SSKDependencies()
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
            .subscribe(on: Threading.workQueue)
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
            .retry(4)
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
        dependencies: SSKDependencies = SSKDependencies()
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
                                associatedWith: nil
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
            .flatMap { results -> AnyPublisher<Set<Snode>, Error> in
                let result: Set<Snode> = results.reduce(Set()) { prev, next in prev.intersection(next) }
                
                // We want the snodes to agree on at least this many snodes
                guard result.count > 24 else {
                    return Fail(error: SnodeAPIError.inconsistentSnodePools)
                        .eraseToAnyPublisher()
                }
                
                // Limit the snode pool size to 256 so that we don't go too long without
                // refreshing it
                return Just(Set(result.prefix(256)))
                    .setFailureType(to: Error.self)
                    .eraseToAnyPublisher()
            }
            .eraseToAnyPublisher()
    }
    
    private static func send<T: Encodable>(
        request: SnodeRequest<T>,
        to snode: Snode,
        associatedWith publicKey: String?,
        using dependencies: SSKDependencies = SSKDependencies()
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
        
        return dependencies.onionApi
            .sendOnionRequest(
                payload,
                to: snode
            )
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
    
    /// - Note: Should only be invoked from `Threading.workQueue` to avoid race conditions.
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
