// Copyright © 2026 Rangeproof Pty Ltd. All rights reserved.

import Testing
import Foundation
import Combine
import GRDB
import SessionUIKit
import SessionMessagingKit
import TestUtilities

@testable import SessionNetworkingKit
@testable import SessionUtilitiesKit

@Suite("Network Resilience Tests", .serialized)
struct MessageSendJobResilienceTests {
    var fixture: ResilienceTestFixture!
    var snodePoolCacheData: Data!
    
    init() async throws {
        fixture = try await ResilienceTestFixture.create(
            serviceNetwork: .testnet,
            router: .onionRequests
        )
        fixture.clearTestData()
        
        fixture.useLiveDateNow()
        try await fixture.createStorage()
        try fixture.createWarmedNetwork(
            customCachePath: nil,
            snodePoolCacheData: nil
        )
        
        /// We need to ensure we have a snode pool (don't want fetching the snode pool to impact the timing results of the tests) so
        /// get the swarm for a pubkey which will fetch the snode pool if it's empty
        print("▷ Waiting for snode cache to be populated...")
        _ = try await fixture.dependencies[singleton: .network]
            .getSwarm(for: "05\(TestConstants.publicKey)", ignoreStrikeCount: true)
        
        // TODO: [NETWORK REFACTOR] The `getSwarm` call won't work for SessionRouter because it just returns an empty value immediately, need to loop and wait
        for _ in 0..<8 {
            _ = try await fixture.dependencies[singleton: .network]
                .getSwarm(for: "05\(TestConstants.publicKey)", ignoreStrikeCount: true)
            try? await Task.sleep(for: .seconds(1))
        }
        
        snodePoolCacheData = try Data(contentsOf: URL(fileURLWithPath: "\(LibSessionNetwork.snodeCachePath)/snode_pool_testnet"))
        print("↳ Completed")
    }
    
    typealias Config = ResilienceTest.Config
    private static let directRequestConfigs: [Config] = {
        [
            Config.directVariations(
                nickname: "Direct Send",
                variant: .sendMessage,
                attempts: 200,
                networkModes: [.newNetworkPerRequest, .shared],
                behaviours: [
                    .concurrent(num: 50),
                    .staggered(delayMs: 250)
                ],
                numPaths: [2]
            ),
            Config.directVariations(
                nickname: "Direct Upload",
                variant: .sendAttachment(fileSize: (5 * 1024 * 1024)),
                attempts: 24,
                networkModes: [.shared],
                behaviours: [
                    .concurrent(num: 2)
                ],
                numPaths: [2]
            ),
            Config.directVariations(
                nickname: "Direct Download",
                variant: .downloadAttachment(fileSize: (5 * 1024 * 1024)),
                attempts: 24,
                networkModes: [.shared],
                behaviours: [
                    .concurrent(num: 2)
                ],
                numPaths: [2]
            )
        ].flatMap { $0 }
    }()
    
    @Test(
        "Direct Request Resilience",
        .serialized,
        arguments: directRequestConfigs
    )
    func testDirectRequestResilience(config: Config) async throws {
        var testResult: ResilienceTest = ResilienceTest(
            name: "Direct Request Resilience - \(config.testDescription)"
        )
        
        /// This test doesn't support the `messageAndAttachment` variant
        switch config.variant {
            case .sendMessage, .sendAttachment, .downloadAttachment,
                .downloadAttachmentConcurrentDownloads:
                break
            case .sendMessageWithAttachment: throw TestError.unableToEvaluateExpression
        }
        
        /// Before we run any tests we want to ensure we have a snode pool (don't want fetching the snode pool to impact the timing
        /// results of the tests)
        func setupNetwork(for fixture: ResilienceTestFixture) async throws {
            fixture.useLiveDateNow()
            
            /// The network will use "single path mode" if it's not running in the main app
            await fixture.mockAppContext.removeMocksFor { $0.isMainApp }
            try await fixture.mockAppContext
                .when { $0.isMainApp }
                .thenReturn(true)
            try await fixture.mockAppContext
                .when { await $0.isMainAppAndForeground }
                .thenReturn(true)
            
            try fixture.createWarmedNetwork(
                customCachePath: fixture.customCachePath,
                snodePoolCacheData: snodePoolCacheData
            )
        }
        
        let parentFixture: ResilienceTestFixture = try await ResilienceTestFixture.create(
            serviceNetwork: fixture.serviceNetwork,
            router: fixture.router
        )
        try await parentFixture.prepare(for: config)
        try await parentFixture.createStorage()
        try await setupNetwork(for: parentFixture)
        
        /// Perform any preparation work
        testResult.setupResult = await Result(catching: {
            try await parentFixture.prepareParentFixture(for: config, snodeCacheData: snodePoolCacheData)
        })
        
        /// Now we can kick off the actual tests
        if case .success = testResult.setupResult {
            await withTaskGroup(of: (attempt: Int, latency: TimeInterval, result: Result<Void, Error>, path: LibSession.Path?).self) { group in
                let fullStartTime: TimeInterval = parentFixture.dependencies.dateNow.timeIntervalSince1970
                
                for attempt in 1...config.numberOfAttempts {
                    /// Add stagger if desired
                    switch config.behaviour {
                        case .concurrent: break
                        case .staggered(let delayMs), .concurrentStaggered(_, let delayMs):
                            if delayMs > 0 && attempt > 1 {
                                try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
                                
                                /// Yield to give any previous tearDown the chance to complete
                                if config.mode == .newNetworkPerRequest {
                                    await Task.yield()
                                }
                            }
                    }
                    
                    group.addTask {
                        let fixture: ResilienceTestFixture
                        let job: Job
                        let targetPathIndex: UInt8 = UInt8(attempt % config.numPaths)
                        
                        do {
                            switch config.mode {
                                case .shared: fixture = parentFixture
                                case .newNetworkPerRequest:
                                    fixture = try await ResilienceTestFixture.create(
                                        serviceNetwork: parentFixture.serviceNetwork,
                                        router: parentFixture.router
                                    )
                                    try await fixture.prepare(for: config)
                                    fixture.setStorage(parentFixture.dependencies[singleton: .storage])
                                    fixture.setFileManager(parentFixture.dependencies[singleton: .fileManager])
                                    try await setupNetwork(for: fixture)
                            }
                            
                            job = try await fixture.createTestJob(
                                for: config.variant,
                                attempt: attempt,
                                pathIndex: targetPathIndex
                            )
                        }
                        catch { return (attempt, 0, .failure(error), nil) }
                        
                        let maybeTargetPath: LibSession.Path? = try? await {
                            let paths: [LibSession.Path] = try await fixture.dependencies[singleton: .network].getActivePaths()
                            
                            guard paths.count > targetPathIndex else { return nil }
                            
                            return paths[Int(targetPathIndex)]
                        }()
                        let startTime: TimeInterval = fixture.dependencies.dateNow.timeIntervalSince1970
                        let result: Result<Void, Error> = await Result(catching: {
                            try await fixture.runJob(job, attempt: attempt, usingJobRunner: false)
                        })
                        let latency: TimeInterval = fixture.dependencies.dateNow.timeIntervalSince1970 - startTime
                        let maybeTargetPath2: LibSession.Path? = try? await {
                            let paths: [LibSession.Path] = try await fixture.dependencies[singleton: .network].getActivePaths()
                            
                            guard paths.count > targetPathIndex else { return nil }
                            
                            return paths[Int(targetPathIndex)]
                        }()
                        
                        switch config.mode {
                            case .shared: break
                            case .newNetworkPerRequest: await fixture.tearDown()
                        }
                        
                        return (attempt, latency, result, (maybeTargetPath ?? maybeTargetPath2))
                    }
                    
                    /// Handle concurrenct limit if specified
                    switch config.behaviour {
                        case .staggered: break
                        case .concurrent(let num), .concurrentStaggered(let num, _):
                            if num > 0 && attempt % num == 0 && attempt < config.numberOfAttempts {
                                for await (attempt, latency, result, path) in group {
                                    testResult.recordResult(attempt: attempt, latency: latency, result: result, path: path)
                                }
                            }
                    }
                }
                
                /// Collect remaining results
                for await (attempt, latency, result, path) in group {
                    testResult.recordResult(attempt: attempt, latency: latency, result: result, path: path)
                }
                
                let endTime: TimeInterval = parentFixture.dependencies.dateNow.timeIntervalSince1970
                testResult.recordTiming(startTime: fullStartTime, endTime: endTime)
            }
        }
        
        await parentFixture.tearDown()
        
        print(testResult.description)
        
        #expect(testResult.successRate >= 0.95, "Success rate should be at least 95%")
        #expect(testResult.averageLatency < config.variant.averageLatencyLimit, "Average latency should be under 5 seconds")
    }
    
    private static let jobRunnerConfigs: [Config] = {
        [1, 2, 3, 4, 5].flatMap { iteration in
            return [
                Config.jobRunnerScenario(
                    nickname: "Job Runner Download - Run \(iteration)",
                    variant: .downloadAttachmentConcurrentDownloads(fileSize: (5 * 1024 * 1024)),
                    attempts: 24,
                    behaviour: .concurrent(num: 2),
                    numPaths: 2
                )
            ].flatMap { $0 }
        }
    }()
    
    @Test(
        "Job Runner Resilience",
        .serialized,
        arguments: jobRunnerConfigs
    )
    func testJobRunnerResilience(config: Config) async throws {
        var testResult: ResilienceTest = ResilienceTest(
            name: "Job Runner Resilience - \(config.testDescription)"
        )
        
        /// Setup the dependencies based on the config
        try await fixture.prepare(for: config)
        await fixture.createJobRunner()
        await fixture.mockAppContext.removeMocksFor { $0.isMainApp }
        try await fixture.mockAppContext
            .when { $0.isMainApp }
            .thenReturn(true)
        try await fixture.mockAppContext
            .when { await $0.isMainAppAndForeground }
            .thenReturn(true)
        try fixture.createWarmedNetwork(
            customCachePath: nil,   /// The main fixture will use the proper snode pool
            snodePoolCacheData: nil /// Same as above
        )
        
        /// Perform any preparation work
        testResult.setupResult = await Result(catching: {
            try await fixture.prepareParentFixture(for: config, snodeCacheData: snodePoolCacheData)
        })
        
        /// Now we can kick off the actual tests
        if case .success = testResult.setupResult {
            await withTaskGroup(of: (attempt: Int, latency: TimeInterval, result: Result<Void, Error>, path: LibSession.Path?).self) { group in
                let fullStartTime: TimeInterval = fixture.dependencies.dateNow.timeIntervalSince1970
                
                for attempt in 1...config.numberOfAttempts {
                    /// Add stagger if desired
                    switch config.behaviour {
                        case .concurrent: break
                        case .staggered(let delayMs), .concurrentStaggered(_, let delayMs):
                            if delayMs > 0 && attempt > 1 {
                                try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
                                
                                /// Yield to give any previous tearDown the chance to complete
                                if config.mode == .newNetworkPerRequest {
                                    await Task.yield()
                                }
                            }
                    }
                    
                    group.addTask {
                        var job: Job
                        let targetPathIndex: UInt8 = UInt8(attempt % config.numPaths)
                        
                        do {
                            job = try await fixture.createTestJob(
                                for: config.variant,
                                attempt: attempt,
                                pathIndex: targetPathIndex
                            )
                        }
                        catch { return (attempt, 0, .failure(error), nil) }
                        
                        let maybeTargetPath: LibSession.Path? = try? await {
                            let paths: [LibSession.Path] = try await fixture.dependencies[singleton: .network].getActivePaths()
                            
                            guard paths.count > targetPathIndex else { return nil }
                            
                            return paths[Int(targetPathIndex)]
                        }()
                        let startTime: TimeInterval = fixture.dependencies.dateNow.timeIntervalSince1970
                        let result: Result<Void, Error> = await Result(catching: {
                            job = try await fixture.runJob(job, attempt: attempt, usingJobRunner: true)
                            
                            let result: JobRunner.JobResult = try await fixture
                                .dependencies[singleton: .jobRunner]
                                .finalResult(for: job)
                            
                            switch result {
                                case .succeeded: return                 /// Leave the loop
                                case .failed(let error, _): throw error /// Fail immediately
                                case .deferred: throw NetworkError.explicit("Unexpected final deferral")
                            }
                        })
                        
                        let latency: TimeInterval = fixture.dependencies.dateNow.timeIntervalSince1970 - startTime
                        let maybeTargetPath2: LibSession.Path? = try? await {
                            let paths: [LibSession.Path] = try await fixture.dependencies[singleton: .network].getActivePaths()
                            
                            guard paths.count > targetPathIndex else { return nil }
                            
                            return paths[Int(targetPathIndex)]
                        }()
                        return (attempt, latency, result, (maybeTargetPath ?? maybeTargetPath2))
                    }
                    
                    /// Handle concurrenct limit if specified
                    switch config.behaviour {
                        case .staggered: break
                        case .concurrent(let num), .concurrentStaggered(let num, _):
                            if num > 0 && attempt % num == 0 && attempt < config.numberOfAttempts {
                                for await (attempt, latency, result, path) in group {
                                    testResult.recordResult(attempt: attempt, latency: latency, result: result, path: path)
                                }
                            }
                    }
                }
                
                /// Collect remaining results
                for await (attempt, latency, result, path) in group {
                    testResult.recordResult(attempt: attempt, latency: latency, result: result, path: path)
                }
                
                let endTime: TimeInterval = fixture.dependencies.dateNow.timeIntervalSince1970
                testResult.recordTiming(startTime: fullStartTime, endTime: endTime)
            }
        }
        
        await fixture.tearDown()
        
        print(testResult.description)
        
        #expect(testResult.successRate >= 0.95, "Success rate should be at least 95%")
        #expect(testResult.averageLatency < config.variant.averageLatencyLimit, "Average latency should be under 5 seconds")
    }
}

// MARK: - Test Fixture

class ResilienceTestFixture: FixtureBase {
    static let testDataPath: String = "\(SessionFileManager.nonInjectedAppSharedDataDirectoryPath)/testData"
    let customCachePath: String = "\(testDataPath)/snodeCache_\(UUID().uuidString)"
    
    var mockAppContext: MockAppContext { mock(for: .appContext) }
    var mockNetwork: MockNetwork { mock(for: .network) }
    var mockJobRunner: MockJobRunner { mock(for: .jobRunner) }
    var mockCrypto: MockCrypto { mock(for: .crypto) }
    var mockExtensionHelper: MockExtensionHelper { mock(for: .extensionHelper) }
    var mockFileManager: MockFileManager { mock(for: .fileManager) }
    var mockGeneralCache: MockGeneralCache { mock(cache: .general) }
    var mockLibSessionCache: MockLibSessionCache { mock(cache: .libSession) }
    var mockMediaDecoder: MockMediaDecoder { mock(for: .mediaDecoder) }
    var mockFileHandleFactory: MockFileHandleFactory { mock(for: .fileHandleFactory) }
    
    var serviceNetwork: ServiceNetwork { dependencies[feature: .serviceNetwork] }
    var router: Router { dependencies[feature: .router] }
        
    static func create(
        serviceNetwork: ServiceNetwork,
        router: Router
    ) async throws -> ResilienceTestFixture {
        let fixture: ResilienceTestFixture = ResilienceTestFixture()
        fixture.dependencies.set(feature: .serviceNetwork, to: serviceNetwork)
        fixture.dependencies.set(feature: .router, to: router)
        
        try await fixture.applyBaselineStubs()
        
        return fixture
    }
    
    func tearDown() async {
        let network: NetworkType = dependencies[singleton: .network]
        await (network as? LibSessionNetwork)?.shutdown()
        dependencies.remove(singleton: .network)
        
        await Task.yield()
        
        await dependencies[singleton: .jobRunner].stopAndClearJobs()
        _ = try? await dependencies[singleton: .storage].write { db in
            try Job.deleteAll(db)
        }
        
        dependencies.removeAll()
        try? FileManager.default.removeItem(atPath: customCachePath)
        
        await Task.yield()
    }
    
    // MARK: - Setup
    
    private func applyBaselineStubs() async throws {
        try await applyBaselineAppContext()
        try await applyBaselineNetwork()
        try await applyBaselineJobRunner()
        try await applyBaselineExtensionHelper()
        try await applyBaselineFileManager()
        try await applyBaselineGeneralCache()
        try await applyBaselineLibSessionCache()
        try await applyBaselineMediaDecoder()
        try await applyBaselineFileHandleFactory(fileSize: 0)
    }
    
    private func applyBaselineAppContext() async throws {
        try await mockAppContext.when { $0.isValid }.thenReturn(true)
        try await mockAppContext.when { $0.isMainApp }.thenReturn(false)
    }
    
    private func applyBaselineNetwork() async throws {}
    private func applyBaselineJobRunner() async throws {}
    
    private func applyBaselineFileManager() async throws {
        try await mockFileManager.defaultInitialSetup()
        
        try await mockFileManager.when { $0.fileExists(atPath: "tmpFile") }.thenReturn(true)
    }
    
    private func applyBaselineGeneralCache() async throws {
        try await mockGeneralCache
            .when { $0.sessionId }
            .thenReturn(SessionId(.standard, hex: TestConstants.publicKey))
        try await mockGeneralCache
            .when { $0.ed25519SecretKey }
            .thenReturn(Array(Data(hex: TestConstants.edSecretKey)))
        try await mockGeneralCache
            .when { $0.ed25519Seed }
            .thenReturn(Array(Data(hex: TestConstants.edKeySeed)))
    }
    
    private func applyBaselineExtensionHelper() async throws {
        try await mockExtensionHelper
            .when { try $0.createDedupeRecord(threadId: .any, uniqueIdentifier: .any) }
            .thenReturn(())
        try await mockExtensionHelper
            .when { $0.dedupeRecordExists(threadId: .any, uniqueIdentifier: .any) }
            .thenReturn(false)
    }
    
    private func applyBaselineLibSessionCache() async throws {}
    
    private func applyBaselineMediaDecoder() async throws {
        try await mockMediaDecoder.defaultInitialSetup()
        
        await mockMediaDecoder.removeMocksFor { $0.source(for: URL.any) }
        await mockMediaDecoder.removeMocksFor { $0.source(for: Data.any) }
        try await mockMediaDecoder.when { $0.source(for: URL.any) }.thenReturn(nil)
        try await mockMediaDecoder.when { $0.source(for: Data.any) }.thenReturn(nil)
    }
    
    private func applyBaselineFileHandleFactory(fileSize: UInt) async throws {
        await mockFileHandleFactory.removeAllMocks()
        
        try await mockFileHandleFactory
            .when { try $0.create(forWritingTo: .any) }
            .thenReturn { _ in
                TestFileHandle(data: Data([UInt8](repeating: 1, count: Int(fileSize))))
            }
        try await mockFileHandleFactory
            .when { $0.create(forWritingAtPath: .any) }
            .thenReturn { _ in
                TestFileHandle(data: Data([UInt8](repeating: 1, count: Int(fileSize))))
            }
        try await mockFileHandleFactory
            .when { try $0.create(forReadingFrom: .any) }
            .thenReturn { _ in
                TestFileHandle(data: Data([UInt8](repeating: 1, count: Int(fileSize))))
            }
        try await mockFileHandleFactory
            .when { $0.create(forReadingAtPath: .any) }
            .thenReturn { _ in
                TestFileHandle(data: Data([UInt8](repeating: 1, count: Int(fileSize))))
            }
    }
    
    // MARK: - Test Helpers
    
    func prepare(for config: ResilienceTest.Config) async throws {
        /// If we want data then create a `TestFileHandle` which had data at the desired size
        switch config.variant {
            case .downloadAttachment(let fileSize), .downloadAttachmentConcurrentDownloads(let fileSize),
                .sendAttachment(let fileSize), .sendMessageWithAttachment(let fileSize):
                try? await applyBaselineFileHandleFactory(fileSize: fileSize)
                
            case .sendMessage: break
        }
        
        /// Some test variants have custom feature flags to modify the default behaviour
        switch config.variant {
            case .sendMessage, .sendAttachment, .sendMessageWithAttachment:
                dependencies.set(feature: .allowDuplicateDownloads, to: false)
                
            case .downloadAttachment:
                dependencies.set(feature: .allowDuplicateDownloads, to: true)
                
            case .downloadAttachmentConcurrentDownloads:
                dependencies.set(feature: .allowDuplicateDownloads, to: true)
        }
        
        dependencies.set(feature: .serviceNetwork, to: .testnet)
        dependencies.set(feature: .router, to: .onionRequests)
        dependencies.set(feature: .disableNetworkRequestTimeouts, to: config.disableTimeouts)
        dependencies.set(feature: .onionRequestMinStandardPaths, to: config.numPaths)
        dependencies.set(feature: .onionRequestMinFilePaths, to: config.numPaths)
        
        switch config.behaviour {
            case .concurrent(let num), .concurrentStaggered(let num, _):
                dependencies.set(feature: .maxConcurrentFiles, to: num)
                
            case .staggered: dependencies.reset(feature: .maxConcurrentFiles)
        }
    }
    
    /// Prepare the parent fixture for a specific test variant (only want to do this once, and then share the instances with any
    /// child fixtures)
    func prepareParentFixture(for config: ResilienceTest.Config, snodeCacheData: Data) async throws {
        switch config.mode {
            case .newNetworkPerRequest: break
            case .shared:
                let numNodes: Int = ((String(data: snodeCacheData, encoding: .utf8) ?? "")?
                    .components(separatedBy: "\n")
                    .filter { !$0.isEmpty }
                    .count ?? 0)
                
                guard numNodes > 0 else {
                    throw NetworkError.explicit("Snode pool cache is empty")
                }
                guard config.numPaths <= (numNodes / 3) else {
                    throw NetworkError.explicit("Not enough nodes (\(numNodes / 3)) to build \(config.numPaths) paths")
                }
                
                print("▷ Waiting for paths to be built...")
                var numBuiltPaths: Int = 0
                for _ in 1...5 {
                    let paths: [Network.PathCategory: [LibSession.Path]] = try await dependencies[singleton: .network]
                        .getActivePaths()
                        .grouped(by: { $0.category ?? .standard })
                    numBuiltPaths = paths.count
                    
                    if (paths[config.variant.pathCategory] ?? []).count >= config.numPaths {
                        break
                    }
                    
                    try await Task.sleep(for: .seconds(1))
                }
                
                try #require(numBuiltPaths == config.numPaths, "Failed to build enough paths")
                print("↳ Completed")
        }
        
        var encryptionKey: Data?
        var digest: Data?
        
        /// Need to ensure the `MockFileManager` returns the right amount of content for the upload/download tests
        switch config.variant {
            case .sendMessage: break
            case .sendAttachment, .sendMessageWithAttachment, .downloadAttachment,
                .downloadAttachmentConcurrentDownloads:
                let readFileHandle: TestFileHandle? = (try dependencies[singleton: .fileHandleFactory].create(forReadingFrom: .any) as? TestFileHandle)
                let encryptionResult = try dependencies[singleton: .crypto].tryGenerate(
                    .legacyEncryptedAttachment(plaintext: readFileHandle?.data ?? Data())
                )
                encryptionKey = encryptionResult.encryptionKey
                digest = encryptionResult.digest
                
                await mockFileManager.removeMocksFor { try $0.contents(atPath: .any) }
                try await mockFileManager
                    .when { try $0.contents(atPath: .any) }
                    .thenReturn(encryptionResult.ciphertext)
        }
        
        /// Need to upload an attachment before we can test downloading
        switch config.variant {
            case .sendMessage, .sendAttachment, .sendMessageWithAttachment: break
            case .downloadAttachment(let fileSize),
                .downloadAttachmentConcurrentDownloads(let fileSize):
                /// Retry 3 times
                for index in 1...3 {
                    do {
                        print("▷ Performing upload for test (attempt \(index)/3)...")
                        try await dependencies[singleton: .storage].write { db in
                            try Interaction.deleteWhere(db, .deleteAll)
                            try Attachment.deleteAll(db)
                            try Job.deleteAll(db)
                        }
                        
                        let job: Job = try await createTestJob(
                            for: .sendAttachment(fileSize: fileSize),
                            attempt: 0,
                            pathIndex: nil
                        )
                        try await runJob(job, attempt: 0, usingJobRunner: false)
                        break
                    }
                    catch {
                        print("▷ Attempt \(index) Failed")
                        if index < 3 { continue }
                        
                        throw NetworkError.explicit("Initial attachment upload failed: \(error)")
                    }
                }
                
                /// Need to override the `encryptionKey` and `digest` of the attachment so that our mock encrypted
                /// data can be decrypted successfully
                try await dependencies[singleton: .storage].write { db in
                    try Attachment.updateAll(
                        db,
                        Attachment.Columns.encryptionKey.set(to: encryptionKey),
                        Attachment.Columns.digest.set(to: digest)
                    )
                }
                
                print("↳ Completed")
        }
    }
    
    func clearTestData() {
        try? FileManager.default.removeItem(atPath: ResilienceTestFixture.testDataPath)
    }
    
    func useLiveDateNow() {
        dependencies.useLiveDateNow()
    }
    
    func setStorage(_ storage: Storage) {
        dependencies.set(singleton: .storage, to: storage)
    }
    
    func setFileManager(_ fileManager: FileManagerType) {
        dependencies.set(singleton: .fileManager, to: fileManager)
    }
    
    func createStorage() async throws {
        let storage: Storage = try! Storage.createForTesting(using: dependencies)
        dependencies.set(singleton: .storage, to: storage)
        
        try await storage.perform(migrations: SNMessagingKit.migrations)
        try await storage.write { db in
            try Identity(variant: .x25519PublicKey, data: Data(hex: TestConstants.publicKey)).insert(db)
            try Identity(variant: .x25519PrivateKey, data: Data(hex: TestConstants.privateKey)).insert(db)
            try Identity(variant: .ed25519PublicKey, data: Data(hex: TestConstants.edPublicKey)).insert(db)
            try Identity(variant: .ed25519SecretKey, data: Data(hex: TestConstants.edSecretKey)).insert(db)
            
            try SessionThread(
                id: "05\(TestConstants.publicKey)",
                variant: .contact,
                creationDateTimestamp: 1234567890
            ).insert(db)
            
            /// Need to clear any pre-created jobs to avoid `id` collisions with the job runner tests
            try Job.deleteAll(db)
        }
    }
    
    func createWarmedNetwork(
        customCachePath: String?,
        snodePoolCacheData: Data?
    ) throws {
        if let path: String = customCachePath {
            try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            
            if let data = snodePoolCacheData {
                switch serviceNetwork {
                    case .mainnet: try data.write(to: URL(fileURLWithPath: "\(path)/snode_pool"))
                    case .testnet: try data.write(to: URL(fileURLWithPath: "\(path)/snode_pool_testnet"))
                    case .devnet: throw NetworkError.invalidState
                }
            }
            
            if let enumerator = FileManager.default.enumerator(atPath: "\(LibSessionNetwork.snodeCachePath)/nodedb") {
                for maybeFilePath in enumerator.allObjects {
                    if let filePath = maybeFilePath as? String {
                        try? FileManager.default.copyItem(atPath: filePath, toPath: "\(path)/\(URL(fileURLWithPath: filePath).lastPathComponent)")
                    }
                }
            }
        }
        
        dependencies.set(
            singleton: .network,
            to: LibSessionNetwork(
                customCachePath: customCachePath,
                using: dependencies
            )
        )
        dependencies.warm(singleton: .network)
    }
    
    func createJobRunner() async {
        let jobRunner: JobRunner = JobRunner(isTestingJobRunner: true, using: dependencies)
        await jobRunner.setExecutor(MessageSendJob.self, for: .messageSend)
        await jobRunner.setExecutor(AttachmentUploadJob.self, for: .attachmentUpload)
        await jobRunner.setExecutor(AttachmentDownloadJob.self, for: .attachmentDownload)
        await jobRunner.appDidBecomeActive()
        dependencies.set(singleton: .jobRunner, to: jobRunner)
    }
    
    func createTestMessage(attempt: Int) -> VisibleMessage {
        VisibleMessage(text: "Resilience Test Message \(attempt)")
    }
    
    func createTestJob(
        for variant: ResilienceTest.Variant,
        attempt: Int,
        pathIndex: UInt8?
    ) async throws -> Job {
        let message: VisibleMessage = createTestMessage(attempt: attempt)
        
        return try await dependencies[singleton: .storage].write { [dependencies] db in
            let interaction: Interaction = try Interaction(
                threadId: "05\(TestConstants.publicKey)",
                threadVariant: .contact,
                authorId: "05\(TestConstants.publicKey)",
                variant: .standardOutgoing,
                body: message.text!,
                timestampMs: Int64(attempt),
                using: dependencies
            ).inserted(db)
            let messageSendJob: Job = Job(
                id: nil,
                failureCount: 0,
                variant: .messageSend,
                threadId: "05\(TestConstants.publicKey)",
                interactionId: interaction.id!,
                uniqueHashValue: nil,
                details: try! JSONEncoder()
                    .with(outputFormatting: .sortedKeys)    // Needed for deterministic comparison
                    .encode(
                        MessageSendJob.Details(
                            destination: .contact(publicKey: "05\(TestConstants.publicKey)"),
                            message: message,
                            ignorePermanentFailure: false
                        )
                    ),
                transientData: nil
            )
            
            /// If we don't want to upload then we can just return the `messageSendJob` here
            let fileSize: UInt
            
            switch variant {
                case .sendMessage: return messageSendJob
                case .downloadAttachment, .downloadAttachmentConcurrentDownloads:
                    let attachments: [SessionMessagingKit.Attachment] = try Attachment.fetchAll(db)
                    
                    guard
                        let attachment: SessionMessagingKit.Attachment = attachments.first,
                        let path: String = try? dependencies[singleton: .attachmentManager].path(
                            for: attachment.downloadUrl
                        )
                    else { throw StorageError.objectNotFound }
                    
                    /// Remove the uploaded attachment file just in case (since we plan to download it) and reset the attachment
                    /// state so we can re-download
                    try? FileManager.default.removeItem(atPath: path)
                    try Attachment
                        .filter(id: attachment.id)
                        .updateAll(
                            db,
                            Attachment.Columns.state.set(to: Attachment.State.pendingDownload)
                        )
                    
                    return Job(
                        id: nil,
                        failureCount: 0,
                        variant: .attachmentDownload,
                        threadId: "05\(TestConstants.publicKey)",
                        interactionId: interaction.id!,
                        uniqueHashValue: nil,
                        details: try! JSONEncoder()
                            .with(outputFormatting: .sortedKeys)    // Needed for deterministic comparison
                            .encode(
                                AttachmentDownloadJob.Details(
                                    attachmentId: attachment.id,
                                    desiredPathIndex: pathIndex
                                )
                            ),
                        transientData: nil
                    )
                    
                case .sendAttachment(let targetFileSize), .sendMessageWithAttachment(let targetFileSize):
                    fileSize = targetFileSize
                    break
            }
            
            let attachment: SessionMessagingKit.Attachment = try Attachment(
                id: "Resilience_Test_Attachment_\(attempt)",
                serverId: nil,
                variant: .standard,
                state: .uploading,
                contentType: "text/plain",
                byteCount: fileSize,
                creationTimestamp: dependencies.dateNow.timeIntervalSince1970,
                sourceFilename: nil,
                downloadUrl: dependencies[singleton: .attachmentManager].pendingUploadPath(
                    for: "Resilience_Test_Attachment_\(attempt)"
                ),
                width: nil,
                height: nil,
                duration: nil,
                isVisualMedia: false,
                isValid: true,
                encryptionKey: nil,
                digest: nil
            ).inserted(db)
            try InteractionAttachment(
                albumIndex: 0,
                interactionId: interaction.id!,
                attachmentId: attachment.id
            ).insert(db)
            
            switch variant {
                case .downloadAttachment, .downloadAttachmentConcurrentDownloads:
                    throw TestError.unableToEvaluateExpression
                
                case .sendMessage: return messageSendJob
                case .sendMessageWithAttachment:
                    /// When we want to send a message with an attachment we should just run the `MessageSendJob` as it
                    /// will schedule and run the `AttachmentUploadJob`
                    return messageSendJob
                
                case .sendAttachment:
                    return Job(
                        id: nil,
                        failureCount: 0,
                        variant: .attachmentUpload,
                        threadId: "05\(TestConstants.publicKey)",
                        interactionId: interaction.id!,
                        uniqueHashValue: nil,
                        details: try! JSONEncoder()
                            .with(outputFormatting: .sortedKeys)    // Needed for deterministic comparison
                            .encode(
                                AttachmentUploadJob.Details(
                                    messageSendJobId: -1,   /// Won't be related to a message send job
                                    attachmentId: attachment.id,
                                    desiredPathIndex: pathIndex
                                )
                            ),
                        transientData: nil
                    )
            }
        }
    }
    
    @discardableResult func runJob(
        _ job: Job,
        attempt: Int,
        usingJobRunner: Bool,
        onRetry: ((Job) -> Void)? = nil
    ) async throws -> Job {
        guard !usingJobRunner else {
            let insertedJob: Job? = try await dependencies[singleton: .storage].write { [dependencies] db in
                dependencies[singleton: .jobRunner].add(db, job: job)
            }
            
            /// If we failed to insert the job then error and fail the test
            guard let insertedJob else {
                throw StorageError.objectNotFound
            }
            
            return insertedJob
        }
        
        /// If we are running the job directly then we need to set it's `id` or the job may fail to run
        let targetJob: JobExecutor.Type
        let updatedJob: Job = job.with(id: Int64(attempt))
        
        switch updatedJob.variant {
            case .messageSend: targetJob = MessageSendJob.self
            case .attachmentUpload: targetJob = AttachmentUploadJob.self
            case .attachmentDownload: targetJob = AttachmentDownloadJob.self
            default: throw TestError.unableToEvaluateExpression
        }
        
        _ = try await targetJob.run(updatedJob,using: dependencies)
        
        return updatedJob
    }
}
