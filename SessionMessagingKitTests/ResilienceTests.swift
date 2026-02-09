// Copyright © 2026 Rangeproof Pty Ltd. All rights reserved.

import Testing
import Foundation
import Combine
import GRDB
import SessionUIKit
import SessionMessagingKit

@testable import SessionNetworkingKit
@testable import SessionUtilitiesKit

@Suite("Network Resilience Tests", .serialized)
struct MessageSendJobResilienceTests {
    var fixture: ResilienceTestFixture!
    var snodePoolCacheData: Data!
    
    init() async throws {
        fixture = try await ResilienceTestFixture.create()
        fixture.clearTestData()
//        LibSession.setupLogger(using: fixture.dependencies)
        fixture.dependencies.set(feature: .serviceNetwork, to: .testnet)
        fixture.dependencies.set(feature: .router, to: .sessionRouter)
        
        fixture.useLiveDateNow()
        try await fixture.createStorage()
        fixture.createWarmedNetwork(
            customCachePath: nil,
            snodePoolCacheData: nil
        )
        
        /// We need to ensure we have a snode pool (don't want fetching the snode pool to impact the timing results of the tests) so
        /// get the swarm for a pubkey which will fetch the snode pool if it's empty
        _ = try await fixture.dependencies[singleton: .network]
            .getSwarm(for: "05\(TestConstants.publicKey)")
        
        // TODO: [NETWORK REFACTOR] The `getSwarm` call won't work for SessionRouter because it just returns an empty value immediately, need to loop and wait
        for _ in 0..<8 {
            let result = try await fixture.dependencies[singleton: .network]
                .getSwarm(for: "05\(TestConstants.publicKey)")
            try? await Task.sleep(for: .seconds(1))
        }
        
        snodePoolCacheData = try Data(contentsOf: URL(fileURLWithPath: "\(LibSessionNetwork.snodeCachePath)/snode_pool_testnet"))
    }
    
    typealias Config = ResilienceTest.Config
    
    @Test(
        "Direct Request Resilience",
        .serialized,
        arguments: [
//            Config.directVariations(
//                variant: .sendMessage,
//                attempts: 500,
//                networkModes: [.newNetworkPerRequest, .shared],
//                behaviours: [
//                    .concurrent(num: 500),
//                    .concurrent(num: 50),
//                    .staggered(delayMs: 250)
//                ],
//                numPaths: [2, 1]
//            ),
//            Config.directVariations(
//                variant: .sendAttachment(fileSize: 5_000_000),
//                attempts: 250,
//                networkModes: [.newNetworkPerRequest, .shared],
//                behaviours: [
//                    .concurrent(num: 250),
//                    .concurrent(num: 50),
//                    .staggered(delayMs: 250)
//                ],
//                numPaths: [1]
//            ),
            Config.directVariations(
                nickname: "Direct Download",
                variant: .downloadAttachment(fileSize: (5 * 1024 * 1024)),
                attempts: 24,
                networkModes: [.shared],
                behaviours: [
                    .concurrent(num: 8),
                    .concurrent(num: 4),
                    .concurrent(num: 2),
                    .concurrent(num: 1)
                ],
                numPaths: [1],
                numStreams: [2]
            )
        ].flatMap { $0 }
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
            try await fixture.mockAppContext
                .when { $0.isMainApp }
                .thenReturn(config.numPaths > 1)
            
            fixture.createWarmedNetwork(
                customCachePath: fixture.customCachePath,
                snodePoolCacheData: snodePoolCacheData
            )
        }
        
        let parentFixture: ResilienceTestFixture = try await ResilienceTestFixture.create()
        parentFixture.prepareFeatures(for: config)
        try await parentFixture.createStorage()
        try await setupNetwork(for: parentFixture)
        
        /// Perform any preparation work
        testResult.setupResult = await Result(catching: {
            try await parentFixture.prepareParentFixtureForTestVariant(config.variant)
        })
        
        /// Now we can kick off the actual tests
        await withTaskGroup(of: (attempt: Int, latency: TimeInterval, result: Result<Void, Error>).self) { group in
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
                    
                    do {
                        switch config.mode {
                            case .shared: fixture = parentFixture
                            case .newNetworkPerRequest:
                                fixture = try await ResilienceTestFixture.create()
                                fixture.prepareFeatures(for: config)
                                fixture.setStorage(parentFixture.dependencies[singleton: .storage])
                                fixture.setFileManager(parentFixture.dependencies[singleton: .fileManager])
                                try await setupNetwork(for: fixture)
                        }
                        
                        job = try await fixture.createTestJob(for: config.variant, attempt: attempt)
                    }
                    catch { return (attempt, 0, .failure(error)) }
                    
                    let startTime: TimeInterval = fixture.dependencies.dateNow.timeIntervalSince1970
                    let result: Result<Void, Error> = await Result(catching: {
                        try await fixture.runJob(job, attempt: attempt, usingJobRunner: false)
                    })
                    let latency: TimeInterval = fixture.dependencies.dateNow.timeIntervalSince1970 - startTime
                    
                    switch config.mode {
                        case .shared: break
                        case .newNetworkPerRequest: await fixture.tearDown()
                    }
                    
                    return (attempt, latency, result)
                }
                
                /// Handle concurrenct limit if specified
                switch config.behaviour {
                    case .staggered: break
                    case .concurrent(let num), .concurrentStaggered(let num, _):
                        if num > 0 && attempt % num == 0 && attempt < config.numberOfAttempts {
                            for await (attempt, latency, result) in group {
                                testResult.recordResult(attempt: attempt, latency: latency, result: result)
                            }
                        }
                }
            }
            
            /// Collect remaining results
            for await (attempt, latency, result) in group {
                testResult.recordResult(attempt: attempt, latency: latency, result: result)
            }
            
            let endTime: TimeInterval = parentFixture.dependencies.dateNow.timeIntervalSince1970
            testResult.recordTiming(startTime: fullStartTime, endTime: endTime)
        }
        
        await parentFixture.tearDown()
        
        print(testResult.description)
        
        #expect(testResult.successRate >= 0.95, "Success rate should be at least 95%")
        #expect(testResult.averageLatency < config.variant.averageLatencyLimit, "Average latency should be under 5 seconds")
    }
    
    @Test(
        "Job Runner Resilience",
        .serialized,
//        arguments: [
//            Config.jobRunnerVariations(
//                variant: .messageAndAttachment(fileSize: 5_000_000),
//                attempts: 200,
//                behaviours: [
//                    .concurrent(num: 50),
//                    .staggered(delayMs: 250)
//                ],
//                numPaths: [2, 1]
//            )
//        ].flatMap { $0 }
        arguments: [1, 2, 3, 4, 5].flatMap { iteration in
            return [
                /// ----------------------------------------------------------------
                /// CANDIDATE A: The "Focused Tube"
                /// Architecture: 2 File Paths.
                /// Logic: Dump 1 file into it at once to saturate the bandwidth.
                /// ----------------------------------------------------------------
                Config.jobRunnerScenario(
                    nickname: "Candidate A (2 Streams / 1 Concurrent) - Run \(iteration)",
                    variant: .downloadAttachmentConcurrentDownloads(fileSize: (5 * 1024 * 1024)),
                    attempts: 24,
                    behaviour: .concurrent(num: 1),
                    numPaths: 2,
                    numStreams: 1
                ),
                
                /// ----------------------------------------------------------------
                /// CANDIDATE B: The "Focused Tube"
                /// Architecture: 1 Dedicated File Path.
                /// Logic: Dump 4 files into it at once to saturate the bandwidth.
                /// ----------------------------------------------------------------
                Config.jobRunnerScenario(
                    nickname: "Candidate B (1 Stream / 4 Concurrent) - Run \(iteration)",
                    variant: .downloadAttachmentConcurrentDownloads(fileSize: (5 * 1024 * 1024)),
                    attempts: 24,
                    behaviour: .concurrent(num: 4),
                    numPaths: 1,
                    numStreams: 1
                ),
                
                /// ----------------------------------------------------------------
                /// CANDIDATE C: The "Split Serial"
                /// Architecture: 2 Dedicated File Paths.
                /// Logic: 1 active download per path (2 Global). Minimizes contention.
                /// ----------------------------------------------------------------
                Config.jobRunnerScenario(
                    nickname: "Candidate C (4 Streams / 4 Concurrent) - Run \(iteration)",
                    variant: .downloadAttachmentConcurrentDownloads(fileSize: (5 * 1024 * 1024)),
                    attempts: 24,
                    behaviour: .concurrent(num: 4), // 2 Global = 1 Per Path
                    numPaths: 4,
                    numStreams: 1
                ),
                
                /// ----------------------------------------------------------------
                /// CANDIDATE D: The "Split Saturated"
                /// Architecture: 2 Dedicated File Paths.
                /// Logic: 4 active downloads per path (8 Global). Max theoretical throughput.
                /// ----------------------------------------------------------------
                Config.jobRunnerScenario(
                    nickname: "Candidate D (1 Streams / 2 Concurrent) - Run \(iteration)",
                    variant: .downloadAttachmentConcurrentDownloads(fileSize: (5 * 1024 * 1024)),
                    attempts: 24,
                    behaviour: .concurrent(num: 2),
                    numPaths: 1,
                    numStreams: 1
                ),
                
                /// ----------------------------------------------------------------
                /// CANDIDATE D: The "Split Saturated"
                /// Architecture: 2 Dedicated File Paths.
                /// Logic: 4 active downloads per path (8 Global). Max theoretical throughput.
                /// ----------------------------------------------------------------
                Config.jobRunnerScenario(
                    nickname: "Candidate E (2 Streams / 2 Concurrent) - Run \(iteration)",
                    variant: .downloadAttachmentConcurrentDownloads(fileSize: (5 * 1024 * 1024)),
                    attempts: 24,
                    behaviour: .concurrent(num: 2),
                    numPaths: 2,
                    numStreams: 1
                )
            ].flatMap { $0 }
        }
    )
    func testJobRunnerResilience(config: Config) async throws {
        var testResult: ResilienceTest = ResilienceTest(
            name: "Job Runner Resilience - \(config.testDescription)"
        )
        
        /// Setup the dependencies based on the config
        fixture.prepareFeatures(for: config)
        await fixture.createJobRunner()
        try await fixture.mockAppContext
            .when { $0.isMainApp }
            .thenReturn(config.numPaths > 1)
        fixture.createWarmedNetwork(
            customCachePath: nil,   /// The main fixture will use the proper snode pool
            snodePoolCacheData: nil /// Same as above
        )
        
        /// Perform any preparation work
        testResult.setupResult = await Result(catching: {
            try await fixture.prepareParentFixtureForTestVariant(config.variant)
        })
        print("RAWR Setup is done, start test")
        /// Now we can kick off the actual tests
        await withTaskGroup(of: (attempt: Int, latency: TimeInterval, result: Result<Void, Error>).self) { group in
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
                    
                    do {
                        job = try await fixture.createTestJob(for: config.variant, attempt: attempt)
                    }
                    catch { return (attempt, 0, .failure(error)) }
                        
                    let startTime: TimeInterval = fixture.dependencies.dateNow.timeIntervalSince1970
                    let result: Result<Void, Error> = await Result(catching: {
                        job = try await fixture.runJob(job, attempt: attempt, usingJobRunner: true)
                        
                        /// If we get a `deferred`error then the job was probably deferred waiting on an attachment
                        /// upload so wait briefly and then check the result again (limit the number of loops to avoid
                        /// running forever - allow `2m` max)
                        for _ in 0..<((2 * 60 * 1000) / 50) {
                            try? await Task.sleep(for: .milliseconds(50))
                            
                            let result: JobRunner.JobResult = await fixture
                                .dependencies[singleton: .jobRunner]
                                .awaitResult(for: job)
                            
                            switch result {
                                case .succeeded: return                 /// Leave the loop
                                case .failed(let error, _): throw error /// Fail immediately
                                case .deferred, .notFound: continue     /// Keep looping
                            }
                        }
                        
                        /// If we got to the end of the loop then error
                        throw NetworkError.explicit("Test Timeout")
                    })
                    
                    let latency: TimeInterval = fixture.dependencies.dateNow.timeIntervalSince1970 - startTime
                    return (attempt, latency, result)
                }
                
                /// Handle concurrenct limit if specified
                switch config.behaviour {
                    case .staggered: break
                    case .concurrent(let num), .concurrentStaggered(let num, _):
                        if num > 0 && attempt % num == 0 && attempt < config.numberOfAttempts {
                            for await (attempt, latency, result) in group {
                                testResult.recordResult(attempt: attempt, latency: latency, result: result)
                            }
                        }
                }
            }
            
            /// Collect remaining results
            for await (attempt, latency, result) in group {
                testResult.recordResult(attempt: attempt, latency: latency, result: result)
            }
            
            let endTime: TimeInterval = fixture.dependencies.dateNow.timeIntervalSince1970
            testResult.recordTiming(startTime: fullStartTime, endTime: endTime)
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
    
    static func create() async throws -> ResilienceTestFixture {
        let fixture: ResilienceTestFixture = ResilienceTestFixture()
        try await fixture.applyBaselineStubs()
        
        return fixture
    }
    
    func tearDown() async {
        let network: NetworkType = dependencies[singleton: .network]
        await (network as? LibSessionNetwork)?.shutdown()
        dependencies.remove(singleton: .network)
        
        await Task.yield()
        
        await dependencies[singleton: .jobRunner].stopAndClearJobs()
        _ = try? await dependencies[singleton: .storage].writeAsync { db in
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
    }
    
    private func applyBaselineAppContext() async throws {
        try await mockAppContext.when { $0.isValid }.thenReturn(true)
        try await mockAppContext.when { $0.isMainApp }.thenReturn(false)
    }
    
    private func applyBaselineNetwork() async throws {}
    private func applyBaselineJobRunner() async throws {}
    
    private func applyBaselineFileManager() async throws {
        try await mockFileManager.defaultInitialSetup()
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
    
    // MARK: - Test Helpers
    
    func prepareFeatures(for config: ResilienceTest.Config) {
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
        dependencies.set(feature: .router, to: .sessionRouter)
        dependencies.set(feature: .disableNetworkRequestTimeouts, to: config.disableTimeouts)
        dependencies.set(feature: .onionRequestMinStandardPaths, to: config.numPaths)
        dependencies.set(feature: .onionRequestMinFilePaths, to: config.numPaths)
        dependencies.set(feature: .quicMaxStandardStreams, to: config.numStreams)
        dependencies.set(feature: .quicMaxFileStreams, to: config.numStreams)
        
        switch config.behaviour {
            case .concurrent(let num), .concurrentStaggered(let num, _):
                dependencies.set(feature: .maxConcurrentFiles, to: num)
                
            case .staggered: dependencies.reset(feature: .maxConcurrentFiles)
        }
    }
    
    /// Prepare the parent fixture for a specific test variant (only want to do this once, and then share the instances with any
    /// child fixtures)
    func prepareParentFixtureForTestVariant(_ variant: ResilienceTest.Variant) async throws {
        var encryptionKey: Data?
        var digest: Data?
        
        /// Need to ensure the `MockFileManager` returns the right amount of content for the upload/download tests
        switch variant {
            case .sendMessage: break
            case .sendAttachment(let fileSize),
                .sendMessageWithAttachment(let fileSize),
                .downloadAttachment(let fileSize),
                .downloadAttachmentConcurrentDownloads(let fileSize):
                let fileData: Data = Data([UInt8](repeating: 1, count: Int(fileSize)))
                let encryptionResult = try dependencies[singleton: .crypto].tryGenerate(
                    .legacyEncryptedAttachment(plaintext: fileData)
                )
                encryptionKey = encryptionResult.encryptionKey
                digest = encryptionResult.digest
                
                await mockFileManager.removeMocksFor { try $0.contents(atPath: .any) }
                try await mockFileManager
                    .when { try $0.contents(atPath: .any) }
                    .thenReturn(encryptionResult.ciphertext)
        }
        
        /// Need to upload an attachment before we can test downloading
        switch variant {
            case .sendMessage, .sendAttachment, .sendMessageWithAttachment: break
            case .downloadAttachment(let fileSize),
                .downloadAttachmentConcurrentDownloads(let fileSize):
                /// Retry 3 times
                for index in 1...3 {
                    do {
                        try await dependencies[singleton: .storage].writeAsync { db in
                            try Interaction.deleteWhere(db, .deleteAll)
                            try Attachment.deleteAll(db)
                            try Job.deleteAll(db)
                        }
                        
                        let job: Job = try await createTestJob(
                            for: .sendAttachment(fileSize: fileSize),
                            attempt: 0
                        )
                        try await runJob(job, attempt: 0, usingJobRunner: false)
                        break
                    }
                    catch {
                        if index < 3 { continue }
                        
                        throw NetworkError.explicit("Initial attachment upload failed: \(error)")
                    }
                }
                
                /// Need to override the `encryptionKey` and `digest` of the attachment so that our mock encrypted
                /// data can be decrypted successfully
                try await dependencies[singleton: .storage].writeAsync { db in
                    try Attachment.updateAll(
                        db,
                        Attachment.Columns.encryptionKey.set(to: encryptionKey),
                        Attachment.Columns.digest.set(to: digest)
                    )
                }
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
        let storage: Storage = SynchronousStorage(
            customWriter: try! DatabaseQueue(),
            using: dependencies
        )
        dependencies.set(singleton: .storage, to: storage)
        
        try await storage.perform(migrations: SNMessagingKit.migrations)
        try await storage.writeAsync { db in
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
    ) {
        // TODO: Seems like we might need to keep `nodedb` and `nodedb_testnet` separate
        if let path: String = customCachePath {
            try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            
            if let data = snodePoolCacheData {
                try? data.write(to: URL(fileURLWithPath: "\(path)/snode_pool_testnet"))
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
    
    func createTestJob(for variant: ResilienceTest.Variant, attempt: Int) async throws -> Job {
        let message: VisibleMessage = createTestMessage(attempt: attempt)
        
        return try await dependencies[singleton: .storage].writeAsync { [dependencies] db in
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
                        details: try! JSONEncoder()
                            .with(outputFormatting: .sortedKeys)    // Needed for deterministic comparison
                            .encode(
                                AttachmentDownloadJob.Details(
                                    attachmentId: attachment.id
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
                        details: try! JSONEncoder()
                            .with(outputFormatting: .sortedKeys)    // Needed for deterministic comparison
                            .encode(
                                AttachmentUploadJob.Details(
                                    messageSendJobId: -1,   /// Won't be related to a message send job
                                    attachmentId: attachment.id
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
            let insertedJob: Job? = try await dependencies[singleton: .storage].writeAsync { [dependencies] db in
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

// MARK: - Types

enum NetworkMode {
    case newNetworkPerRequest
    case shared
    
    var name: String {
        switch self {
            case .newNetworkPerRequest: return "New Network Per Request"
            case .shared: return "Single Network"
        }
    }
}

struct ResilienceTest {
    let name: String
    var totalRequests: Int = 0
    var retryCount: Int = 0
    var startTime: TimeInterval = 0
    var endTime: TimeInterval = 0
    var setupResult: Result<Void, Error> = .success(())
    
    var results: [Int: TestResult] = [:]
    var failedResults: [TestResult] = []
    
    private var latencies: [TimeInterval] = []
    private var totalLatency: TimeInterval = 0
    var averageLatency: TimeInterval = 0
    var medianLatency: TimeInterval = 0
    var minLatency: TimeInterval = .greatestFiniteMagnitude
    var maxLatency: TimeInterval = 0
    
    var successCount: Int { results.count - failedResults.count }
    var failureCount: Int { failedResults.count }
    
    init(name: String) {
        self.name = name
    }
    
    mutating func recordResult(attempt: Int, latency: TimeInterval, result: Result<Void, Error>) {
        let testResult: TestResult = TestResult(attempt: attempt, result: result)
        totalRequests += 1
        results[attempt] = testResult
        updateLatency(latency)
        
        switch result {
            case .failure: failedResults.append(testResult)
            default: break
        }
    }
    
    mutating func recordRetry() {
        retryCount += 1
    }
    
    mutating func recordTiming(startTime: TimeInterval, endTime: TimeInterval) {
        self.startTime = startTime
        self.endTime = endTime
    }
    
    private mutating func updateLatency(_ latency: TimeInterval) {
        latencies.append(latency)
        latencies.sort()
        
        if latency < minLatency { minLatency = latency }
        if latency > maxLatency { maxLatency = latency }
        
        let count: Int = latencies.count
        totalLatency += latency
        averageLatency = (totalLatency / Double(latencies.count))
        
        if count % 2 == 1 {
            medianLatency = latencies[count / 2]
        } else {
            let midIndex: Int = (count / 2)
            let middleValuesSum: TimeInterval = (latencies[midIndex - 1] + latencies[midIndex])
            medianLatency = (middleValuesSum / 2.0)
        }
    }
    
    var successRate: Double {
        guard totalRequests > 0 else { return 0 }
        return Double(successCount) / Double(totalRequests)
    }
    
    var failureRate: Double {
        guard totalRequests > 0 else { return 0 }
        return Double(failureCount) / Double(totalRequests)
    }
    
    var description: String {
        /// If the setup failed then just output the error
        switch setupResult {
            case .success: break
            case .failure(let error):
                return """
                
                \(name):
                ------------------------
                Failure during setup due to error: \(error)
                """
        }
        
        /// Otherwise, we want to output the stats
        let errorBreakdown: String = {
            guard failureCount > 0 else { return "" }
            
            return "\n" + failedResults
                .map { result in
                    guard let error: Error = result.error else {
                        return "No error"
                    }
                    
                    switch error {
                        case NetworkError.timeout(let error, _):
                            if error.contains("path build") {
                                return "Timeout (Waiting for path build)"
                            }
                            
                            return "Timeout"
                            
                        case NetworkError.requestFailed(let error, _):
                            if error.starts(with: "Decryption failed") {
                                return "Decryption failed"
                            }
                            
                            return error
                            
                        case NetworkError.badRequest(let error, _): return "400 Bad Request \(error)"
                        case NetworkError.unauthorised: return "401 Unauthorised"
                        case NetworkError.forbidden: return "403 Forbidden"
                        case NetworkError.notFound: return "404 Not found"
                        case StorageServerError.clockOutOfSync: return "406/425 Clock out of sync"
                        case StorageServerError.unassociatedPubkey: return "421 Pubkey not associated with swarm"
                        case StorageServerError.rateLimited: return "429 Rate limited"
                        case NetworkError.internalServerError: return "500 Internal server error"
                        case NetworkError.badGateway: return "502 Bad gateway"
                        case StorageServerError.nodeNotFound: return "502 Bad gateway (Node not found)"
                        case NetworkError.serviceUnavailable: return "503 Service Unavailable"
                        case NetworkError.gatewayTimeout: return "504 Gateway timeout"
                        default: return "Unknown error type: \(error)"
                    }
                }
                .reduce(into: [:]) { result, next in
                    result[next, default: []].append(next)
                }
                .map { key, values in "  - \(key): \(values.count)" }
                .joined(separator: "\n")
        }()
        
        return """
        
        \(name):
        ------------------------
        Successes: \(successCount) (\(String(format: "%.2f%%", successRate * 100)))
        Failures: \(failureCount) (\(String(format: "%.2f%%", failureRate * 100)))\(errorBreakdown)
        Retries: \(retryCount)
        Latency:
          - Average: \(String(format: "%.3fs", averageLatency))
          - Median: \(String(format: "%.3fs", medianLatency))
          - Min: \(String(format: "%.3fs", minLatency))
          - Max: \(String(format: "%.3fs", maxLatency))
          - Total: \(String(format: "%.3fs", endTime - startTime))
        """
    }
}

extension ResilienceTest {
    enum Variant {
        case sendMessage
        case sendAttachment(fileSize: UInt)
        case sendMessageWithAttachment(fileSize: UInt)
        case downloadAttachment(fileSize: UInt)
        case downloadAttachmentConcurrentDownloads(fileSize: UInt)
        
        var averageLatencyLimit: TimeInterval {
            switch self {
                case .sendMessage: return 5
                case .sendAttachment(let fileSize),
                    .sendMessageWithAttachment(let fileSize),
                    .downloadAttachment(let fileSize),
                    .downloadAttachmentConcurrentDownloads(let fileSize):
                    /// 2 seconds per MB
                    return ((TimeInterval(fileSize) / 1024 / 1024) * 2)
            }
        }
    }
    
    enum SendBehaviour {
        case concurrent(num: Int)
        case concurrentStaggered(num: Int, delayMs: Int)
        case staggered(delayMs: Int)
        
        func description(with totalAttempts: Int) -> String {
            switch self {
                case .concurrent(let num):
                    return (num == 0 || num >= totalAttempts ?
                        "\(totalAttempts) at a time" :
                        "\(num) at a time"
                    )
                    
                case .concurrentStaggered(let num, let delay):
                    return (num == 0 || num >= totalAttempts ?
                        "\(totalAttempts) at a time, \(delay)ms between each" :
                        "\(num) at a time, \(delay)ms between each"
                    )
                    
                case .staggered(let delay):
                    return "\(delay)ms between each"
            }
        }
    }
    
    struct Config: CustomTestStringConvertible {
        let nickname: String?
        let mode: NetworkMode
        let numberOfAttempts: Int
        let variant: Variant
        let behaviour: SendBehaviour
        let numPaths: Int
        let numStreams: Int
        let disableTimeouts: Bool
        
        let simulateNetworkFailure: Bool
        let simulateStorageFailure: Bool
        let failureRate: Double // 0.0 to 1.0
        
        init(
            nickname: String?,
            mode: NetworkMode,
            attempts: Int,
            variant: Variant,
            behaviour: SendBehaviour,
            numPaths: Int,
            numStreams: Int,
            disableTimeouts: Bool,
            simulateNetworkFailure: Bool = false,
            simulateStorageFailure: Bool = false,
            failureRate: Double = 0
        ) {
            self.nickname = nickname
            self.mode = mode
            self.numberOfAttempts = attempts
            self.variant = variant
            self.behaviour = behaviour
            self.numPaths = numPaths
            self.numStreams = numStreams
            self.disableTimeouts = disableTimeouts
            self.simulateNetworkFailure = simulateNetworkFailure
            self.simulateStorageFailure = simulateStorageFailure
            self.failureRate = failureRate
        }
        
        var testDescription: String {
            let attemptString: String = {
                switch variant {
                    case .sendMessage where numberOfAttempts == 1: return "send 1 message"
                    case .sendMessage: return "send \(numberOfAttempts) messages"
                    case .sendAttachment(let fileSize) where numberOfAttempts == 1:
                        return "send 1 attachment (\(Format.fileSize(fileSize)))"
                        
                    case .sendAttachment(let fileSize):
                        return "send \(numberOfAttempts) attachments (\(Format.fileSize(fileSize)) each)"
                    
                    case .sendMessageWithAttachment(let fileSize) where numberOfAttempts == 1:
                        return "send 1 message with \(Format.fileSize(fileSize)) attachment"
                        
                    case .sendMessageWithAttachment(let fileSize):
                        return "send \(numberOfAttempts) messages (each with \(Format.fileSize(fileSize)) attachment)"
                        
                    case .downloadAttachment(let fileSize) where numberOfAttempts == 1:
                        return "download 1 attachment (\(Format.fileSize(fileSize)))"
                        
                    case .downloadAttachment(let fileSize):
                        return "download \(numberOfAttempts) attachments (\(Format.fileSize(fileSize)) each)"
                        
                    case .downloadAttachmentConcurrentDownloads(let fileSize) where numberOfAttempts == 1:
                        return "download 1 attachment (\(Format.fileSize(fileSize))), allow concurrent downloads"
                        
                    case .downloadAttachmentConcurrentDownloads(let fileSize):
                        return "download \(numberOfAttempts) attachments (\(Format.fileSize(fileSize)) each), allow concurrent downloads"
                }
            }()
            
            let prefix: String = (nickname.map { "[\($0)] " } ?? "")
            let info: String = [
                mode.name,
                (numPaths == 1 ? "1 path" : "\(numPaths) paths"),
                (numStreams == 1 ? "1 stream" : "\(numStreams) streams"),
                attemptString,
                behaviour.description(with: numberOfAttempts)
            ].joined(separator: ", ")
            let timeoutFlag: String = (disableTimeouts ? " [No Timeout]" : "")
            
            return prefix + info + timeoutFlag
        }
    }
    
    struct TestResult {
        let attempt: Int
        let success: Bool
        let error: Error?
        let errorString: String?
        
        init(attempt: Int, result: Result<Void, Error>) {
            self.attempt = attempt
            
            switch result {
                case .success:
                    self.success = true
                    self.error = nil
                    self.errorString = nil
                    
                case .failure(let error):
                    self.success = false
                    self.error = error
                    self.errorString = "\(error)"
            }
        }
    }
}

extension ResilienceTest.Config {
    enum DirectVariant {
        case sendMessage
        case sendAttachment(fileSize: UInt)
        case downloadAttachment(fileSize: UInt)
        
        var variant: ResilienceTest.Variant {
            switch self {
                case .sendMessage: return .sendMessage
                case .sendAttachment(let fileSize): return .sendAttachment(fileSize: fileSize)
                case .downloadAttachment(let fileSize): return .downloadAttachment(fileSize: fileSize)
            }
        }
    }
    
    static func directVariations(
        nickname: String? = nil,
        variant: ResilienceTest.Config.DirectVariant,
        attempts: Int,
        networkModes: [NetworkMode],
        behaviours: [ResilienceTest.SendBehaviour],
        numPaths: [Int],
        numStreams: [Int],
        disableTimeouts: Bool = false
    ) -> [ResilienceTest.Config] {
        return variations(
            nickname: nickname,
            variant: variant.variant,
            attempts: attempts,
            networkModes: networkModes,
            behaviours: behaviours,
            numPaths: numPaths,
            numStreams: numStreams,
            disableTimeouts: disableTimeouts
        )
    }
    
    static func jobRunnerVariations(
        nickname: String? = nil,
        variant: ResilienceTest.Variant,
        attempts: Int,
        behaviours: [ResilienceTest.SendBehaviour],
        numPaths: [Int],
        numStreams: [Int],
        disableTimeouts: Bool = false
    ) -> [ResilienceTest.Config] {
        return variations(
            nickname: nickname,
            variant: variant,
            attempts: attempts,
            networkModes: [.shared],
            behaviours: behaviours,
            numPaths: numPaths,
            numStreams: numStreams,
            disableTimeouts: disableTimeouts
        )
    }
    
    static func jobRunnerScenario(
        nickname: String? = nil,
        variant: ResilienceTest.Variant,
        attempts: Int,
        behaviour: ResilienceTest.SendBehaviour,
        numPaths: Int,
        numStreams: Int,
        disableTimeouts: Bool = false
    ) -> [ResilienceTest.Config] {
        return variations(
            nickname: nickname,
            variant: variant,
            attempts: attempts,
            networkModes: [.shared],
            behaviours: [behaviour],
            numPaths: [numPaths],
            numStreams: [numStreams],
            disableTimeouts: disableTimeouts
        )
    }
    
    private static func variations(
        nickname: String?,
        variant: ResilienceTest.Variant,
        attempts: Int,
        networkModes: [NetworkMode],
        behaviours: [ResilienceTest.SendBehaviour],
        numPaths: [Int],
        numStreams: [Int],
        disableTimeouts: Bool
    ) -> [ResilienceTest.Config] {
        return networkModes.flatMap { mode in
            numPaths.flatMap { numPaths in
                numStreams.flatMap { numStreams in
                    behaviours.map { behaviour in
                        ResilienceTest.Config(
                            nickname: nickname,
                            mode: mode,
                            attempts: attempts,
                            variant: variant,
                            behaviour: behaviour,
                            numPaths: numPaths,
                            numStreams: numStreams,
                            disableTimeouts: disableTimeouts
                        )
                    }
                }
            }
        }
    }
}
