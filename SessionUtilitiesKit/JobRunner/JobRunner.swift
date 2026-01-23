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
        createInstance: { dependencies, _ in JobRunner(using: dependencies) }
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
    func setSortDataRetriever(_ sortDataRetriever: JobSorterDataRetriever.Type, for type: JobQueue.QueueType) async
    
    // MARK: - State Management
    
    func registerStartupJobs(jobInfo: [JobRunner.StartupJobInfo])
    func appDidBecomeActive() async
    
    func jobsMatching(filters: JobRunner.Filters) async -> [JobQueue.JobQueueId: JobState]
    func deferCount(for jobId: Int64?, of variant: Job.Variant) async -> Int
    func stopAndClearPendingJobs(filters: JobRunner.Filters) async
    
    // MARK: - Job Scheduling
    
    @discardableResult nonisolated func add(
        _ db: ObservingDatabase,
        job: Job?,
        initialDependencies: [JobDependencyInitialInfo]
    ) -> Job?
    nonisolated func update(_ db: ObservingDatabase, job: Job) throws
    func getJobDependencyCoordinator() -> JobDependencyCoordinator
    nonisolated func addJobDependency(
        _ db: ObservingDatabase,
        _ info: JobDependencyInfo
    ) throws
    @discardableResult nonisolated func removeJobDependencies(
        _ db: ObservingDatabase,
        _ info: JobDependencyRemovalInfo,
        fromJobIds targetJobIds: Set<Int64>?
    ) -> Set<Int64>
    func tryFillCapacityForVariants(_ variants: Set<Job.Variant>) async
    func removePendingJob(_ jobId: Int64?) async
    
    // MARK: - Awaiting Job Resules
    
    func blockingQueueCompleted() async
    @discardableResult func finalResult(forFirstJobMatching filters: JobRunner.Filters) async throws -> JobRunner.JobResult
    func executionPhase(forFirstJobMatching filters: JobRunner.Filters) async -> JobState.ExecutionPhase?
}

// MARK: - JobRunnerType Convenience

public extension JobRunnerType {
    func firstJobMatching(filters: JobRunner.Filters) async -> JobState? {
        let results: [JobQueue.JobQueueId: JobState] = await jobsMatching(filters: filters)
        
        return results
            .sorted { lhs, rhs in lhs.key < rhs.key }
            .first?
            .value
    }
    
    func stopAndClearPendingJobs() async {
        await stopAndClearPendingJobs(filters: .matchingAll)
    }
    
    @discardableResult nonisolated func add(
        _ db: ObservingDatabase,
        job: Job?
    ) -> Job? {
        return add(db, job: job, initialDependencies: [])
    }
    
    @discardableResult nonisolated func removeJobDependencies(
        _ db: ObservingDatabase,
        _ info: JobDependencyRemovalInfo
    ) -> Set<Int64> {
        return removeJobDependencies(db, info, fromJobIds: nil)
    }
    
    func finalResult(for job: Job) async throws -> JobRunner.JobResult {
        guard let jobId: Int64 = job.id else { throw JobRunnerError.jobIdMissing }
        
        return try await finalResult(forFirstJobMatching: JobRunner.Filters(include: [.jobId(jobId)]))
    }
    
    func executionPhase(for job: Job) async -> JobState.ExecutionPhase? {
        guard let jobId: Int64 = job.id else { return nil }
        
        return await executionPhase(forFirstJobMatching: JobRunner.Filters(include: [.jobId(jobId)]))
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
    nonisolated private let jobDependencyCoordinator: JobDependencyCoordinator = JobDependencyCoordinator()
    
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
                jobVariants.remove(.failedMessageSends),
                jobVariants.remove(.failedAttachmentDownloads),
                jobVariants.remove(.failedGroupInvitesAndPromotions)
            ].compactMap { $0 },
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
                    jobVariants.remove(.garbageCollection),
                    jobVariants.remove(.retrieveDefaultOpenGroupRooms),
                    jobVariants.remove(.syncPushTokens),
                    jobVariants.remove(.checkForAppUpdates)
                ].compactMap { $0 },
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
    
    public func setExecutor(_ executor: JobExecutor.Type, for variant: Job.Variant) async {
        /// The blocking queue can run any job
        await blockingQueue.setExecutor(executor, for: variant)
        await queues[variant]?.setExecutor(executor, for: variant)
    }
    
    public func setSortDataRetriever(_ sortDataRetriever: JobSorterDataRetriever.Type, for type: JobQueue.QueueType) async {
        let uniqueQueues: Set<JobQueue> = Set(queues.values)
        
        await withTaskGroup(of: Void.self) { group in
            for queue in uniqueQueues {
                guard queue.type == type else { return }
                
                group.addTask {
                    await queue.setSortDataRetriever(sortDataRetriever)
                }
            }
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
        guard await dependencies[singleton: .storage].state.first(where: { $0 == .readyForUse }) != nil else {
            Log.error(.jobRunner, "Skipping startup due to invalid database.")
            return
        }
        
        /// If we have a running `sutdownBackgroundTask` then we want to cancel it as otherwise it can result in the database
        /// being suspended and us being unable to interact with it at all
        shutdownBackgroundTask?.cancel()
        shutdownBackgroundTask = nil
        appIsActive = true
        
        /// Retrieve and perform any blocking jobs first (we put this in a task so it can be cancelled if we want)
        blockingQueueTask = Task {
            let blockingJobs: [Job] = registeredStartupJobs
                .filter { $0.block }
                .map { Job(variant: $0.variant) }
                
            for job in blockingJobs {
                await blockingQueue.add(job, transientId: UUID())
            }
            
            /// Kick off the blocking queue and wait for it to be drained
            _ = await blockingQueue.start(drainOnly: true)
            _ = await blockingQueue.state.first(where: { $0 == .drained })
            Log.info(.jobRunner, "Blocking queue completed.")
        }
        
        /// Wait for the `blockingQueueTask` to complete
        await blockingQueueTask?.value
        blockingQueueTask = nil
        
        /// Ensure we can still run jobs (if `appIsActive` is no longer `true` then the app has gone into the background
        guard appIsActive else { return }
        
        /// Schedule any non-blocking startup jobs then start the queues
        let nonBlockingJobsByVariant: [Job.Variant: [Job]] = registeredStartupJobs
            .filter { !$0.block }
            .map { Job(variant: $0.variant) }
            .grouped(by: \.variant)
        
        for (variant, jobs) in nonBlockingJobsByVariant {
            guard let queue: JobQueue = queues[variant] else { continue }
            
            Task {
                for job in jobs {
                    await queue.add(job, transientId: UUID())
                }
            }
        }
        
        /// Start all non-blocking queues concurrently
        await withTaskGroup(of: Void.self) { group in
            let uniqueQueues: Set<JobQueue> = Set(queues.values).removing(blockingQueue)
            
            for queue in uniqueQueues {
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
        
        let uniqueQueues: Set<JobQueue> = Set(queues.values)
        
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
    ) async -> [JobQueue.JobQueueId: JobState] {
        var result: [JobQueue.JobQueueId: JobState] = [:]
        let uniqueQueues: Set<JobQueue> = Set(queues.values)
        
        await withTaskGroup(of: [JobQueue.JobQueueId: JobState].self) { group in
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
        job: Job?,
        initialDependencies: [JobDependencyInitialInfo]
    ) -> Job? {
        guard
            let savedJob: Job = validatedJob(db, job: job),
            let queueId: JobQueue.JobQueueId = JobQueue.JobQueueId(databaseId: savedJob.id)
        else { return nil }
        
        /// If there are any job dependencies related to this new job then we also need to add them to the queues
        var newJobDependencies: Set<JobDependency> = []
        
        if let jobId: Int64 = savedJob.id {
            /// Insert any initial dependencies
            if !initialDependencies.isEmpty {
                newJobDependencies.insert(
                    contentsOf: Set(initialDependencies.map { $0.create(with: jobId) })
                )
            }
            
            /// Retrieve any existing dependencies from the database (shouldn't be possible but just in case
            newJobDependencies.insert(
                contentsOf: ((try? JobDependency
                    .filter(
                        JobDependency.Columns.jobId == jobId ||
                        JobDependency.Columns.otherJobId == jobId
                    )
                    .fetchSet(db)) ?? [])
            )
        }
        
        /// Start the job runner if needed
        db.afterCommit { [weak self] in
            Task(priority: .high) { [weak self] in
                guard let self else { return }
                
                let allQueues: [Job.Variant: JobQueue] = await queues
                
                guard let queue: JobQueue = allQueues[savedJob.variant] else {
                    Log.critical(.jobRunner, "Attempted to add job \(savedJob) with variant \(savedJob.variant) which has no assigned queue.")
                    return
                }
                
                /// Add the job to it's queue
                await queue.add(savedJob)
                
                if !newJobDependencies.isEmpty {
                    /// Dependencies can exist across queues so we should try add them to each queue
                    let uniqueQueues: Set<JobQueue> = await Set(queues.values)
                    
                    await withTaskGroup(of: Void.self) { group in
                        for otherQueue in uniqueQueues {
                            group.addTask {
                                await otherQueue.addJobDependencies(
                                    queueId: queueId,
                                    jobDependencies: newJobDependencies
                                )
                            }
                        }
                    }
                }
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
    
    public func getJobDependencyCoordinator() -> JobDependencyCoordinator {
        return jobDependencyCoordinator
    }
    
    nonisolated public func addJobDependency(
        _ db: ObservingDatabase,
        _ info: JobDependencyInfo
    ) throws {
        let jobDependency: JobDependency = info.create()
        let queueId: JobQueue.JobQueueId = JobQueue.JobQueueId(databaseId: info.jobId)
        
        /// Since the `JobDependency` has nullable columns we can't prevent duplication using unique database constraints so
        /// we need to prevent them here
        guard !jobDependency.existsInDatabase(db) else { return }
        
        /// Save the dependency to the database
        try jobDependency.insert(db)
        jobDependencyCoordinator.markPendingAddition(queueId: queueId)
        
        /// Update the `JobState` for the newly added job dependency
        db.afterCommit { [weak self, jobDependencyCoordinator] in
            Task(priority: .high) { [weak self] in
                defer { jobDependencyCoordinator.clearPendingAddition(queueId: queueId) }
                guard let self else { return }
                
                let uniqueQueues: Set<JobQueue> = await Set(queues.values)
                
                await withTaskGroup(of: Void.self) { group in
                    for queue in uniqueQueues {
                        group.addTask {
                            await queue.addJobDependencies(
                                queueId: queueId,
                                jobDependencies: [jobDependency]
                            )
                        }
                    }
                }
            }
        }
    }
    
    nonisolated public func removeJobDependencies(
        _ db: ObservingDatabase,
        _ info: JobDependencyRemovalInfo,
        fromJobIds targetJobIds: Set<Int64>?
    ) -> Set<Int64> {
        let query: QueryInterfaceRequest<JobDependency> = {
            var result: QueryInterfaceRequest<JobDependency>
            
            switch info {
                case .job(let otherJobId):
                    result = JobDependency
                        .filter(JobDependency.Columns.variant == JobDependency.Variant.job)
                        .filter(JobDependency.Columns.otherJobId == otherJobId)
                    
                case .timestamp:
                    /// In this case we don't do an exact timestamp match because it would be a pain (and is unlikely we'd only
                    /// want to remove it for a given timestamp)
                    result = JobDependency
                        .filter(JobDependency.Columns.variant == JobDependency.Variant.timestamp)
                    
                case .configSync(let threadId):
                    result = JobDependency
                        .filter(JobDependency.Columns.variant == JobDependency.Variant.configSync)
                        .filter(JobDependency.Columns.threadId == threadId)
            }
            
            if let targetJobIds {
                result = result.filter(targetJobIds.contains(JobDependency.Columns.jobId))
            }
            
            return result
        }()
        
        let jobDependencies: [JobDependency] = ((try? query.fetchAll(db)) ?? [])
        
        /// If we found no dependencies then no need to run the remaining logic
        guard !jobDependencies.isEmpty else { return [] }
        
        _ = try? query.deleteAll(db)
        
        /// After the databse changes are completed we need to remove the dependencies from the jobs in memory
        db.afterCommit { [weak self] in
            Task { [weak self] in
                guard let self else { return }
                
                let uniqueQueues: Set<JobQueue> = await Set(queues.values)
                
                await withTaskGroup(of: Void.self) { group in
                    for queue in uniqueQueues {
                        group.addTask {
                            await queue.removeJobDependencies(jobDependencies)
                        }
                    }
                }
            }
        }
        
        /// Return the ids of the jobs which have dependencies
        return Set(jobDependencies.map { $0.jobId })
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
    
    public func removePendingJob(_ jobId: Int64?) async {
        guard let jobId else { return }
        
        let uniqueQueues: Set<JobQueue> = Set(queues.values)
        
        await withTaskGroup(of: Void.self) { group in
            for queue in uniqueQueues {
                group.addTask {
                    await queue.removePendingJob(jobId)
                }
            }
        }
    }
    
    // MARK: - Awaiting Job Results
    
    public func blockingQueueCompleted() async {
        await blockingQueueTask?.value
    }
    
    @discardableResult public func finalResult(forFirstJobMatching filters: JobRunner.Filters) async throws -> JobRunner.JobResult {
        let uniqueQueues: Set<JobQueue> = Set(queues.values)
        
        for queue in uniqueQueues {
            let jobs: [JobState] = await queue.sortedJobs(
                matching: filters,
                excludePendingJobsWhichCannotBeStarted: false
            )
            
            /// No need to do further processing if we found no jobs in this queue
            guard !jobs.isEmpty else { continue }
            
            /// Pick the first job based on phase - we generally want `running` > `pending` > `completed` when waiting on
            /// a job (this is because usually we will wait on a newly scheduled job and it's possible there is a previously completed
            /// job that matches the same filters which could incorrectly indicate that we can stop waiting
            let jobsByStatus: [JobState.ExecutionPhase: [JobState]] = jobs.grouped(by: \.executionState.phase)
            let targetState: JobState? = (
                jobsByStatus[.running]?.first ??
                jobsByStatus[.pending]?.first ??
                jobsByStatus[.completed]?.first
            )
            
            guard let targetJobQueueId: JobQueue.JobQueueId = targetState?.queueId else { continue }
            
            /// Await the first result from the stream
            return try await queue.finalResult(for: targetJobQueueId)
        }
        
        /// If we didn't find a job then indicate that
        throw JobRunnerError.noJobsMatchingFilters
    }
    
    public func executionPhase(forFirstJobMatching filters: JobRunner.Filters) async -> JobState.ExecutionPhase? {
        let uniqueQueues: Set<JobQueue> = Set(queues.values)
        
        for queue in uniqueQueues {
            let jobs: [JobState] = await queue.sortedJobs(
                matching: filters,
                excludePendingJobsWhichCannotBeStarted: false
            )
            
            /// No need to do further processing if we found no jobs in this queue
            guard !jobs.isEmpty else { continue }
            
            /// Pick the first job based on phase - we generally want `running` > `pending` > `completed` when waiting on
            /// a job (this is because usually we will wait on a newly scheduled job and it's possible there is a previously completed
            /// job that matches the same filters which could incorrectly indicate that we can stop waiting
            let jobsByStatus: [JobState.ExecutionPhase: [JobState]] = jobs.grouped(by: \.executionState.phase)
            let maybeTargetState: JobState? = (
                jobsByStatus[.running]?.first ??
                jobsByStatus[.pending]?.first ??
                jobsByStatus[.completed]?.first
            )
            
            guard let targetState: JobState = maybeTargetState else { continue }
            
            return targetState.executionState.phase
        }
        
        return nil
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

// MARK: - JobRunner.Filters

public extension JobRunner {
    struct Filters {
        public static let matchingAll: Filters = Filters(include: [], exclude: [])
        public static let matchingNone: Filters = Filters(include: [.never], exclude: [])
        
        public enum FilterType: Hashable {
            case executionPhase(JobState.ExecutionPhase)
            case jobId(Int64)
            case interactionId(Int64)
            case threadId(String)
            case variant(Job.Variant)
            case detailsData(Data)
            
            case never
            
            public static func details<T: Encodable>(_ value: T) throws -> FilterType {
                return .detailsData(
                    try JSONEncoder()
                        .with(outputFormatting: .sortedKeys)    /// Needed for deterministic comparison
                        .encode(value)
                )
            }
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
        
        public func matches(_ state: JobState) -> Bool {
            return matches([
                .executionPhase(state.executionState.phase),
                state.job.id.map { .jobId($0) },
                .variant(state.job.variant),
                state.job.threadId.map { .threadId($0) },
                state.job.interactionId.map { .interactionId($0) },
                state.job.details.map { .detailsData($0) }
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
            return (include.isEmpty || include.isSubset(of: filterSet))
        }
    }
}

// MARK: - JobRunner.JobResult

public extension JobRunner {
    enum JobResult: Equatable {
        case succeeded
        case failed(Error, isPermanent: Bool)
        case deferred
        
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

// MARK: - JobDependencyCoordinator

public final class JobDependencyCoordinator: @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var _pendingAdditions: [JobQueue.JobQueueId: Int] = [:]
    
    internal var pendingAdditions: [JobQueue.JobQueueId: Int] {
        lock.lock()
        defer { lock.unlock() }
        return _pendingAdditions
    }
    
    fileprivate func markPendingAddition(queueId: JobQueue.JobQueueId) {
        lock.lock()
        defer { lock.unlock() }
        _pendingAdditions[queueId, default: 0] += 1
    }
    
    fileprivate func clearPendingAddition(queueId: JobQueue.JobQueueId) {
        lock.lock()
        defer { lock.unlock() }
        if let count: Int = _pendingAdditions[queueId], count > 1 {
            _pendingAdditions[queueId] = count - 1
        }
        else {
            _pendingAdditions.removeValue(forKey: queueId)
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
}
