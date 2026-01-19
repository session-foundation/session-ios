// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import Combine
import GRDB

// MARK: - Singleton

public extension Singleton {
    static let jobRunner: SingletonConfig<JobRunnerType> = Dependencies.create(
        identifier: "jobRunner",
        createInstance: { dependencies in JobRunner(using: dependencies) }
    )
}

// MARK: - Log.Category

public extension Log.Category {
    static let jobRunner: Log.Category = .create("JobRunner", defaultLevel: .info)
}

// MARK: - JobRunnerType

public protocol JobRunnerType: Actor {
    // MARK: - Configuration
    
    func setExecutor(_ executor: JobExecutor.Type, for variant: Job.Variant) async
    
    // MARK: - State Management
    
    func registerStartupJobs(jobInfo: [JobRunner.StartupJobInfo])
    func appDidBecomeActive() async
    
    func jobsMatching(filters: JobRunner.Filters) async -> [Int64: Job]
    func deferCount(for jobId: Int64?, of variant: Job.Variant) async -> Int
    func stopAndClearPendingJobs(filters: JobRunner.Filters) async
    
    // MARK: - Job Scheduling
    
    @discardableResult nonisolated func add(_ db: ObservingDatabase, job: Job?) -> Job?
    nonisolated func update(_ db: ObservingDatabase, job: Job) throws
    nonisolated func addDependency(_ db: ObservingDatabase, forJobId jobId: Int64, on otherJobId: Int64) throws
    func tryFillCapacityForVariants(_ variants: Set<Job.Variant>) async
    func removePendingJob(_ job: Job?) async
    
    // MARK: - Awaiting Job Resules
    
    func awaitBlockingQueueCompletion() async
    func awaitResult(forFirstJobMatching filters: JobRunner.Filters) async -> JobRunner.JobResult
}

// MARK: - JobRunnerType Convenience

public extension JobRunnerType {
    func firstJobMatching(filters: JobRunner.Filters) async -> Job? {
        let results: [Int64: Job] = await jobsMatching(filters: filters)
        
        return results
            .sorted { lhs, rhs in lhs.key < rhs.key }
            .first?
            .value
    }
    
    func stopAndClearPendingJobs() async {
        await stopAndClearPendingJobs(filters: .matchingAll)
    }
    
    // MARK: -- Job Scheduling
    
    func awaitResult(for job: Job) async -> JobRunner.JobResult {
        guard let jobId: Int64 = job.id else { return .notFound }
        
        return await awaitResult(forFirstJobMatching: JobRunner.Filters(include: [.jobId(jobId)]))
    }
}

// MARK: - JobRunner

public actor JobRunner: JobRunnerType {
    // MARK: - Variables
    
    private let dependencies: Dependencies
    private let allowToExecuteJobs: Bool
    private let blockingQueue: JobQueue
    private var queues: [Job.Variant: JobQueue] = [:]
    private var registeredStartupJobs: [JobRunner.StartupJobInfo] = []
    
    private var appIsActive: Bool = false
    private var hasCompletedInitialBecomeActive: Bool = false
    
    private var blockingQueueTask: Task<Void, Never>?
    private var shutdownBackgroundTask: SessionBackgroundTask? = nil
    
    // MARK: - Initialization
    
    init(
        isTestingJobRunner: Bool = false,
        using dependencies: Dependencies
    ) {
        var jobVariants: Set<Job.Variant> = Job.Variant.allCases.asSet()
        
        self.dependencies = dependencies
        self.allowToExecuteJobs = (
            isTestingJobRunner || (
                dependencies[singleton: .appContext].isMainApp &&
                !SNUtilitiesKit.isRunningTests
            )
        )
        self.blockingQueue = JobQueue(
            type: .blocking,
            executionType: .serial,
            priority: .userInitiated,
            isTestingJobRunner: isTestingJobRunner,
            jobVariants: [
                .failedMessageSends,
                .failedAttachmentDownloads,
                .failedGroupInvitesAndPromotions
            ],
            using: dependencies
        )
        
        let queueList: [JobQueue] = [
            // MARK: -- Message Send Queue
            
            JobQueue(
                type: .messageSend,
                executionType: .concurrent(max: Int.max),
                priority: .medium,
                isTestingJobRunner: isTestingJobRunner,
                jobVariants: [
                    jobVariants.remove(.messageSend),
                    jobVariants.remove(.sendReadReceipts),
                    jobVariants.remove(.groupLeaving),
                    jobVariants.remove(.configurationSync),
                    jobVariants.remove(.groupInviteMember),
                    jobVariants.remove(.groupPromoteMember),
                    jobVariants.remove(.processPendingGroupMemberRemovals)
                ].compactMap { $0 },
                using: dependencies
            ),
            
            // MARK: -- Message Receive Queue
            
            JobQueue(
                type: .messageReceive,
                /// Explicitly serial as executing concurrently means message receives getting processed at different speeds which
                /// can result in:
                /// • Small batches of messages appearing in the UI before larger batches
                /// • Closed group messages encrypted with updated keys could start parsing before it's key update message has
                /// been processed (ie. guaranteed to fail)
                executionType: .serial,
                priority: .medium,
                isTestingJobRunner: isTestingJobRunner,
                jobVariants: [
                    jobVariants.remove(.messageReceive),
                    jobVariants.remove(.configMessageReceive)
                ].compactMap { $0 },
                using: dependencies
            ),
            
            // MARK: -- File Queue
            
            JobQueue(
                type: .file,
                executionType: .concurrent(max: 2),
                priority: .medium,
                isTestingJobRunner: isTestingJobRunner,
                jobVariants: [
                    jobVariants.remove(.attachmentUpload),
                    jobVariants.remove(.attachmentDownload),
                    jobVariants.remove(.displayPictureDownload),
                    jobVariants.remove(.reuploadUserDisplayPicture) // TODO: [JOBRUNNER] Ensure this is handled in prioritisation
                ].compactMap { $0 },
                using: dependencies
            ),
            
            // MARK: -- Expiration Update Queue
            
            JobQueue(
                type: .expirationUpdate,
                executionType: .concurrent(max: Int.max),
                priority: .medium,
                isTestingJobRunner: isTestingJobRunner,
                jobVariants: [
                    jobVariants.remove(.expirationUpdate),
                    jobVariants.remove(.getExpiration),
                    jobVariants.remove(.disappearingMessages)
                ].compactMap { $0 },
                using: dependencies
            ),
            
            // MARK: -- Startup Processes
            
            JobQueue(
                type: .startupProcesses,
                executionType: .concurrent(max: Int.max),
                priority: .utility,
                isTestingJobRunner: isTestingJobRunner,
                jobVariants: [
                    .garbageCollection,
                    .retrieveDefaultOpenGroupRooms,
                    .syncPushTokens,
                    .checkForAppUpdates
                ],
                using: dependencies
            )
        ]
        
        /// Remove the legacy variants then assert if there are any variants which haven't been allocated to a queue
        jobVariants.remove(._legacy_getSwarm)
        jobVariants.remove(._legacy_buildPaths)
        jobVariants.remove(._legacy_getSnodePool)
        jobVariants.remove(._legacy_notifyPushServer)
        assert(jobVariants.isEmpty, "The following variants haven't been assigned to a queue: \(jobVariants.map { "\($0)" }.joined(separator: ", "))")
            
        self.queues = (queueList + [blockingQueue]).reduce(into: [:]) { prev, next in
            next.jobVariants.forEach { variant in
                prev[variant] = next
            }
        }
    }
    
    // MARK: - Configuration
    
    public func setExecutor(_ executor: JobExecutor.Type, for variant: Job.Variant) {
        Task {
            /// The blocking queue can run any job
            await blockingQueue.setExecutor(executor, for: variant)
            await queues[variant]?.setExecutor(executor, for: variant)
        }
    }
    
    public func registerStartupJobs(jobInfo: [JobRunner.StartupJobInfo]) {
        registeredStartupJobs.append(contentsOf: jobInfo)
    }
    
    // MARK: - State Management
    
    public func appDidBecomeActive() async {
        /// If we aren't allowed to execute jobs then do nothing
        guard allowToExecuteJobs else { return }
        
        /// Wait until the database reports that it is ready (the `JobRunner` will try to retrieve jobs from it so no use starting until
        /// it is ready)
        _ = await dependencies[singleton: .storage].state.first(where: { $0 == .valid })
        
        /// If we have a running `sutdownBackgroundTask` then we want to cancel it as otherwise it can result in the database
        /// being suspended and us being unable to interact with it at all
        shutdownBackgroundTask?.cancel()
        shutdownBackgroundTask = nil
        appIsActive = true
        
        /// Retrieve and perform any blocking jobs first (we put this in a task so it can be cancelled if we want)
        blockingQueueTask = Task {
            let blockingJobs: [Job] = registeredStartupJobs
                .filter { $0.block }
                .map { Job(variant: $0.variant, behaviour: .recurring) }
                
            for (index, job) in blockingJobs.enumerated() {
                await blockingQueue.add(
                    job,
                    otherJobIdsItDependsOn: [],
                    variantsWithJobsDependantOnThisJob: [],
                    transientId: UUID()
                )
            }
            
            /// Kick off the blocking queue and wait for it to be drained
            _ = await blockingQueue.start(drainOnly: true)
            _ = await blockingQueue.state.first(where: { $0 == .drained })
        }
        
        /// Wait for the `blockingQueueTask` to complete
        await blockingQueueTask?.value
        
        /// Ensure we can still run jobs (if `appIsActive` is no longer `true` then the app has gone into the background
        guard appIsActive else { return }
        
        /// Schedule any non-blocking startup jobs then start the queues
        let nonBlockingJobsByVariant: [Job.Variant: [Job]] = registeredStartupJobs
            .filter { !$0.block }
            .map { Job(variant: $0.variant, behaviour: .recurring) }
            .grouped(by: \.variant)
        
        for (variant, jobs) in nonBlockingJobsByVariant {
            guard let queue: JobQueue = queues[variant] else { continue }
            
            Task {
                for job in jobs {
                    await queue.add(
                        job,
                        otherJobIdsItDependsOn: [],
                        variantsWithJobsDependantOnThisJob: [],
                        transientId: UUID()
                    )
                }
            }
        }
        
        /// Start all non-blocking queues concurrently
        await withTaskGroup(of: Void.self) { group in
            for queue in queues.values {
                guard queue != blockingQueue else { continue }
                
                group.addTask {
                    _ = await queue.start(drainOnly: false)
                }
            }
        }
        
        hasCompletedInitialBecomeActive = true
    }
    
    public func stopAndClearPendingJobs(filters: JobRunner.Filters) async {
        /// Inform the `JobRunner` that it can't start any queues (this is to prevent queues from rescheduling themselves while in the
        /// background, when the app restarts or becomes active the `JobRunner` will update this flag)
        appIsActive = false
        
        let uniqueQueues = Set(queues.values)
        
        await withTaskGroup(of: Void.self) { group in
            /// Stop any queues which match the filters
            for queue in uniqueQueues {
                group.addTask {
                    if await queue.matches(filters: filters) {
                        await queue.stopAndClear()
                    }
                }
            }
            
            /// Also handle blocking queue
            group.addTask {
                if await self.blockingQueue.matches(filters: filters) {
                    await self.blockingQueue.stopAndClear()
                }
            }
        }
    }
    
    private func cancelShutdown() {
        shutdownBackgroundTask?.cancel()
        shutdownBackgroundTask = nil
    }

    public func jobsMatching(
        filters: JobRunner.Filters
    ) async -> [Int64: Job] {
        var result: [Int64: Job] = [:]
        let uniqueQueues: Set<JobQueue> = Set(queues.values)
        
        await withTaskGroup(of: [Int64: Job].self) { group in
            for queue in uniqueQueues {
                group.addTask { await queue.jobsMatching(filters: filters) }
            }
            
            for await jobsForQueue in group {
                result.merge(jobsForQueue, uniquingKeysWith: { current, _ in current })
            }
        }
        
        return result
    }
    
    public func deferCount(for jobId: Int64?, of variant: Job.Variant) async -> Int {
        guard let jobId: Int64 = jobId else { return 0 }
        
        /// We should also check the `blockingQueue` just in case, so return the max value from both
        return max(
            await blockingQueue.deferCount(for: jobId),
            await (queues[variant]?.deferCount(for: jobId) ?? 0)
        )
    }
    
    // MARK: - Job Scheduling
    
    @discardableResult nonisolated public func add(
        _ db: ObservingDatabase,
        job: Job?
    ) -> Job? {
        guard let savedJob: Job = validatedJob(db, job: job) else { return nil }
        
        /// If there are any jobs dependant on this one then we should record them so they can be started when this one completes
        var idsThisJobDependsOn: Set<Int64> = []
        var jobVaraintsWithJobsDependantOnThisJob: Set<Job.Variant> = []
        
        if let jobId: Int64 = savedJob.id {
            let dependenciesForThisJob: Set<JobDependencies> = ((try? JobDependencies
                .filter(JobDependencies.Columns.jobId == jobId)
                .fetchSet(db)) ?? [])
            let otherJobsDependantOnThisJob: Set<JobDependencies> = ((try? JobDependencies
                .filter(JobDependencies.Columns.dependantId == jobId)
                .fetchSet(db)) ?? [])
            idsThisJobDependsOn = Set(dependenciesForThisJob.compactMap { $0.dependantId })
            jobVaraintsWithJobsDependantOnThisJob = ((try? Job
                .select(.variant)
                .filter(ids: Set(otherJobsDependantOnThisJob.map(\.jobId)))
                .asRequest(of: Job.Variant.self)
                .fetchSet(db)) ?? [])
        }
        
        /// Start the job runner if needed
        db.afterCommit { [weak self] in
            Task { [weak self] in
                guard let queue: JobQueue = await self?.queues[savedJob.variant] else {
                    Log.critical(.jobRunner, "Attempted to add job \(savedJob) with variant \(savedJob.variant) which has no assigned queue.")
                    return
                }
                
                await queue.add(
                    savedJob,
                    otherJobIdsItDependsOn: idsThisJobDependsOn,
                    variantsWithJobsDependantOnThisJob: jobVaraintsWithJobsDependantOnThisJob
                )
            }
        }
        
        return savedJob
    }
    
    nonisolated public func update(
        _ db: ObservingDatabase,
        job: Job
    ) throws {
        let updatedJob: Job = try job.upserted(db)
        
        /// Start the job runner if needed
        db.afterCommit { [weak self] in
            Task { [weak self] in
                guard let queue: JobQueue = await self?.queues[updatedJob.variant] else {
                    Log.critical(.jobRunner, "Attempted to update job \(updatedJob) with variant \(updatedJob.variant) which has no assigned queue.")
                    return
                }
                
                await queue.update(updatedJob)
            }
        }
    }
    
    nonisolated public func addDependency(
        _ db: ObservingDatabase,
        forJobId jobId: Int64,
        on otherJobId: Int64
    ) throws {
        /// Create the dependency between the jobs
        try JobDependencies(
            jobId: jobId,
            dependantId: otherJobId
        )
        .upsert(db)
        
        let dependantVariant: Job.Variant = try Job
            .filter(id: jobId)
            .select(.variant)
            .asRequest(of: Job.Variant.self)
            .fetchOne(db, orThrow: StorageError.objectNotFound)
        
        /// Update the state for both jobs
        db.afterCommit { [weak self] in
            Task { [weak self] in
                guard let self else { return }
                
                for queue in await queues.values {
                    if await queue.hasJob(jobId: jobId) {
                        await queue.addDependency(jobId: jobId, otherJobId: otherJobId)
                    }
                    
                    if await queue.hasJob(jobId: otherJobId) {
                        await queue.addDependantVariant(jobId: otherJobId, variant: dependantVariant)
                    }
                }
            }
        }
    }
    
    public func tryFillCapacityForVariants(_ variants: Set<Job.Variant>) async {
        let targetQueues: Set<JobQueue> = Set(variants.compactMap { queues[$0] })
        
        /// Load any pending jobs from the database (just in case we somehow lost a dependency) and then try to fill any available
        /// capacity the queue has
        for queue in targetQueues {
            await queue.loadPendingJobsFromDatabase()
            await queue.tryFillAvailableSlots()
        }
    }
    
    public func removePendingJob(_ job: Job?) async {
        guard let job: Job = job, let jobId: Int64 = job.id else { return }
        
        await queues[job.variant]?.removePendingJob(jobId)
    }
    
    // MARK: - Awaiting Job Results
    
    public func awaitBlockingQueueCompletion() async {
        await blockingQueueTask?.value
    }
    
    public func awaitResult(
        forFirstJobMatching filters: JobRunner.Filters
    ) async -> JobRunner.JobResult {
        let maybeStream: AsyncStream<JobRunner.JobResult>
        
        for queue in queues.values {
            let jobs: [Int64: Job] = await queue.jobsMatching(filters: filters)
            
            /// Sort by database insertion order
            guard
                let targetJob: Job = jobs
                    .sorted(by: { lhs, rhs in lhs.key < rhs.key })
                    .first?
                    .value,
                let targetJobId: Int64 = targetJob.id
            else { continue }
            
            /// Await the first result from the stream
            return await queue.awaitResult(for: targetJobId)
        }
        
        /// If we didn't find a job then indicate that
        return .notFound
    }
    
    nonisolated private func validatedJob(_ db: ObservingDatabase, job: Job?) -> Job? {
        guard let job: Job = job else { return nil }
        
        /// Job already exists, no need to do anything
        guard job.id == nil else { return job }
        
        do {
            let insertedJob: Job = try job.inserted(db)
            
            guard insertedJob.id != nil else {
                Log.info(.jobRunner, "Unable to add \(job) due to DB insertion failure.")
                return nil
            }
            
            return insertedJob
        } catch {
            Log.info(.jobRunner, "Unable to add \(job) due to error: \(error)")
            return nil
        }
    }
}

// MARK: - JobRunner.JobInfo

public extension JobRunner {
    struct JobInfo: Equatable, CustomDebugStringConvertible {
        public let id: Int64?
        public let variant: Job.Variant
        public let threadId: String?
        public let interactionId: Int64?
        public let nextRunTimestamp: TimeInterval
        public let queueIndex: Int?
        public let detailsData: Data?
        
        public var debugDescription: String {
            let dataDescription: String = detailsData
                .map { data in "Data(hex: \(data.toHexString()), \(data.bytes.count) bytes" }
                .defaulting(to: "nil")
            
            return """
            JobRunner.JobInfo(
              id: \(id.map { "\($0)" } ?? "nil"),
              variant: \(variant),
              threadId: \(threadId ?? "nil"),
              interactionId: \(interactionId.map { "\($0)" } ?? "nil"),
              nextRunTimestamp: \(nextRunTimestamp),
              queueIndex: \(queueIndex.map { "\($0)" } ?? "nil"),
              detailsData: \(dataDescription)
            )
            """
        }
    }
}

public extension JobRunner.JobInfo {
    init(job: Job, queueIndex: Int) {
        self.id = job.id
        self.variant = job.variant
        self.threadId = job.threadId
        self.interactionId = job.interactionId
        self.nextRunTimestamp = job.nextRunTimestamp
        self.queueIndex = queueIndex
        self.detailsData = job.details
    }
}

// MARK: - JobRunner.Filters

public extension JobRunner {
    struct Filters {
        public static let matchingAll: Filters = Filters(include: [], exclude: [])
        public static let matchingNone: Filters = Filters(include: [.never], exclude: [])
        
        public enum FilterType: Hashable {
            case status(JobStatus)
            case jobId(Int64)
            case interactionId(Int64)
            case threadId(String)
            case variant(Job.Variant)
            
            case never
        }
        
        let include: Set<FilterType>
        let exclude: Set<FilterType>
        
        // MARK: - Initialization
        
        public init(
            include: [FilterType] = [],
            exclude: [FilterType] = []
        ) {
            self.include = Set(include)
            self.exclude = Set(exclude)
        }
        
        // MARK: - Functions
        
        public func including(_ filters: FilterType...) -> Filters {
            return Filters(
                include: Array(include.union(Set(filters))),
                exclude: Array(exclude)
            )
        }
        
        public func excluding(_ filters: FilterType...) -> Filters {
            return Filters(
                include: Array(include),
                exclude: Array(exclude.union(Set(filters)))
            )
        }
        
        public func matches(_ job: Job) -> Bool {
            return matches([
                job.id.map { .jobId($0) },
                .variant(job.variant),
                job.threadId.map { .threadId($0) },
                job.interactionId.map { .interactionId($0) }
            ].compactMap { $0 })
        }
        
        public func matches(_ filters: [FilterType]) -> Bool {
            /// If the filter is `.matchingAll`, we can return early
            if include.isEmpty && exclude.isEmpty {
                return true
            }
            
            let filterSet: Set<FilterType> = Set(filters)
            
            /// If the job is explicitly excluded then it doesn't match the filters
            if !exclude.intersection(filterSet).isEmpty {
                return false
            }
            
            /// If `include` is empty, or the job is explicitly included then it does match the filters
            return (include.isEmpty || !include.intersection(filterSet).isEmpty)
        }
    }
}

// MARK: - JobRunner.JobStatus

public extension JobRunner {
    struct JobStatus: OptionSet, Hashable {
        public let rawValue: UInt8
        
        public init(rawValue: UInt8) {
            self.rawValue = rawValue
        }
        
        public static let pending: JobStatus = JobStatus(rawValue: 1 << 0)
        public static let running: JobStatus = JobStatus(rawValue: 1 << 1)
        public static let completed: JobStatus = JobStatus(rawValue: 1 << 2)
        
        public static let any: JobStatus = [ .pending, .running, .completed ]
    }
}

public extension JobRunner {
    enum JobResult: Equatable {
        case succeeded
        case failed(Error, Bool)
        case deferred
        case notFound
        
        public static func == (lhs: JobRunner.JobResult, rhs: JobRunner.JobResult) -> Bool {
            switch (lhs, rhs) {
                case (.succeeded, .succeeded): return true
                case (.failed(let lhsError, let lhsPermanent), .failed(let rhsError, let rhsPermanent)):
                    return (
                        // Not a perfect solution but should be good enough
                        "\(lhsError)" == "\(rhsError)" &&
                        lhsPermanent == rhsPermanent
                    )
                    
                case (.deferred, .deferred): return true
                default: return false
            }
        }
    }
}

// MARK: - JobRunner.StartupJobInfo

public extension JobRunner {
    struct StartupJobInfo {
        let variant: Job.Variant
        let block: Bool
        
        public init(
            variant: Job.Variant,
            block: Bool
        ) {
            self.variant = variant
            self.block = block
        }
    }
}

// MARK: - Formatting

private extension String.StringInterpolation {
    mutating func appendInterpolation(_ job: Job) {
        appendLiteral("\(job.variant) job (id: \(job.id ?? -1))")
    }
    
    mutating func appendInterpolation(_ job: Job?) {
        switch job {
            case .some(let job): appendInterpolation(job)
            case .none: appendLiteral("null job")
        }
    }
}

extension String.StringInterpolation {
    mutating func appendInterpolation(_ variant: Job.Variant?) {
        appendLiteral(variant.map { "\($0)" } ?? "unknown")
    }
    
    mutating func appendInterpolation(_ behaviour: Job.Behaviour?) {
        appendLiteral(behaviour.map { "\($0)" } ?? "unknown")
    }
}
