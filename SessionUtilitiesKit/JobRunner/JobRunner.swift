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
    
    func appDidFinishLaunching() async
    func appDidBecomeActive() async
    
    func jobInfoFor(state: JobRunner.JobState, filters: JobRunner.Filters) async -> [Int64: JobRunner.JobInfo]
    func deferCount(for jobId: Int64?, of variant: Job.Variant) async -> Int
    func stopAndClearPendingJobs(filters: JobRunner.Filters) async
    
    // MARK: - Job Scheduling
    
    @discardableResult nonisolated func add(
        _ db: ObservingDatabase,
        job: Job?,
        dependantJob: Job?,
        canStartJob: Bool
    ) -> Job?
    @discardableResult nonisolated func upsert(
        _ db: ObservingDatabase,
        job: Job?,
        canStartJob: Bool
    ) -> Job?
    @discardableResult nonisolated func insert(
        _ db: ObservingDatabase,
        job: Job?,
        before otherJob: Job
    ) -> (Int64, Job)?
    
    func enqueueDependenciesIfNeeded(_ jobs: [Job]) async
    func removePendingJob(_ job: Job?) async
    
    // MARK: - Awaiting Job Resules
    
    func awaitBlockingQueueCompletion() async
    func didCompleteJob(id: Int64, result: JobRunner.JobResult)
    func awaitResult(forFirstJobMatching filters: JobRunner.Filters, in state: JobRunner.JobState) async -> JobRunner.JobResult
    
    // MARK: - Recurring Jobs
    
    func registerRecurringJobs(scheduleInfo: [JobRunner.ScheduleInfo])
    func scheduleRecurringJobsIfNeeded() async
}

// MARK: - JobRunnerType Convenience

public extension JobRunnerType {
    func allJobInfo() async -> [Int64: JobRunner.JobInfo] {
        return await jobInfoFor(state: .any, filters: .matchingAll)
    }

    func jobInfoFor(filters: JobRunner.Filters) async -> [Int64: JobRunner.JobInfo] {
        return await jobInfoFor(state: .any, filters: filters)
    }

    func jobInfoFor(state: JobRunner.JobState) async -> [Int64: JobRunner.JobInfo] {
        return await jobInfoFor(state: state, filters: .matchingAll)
    }
    
    func isCurrentlyRunning(_ job: Job?) async -> Bool {
        guard let jobId: Int64 = job?.id else { return false }
        
        let jobResults: [Int64: JobRunner.JobInfo] = await jobInfoFor(
            state: .running,
            filters: JobRunner.Filters(
                include: [.jobId(jobId)],
                exclude: []
            )
        )
        
        return !jobResults.isEmpty
    }
    
    func stopAndClearPendingJobs() async {
        await stopAndClearPendingJobs(filters: .matchingAll)
    }
    
    // MARK: -- Job Scheduling
    
    @discardableResult nonisolated func add(_ db: ObservingDatabase, job: Job?, canStartJob: Bool) -> Job? {
        return add(db, job: job, dependantJob: nil, canStartJob: canStartJob)
    }
    
    func awaitResult(forFirstJobMatching filters: JobRunner.Filters) async -> JobRunner.JobResult {
        return await awaitResult(forFirstJobMatching: filters, in: .any)
    }
    
    func awaitResult(for job: Job) async -> JobRunner.JobResult {
        guard let jobId: Int64 = job.id else { return .notFound }
        
        return await awaitResult(forFirstJobMatching: JobRunner.Filters(include: [.jobId(jobId)]), in: .any)
    }
}

// MARK: - JobRunner

public actor JobRunner: JobRunnerType {
    // MARK: - Variables
    
    private let dependencies: Dependencies
    private let allowToExecuteJobs: Bool
    private let blockingQueue: JobQueue
    private var queues: [Job.Variant: JobQueue] = [:]
    private var registeredRecurringJobs: [JobRunner.ScheduleInfo] = []
    
    private var appReadyToStartQueues: Bool = false
    private var appHasBecomeActive: Bool = false
    private var hasCompletedInitialBecomeActive: Bool = false
    
    private var blockingQueueTask: Task<Void, Never>?
    private var shutdownBackgroundTask: SessionBackgroundTask? = nil
    private var resultStreams: [Int64: CancellationAwareAsyncStream<JobRunner.JobResult>] = [:]
    
    private var canStartNonBlockingQueues: Bool {
        (blockingQueueTask == nil || blockingQueueTask?.isCancelled == true) &&
        appHasBecomeActive
    }
    
    // MARK: - Initialization
    
    init(
        isTestingJobRunner: Bool = false,
        variantsToExclude: [Job.Variant] = [],
        using dependencies: Dependencies
    ) {
        var jobVariants: Set<Job.Variant> = Job.Variant.allCases
            .filter { !variantsToExclude.contains($0) }
            .asSet()
        
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
            jobVariants: [],
            using: dependencies
        )
        
        let queueList: [JobQueue] = [
            // MARK: -- Message Send Queue
            
            JobQueue(
                type: .messageSend,
                executionType: .concurrent, /// Allow as many jobs to run at once as supported by the device
                priority: .medium,
                isTestingJobRunner: isTestingJobRunner,
                jobVariants: [
                    jobVariants.remove(.attachmentUpload),
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
            
            // MARK: -- Attachment Download Queue
            
            JobQueue(
                type: .attachmentDownload,
                executionType: .serial,
                priority: .utility,
                isTestingJobRunner: isTestingJobRunner,
                jobVariants: [
                    jobVariants.remove(.attachmentDownload)
                ].compactMap { $0 },
                using: dependencies
            ),
            
            // MARK: -- Expiration Update Queue
            
            JobQueue(
                type: .expirationUpdate,
                executionType: .concurrent, /// Allow as many jobs to run at once as supported by the device
                priority: .medium,
                isTestingJobRunner: isTestingJobRunner,
                jobVariants: [
                    jobVariants.remove(.expirationUpdate),
                    jobVariants.remove(.getExpiration),
                    jobVariants.remove(.disappearingMessages),
                    jobVariants.remove(.checkForAppUpdates) /// Don't want this to block other jobs
                ].compactMap { $0 },
                using: dependencies
            ),
            
            // MARK: -- Display Picture Download Queue
            
            JobQueue(
                type: .displayPictureDownload,
                executionType: .serial,
                priority: .utility,
                isTestingJobRunner: isTestingJobRunner,
                jobVariants: [
                    jobVariants.remove(.displayPictureDownload)
                ].compactMap { $0 },
                using: dependencies
            ),
            
            // MARK: -- General Queue
            
            JobQueue(
                type: .general(number: 0),
                executionType: .serial,
                priority: .utility,
                isTestingJobRunner: isTestingJobRunner,
                jobVariants: Array(jobVariants),
                using: dependencies
            )
        ]
            
        self.queues = queueList.reduce(into: [:]) { prev, next in
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
    
    // MARK: - State Management
    
    public func appDidFinishLaunching() async {
        /// Flag that the JobRunner can start it's queues
        appReadyToStartQueues = true
        
        /// **Note:** `appDidBecomeActive` will run on first launch anyway so we can leave those jobs out and can wait until
        /// then to start the JobRunner
        let jobsToRun: (blocking: [Job], nonBlocking: [Job]) = ((try? await dependencies[singleton: .storage]
            .readAsync { db in
                let blockingJobs: [Job] = try Job
                    .filter(
                        [
                            Job.Behaviour.recurringOnLaunch,
                            Job.Behaviour.runOnceNextLaunch
                        ].contains(Job.Columns.behaviour)
                    )
                    .filter(Job.Columns.shouldBlock == true)
                    .order(
                        Job.Columns.priority.desc,
                        Job.Columns.id
                    )
                    .fetchAll(db)
                let nonblockingJobs: [Job] = try Job
                    .filter(
                        [
                            Job.Behaviour.recurringOnLaunch,
                            Job.Behaviour.runOnceNextLaunch
                        ].contains(Job.Columns.behaviour)
                    )
                    .filter(Job.Columns.shouldBlock == false)
                    .order(
                        Job.Columns.priority.desc,
                        Job.Columns.id
                    )
                    .fetchAll(db)
                
                return (blockingJobs, nonblockingJobs)
            }) ?? ([], []))
        
        /// Add any blocking jobs
        await blockingQueue.addJobsFromLifecycle(
            jobsToRun.blocking.map { job -> Job in
                guard job.behaviour == .recurringOnLaunch else { return job }
                
                /// If the job is a `recurringOnLaunch` job then we reset the `nextRunTimestamp` value on the instance
                /// because the assumption is that `recurringOnLaunch` will run a job regardless of how many times it
                /// previously failed
                return job.with(nextRunTimestamp: 0)
            },
            canStart: false
        )
        
        /// Add any non-blocking jobs
        let jobsByVariant: [Job.Variant: [Job]] = jobsToRun.nonBlocking.grouped(by: \.variant)
        
        for (variant, jobs) in jobsByVariant {
            if let queue: JobQueue = queues[variant] {
                await queue.addJobsFromLifecycle(
                    jobs.map { job -> Job in
                        guard job.behaviour == .recurringOnLaunch else { return job }
                        
                        /// If the job is a `recurringOnLaunch` job then we reset the `nextRunTimestamp` value on the instance
                        /// because the assumption is that `recurringOnLaunch` will run a job regardless of how many times it
                        /// previously failed
                        return job.with(nextRunTimestamp: 0)
                    },
                    canStart: false
                )
            }
        }
        
        /// Create and store the task for the blocking queue, start the `blockingQueue` and, once it's complete, trigger the
        /// `startNonBlockingQueues` function
        blockingQueueTask = Task {
            let canStart: Bool = (allowToExecuteJobs && appReadyToStartQueues)
            
            _ = await blockingQueue.start(canStart: canStart, drainOnly: false)
            await self.startNonBlockingQueues()
        }
    }
    
    public func appDidBecomeActive() async {
        /// Flag that the JobRunner can start it's queues and start queueing non-launch jobs
        appReadyToStartQueues = true
        appHasBecomeActive = true
        
        /// If we have a running `sutdownBackgroundTask` then we want to cancel it as otherwise it can result in the database
        /// being suspended and us being unable to interact with it at all
        shutdownBackgroundTask?.cancel()
        shutdownBackgroundTask = nil
        
        /// Retrieve any jobs which should run when becoming active
        let hasCompletedInitialBecomeActive: Bool = self.hasCompletedInitialBecomeActive
        let jobsToRun: [Job] = ((try? await dependencies[singleton: .storage]
            .readAsync { db in
                return try Job
                    .filter(Job.Columns.behaviour == Job.Behaviour.recurringOnActive)
                    .order(
                        Job.Columns.priority.desc,
                        Job.Columns.id
                    )
                    .fetchAll(db)
            }) ?? [] )
            .filter { hasCompletedInitialBecomeActive || !$0.shouldSkipLaunchBecomeActive }
        
        /// Add and start any non-blocking jobs (if there are no blocking jobs)
        ///
        /// We only want to trigger the queue to start once so we need to consolidate the queues to list of jobs (as queues can handle
        /// multiple job variants), this means that `onActive` jobs will be queued before any standard jobs
        let jobsByVariant: [Job.Variant: [Job]] = jobsToRun.grouped(by: \.variant)
        for (variant, jobs) in jobsByVariant {
            guard let queue: JobQueue = queues[variant] else { continue }
            
            Task { await queue.addJobsFromLifecycle(jobs, canStart: false) }
        }
        
        /// If the blocking queue isn't running, it's safe to start the non-blocking ones
        if blockingQueueTask == nil || blockingQueueTask?.isCancelled == true {
            Task { await self.startNonBlockingQueues() }
        }
        
        self.hasCompletedInitialBecomeActive = true
    }
    
    private func startNonBlockingQueues() async {
        guard canStartNonBlockingQueues else { return }
        
        let canStart: Bool = (allowToExecuteJobs && appReadyToStartQueues)
        
        /// Start all non-blocking queues concurrently
        await withTaskGroup(of: Void.self) { group in
            for queue in queues.values {
                group.addTask {
                    _ = await queue.start(canStart: canStart, drainOnly: false)
                }
            }
        }
    }
    
    public func stopAndClearPendingJobs(filters: JobRunner.Filters) async {
        /// Inform the `JobRunner` that it can't start any queues (this is to prevent queues from rescheduling themselves while in the
        /// background, when the app restarts or becomes active the `JobRunner` will update this flag)
        appReadyToStartQueues = false
        appHasBecomeActive = false
        
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

    public func jobInfoFor(
        state: JobRunner.JobState,
        filters: JobRunner.Filters
    ) async -> [Int64: JobRunner.JobInfo] {
        var allInfo: [Int64: JobRunner.JobInfo] = [:]
        let uniqueQueues: Set<JobQueue> = Set(queues.values).union([blockingQueue])
        
        await withTaskGroup(of: [Int64: JobRunner.JobInfo].self) { group in
            for queue in uniqueQueues {
                if state.contains(.running) {
                    group.addTask { await queue.infoForAllCurrentlyRunningJobs() }
                }
                
                if state.contains(.pending) {
                    group.addTask { await queue.infoForAllPendingJobs() }
                }
            }
            
            for await infoDict in group {
                allInfo.merge(infoDict, uniquingKeysWith: { (current, _) in current })
            }
        }
        
        /// If the filter is `.matchingAll`, we can return early
        if filters.include.isEmpty && filters.exclude.isEmpty {
            return allInfo
        }
        
        /// Apply the filters to the collected results
        return allInfo.filter { _, jobInfo in
            filters.matches(jobInfo)
        }
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
        dependantJob: Job?,
        canStartJob: Bool
    ) -> Job? {
        guard let savedJob: Job = validatedJob(db, job: job) else { return nil }
        
        /// If we are adding a job that's dependant on another job then create the dependency between them
        if let jobId: Int64 = savedJob.id, let dependantJobId: Int64 = dependantJob?.id {
            try? JobDependencies(
                jobId: jobId,
                dependantId: dependantJobId
            )
            .insert(db)
        }
        
        /// Start the job runner if needed
        db.afterCommit { [weak self] in
            Task { [weak self] in await self?.addJobToQueue(savedJob, canStartJob: canStartJob) }
        }
        
        return savedJob
    }
    
    @discardableResult nonisolated public func upsert(
        _ db: ObservingDatabase,
        job: Job?,
        canStartJob: Bool
    ) -> Job? {
        guard let savedJob: Job = validatedJob(db, job: job) else { return nil }
        
        db.afterCommit { [weak self] in
            Task { [weak self] in await self?.upsertJobInQueue(savedJob, canStartJob: canStartJob) }
        }
        
        return savedJob
    }
    
    @discardableResult nonisolated public func insert(
        _ db: ObservingDatabase,
        job: Job?,
        before otherJob: Job
    ) -> (Int64, Job)? {
        switch job?.behaviour {
            case .recurringOnActive, .recurringOnLaunch, .runOnceNextLaunch,
                .runOnceAfterConfigSyncIgnoringPermanentFailure:
                Log.info(.jobRunner, "Attempted to insert \(job) before the current one even though it's behaviour is \(job?.behaviour)")
                return nil
                
            default: break
        }
        
        guard
            let savedJob: Job = validatedJob(db, job: job),
            let savedJobId: Int64 = savedJob.id
        else { return nil }
        
        db.afterCommit { [weak self] in
            Task { [weak self] in await self?.insertJobIntoQueue(savedJob, before: otherJob) }
        }
        
        return (savedJobId, savedJob)
    }
    
    private func addJobToQueue(_ job: Job, canStartJob: Bool) async {
        guard canAddToQueue(job) else { return }
        guard let queue: JobQueue = queues[job.variant] else {
            Log.critical(.jobRunner, "Attempted to add job \(job) with variant \(job.variant) which has no assigned queue.")
            return
        }
        
        await queue.add(job, canStart: canStartJob && allowToExecuteJobs && appReadyToStartQueues)
    }
    
    private func upsertJobInQueue(_ job: Job, canStartJob: Bool) async {
        guard canAddToQueue(job) else { return }
        guard let queue: JobQueue = queues[job.variant] else {
            Log.critical(.jobRunner, "Attempted to upsert job \(job) with variant \(job.variant) which has no assigned queue.")
            return
        }
        
        await queue.upsert(job, canStart: canStartJob && allowToExecuteJobs && appReadyToStartQueues)
    }
    
    private func insertJobIntoQueue(_ job: Job, before otherJob: Job) async {
        guard let queue: JobQueue = queues[otherJob.variant] else {
            Log.critical(.jobRunner, "Attempted to insert job before \(otherJob) with variant \(otherJob.variant) which has no assigned queue.")
            return
        }
        
        await queue.insert(job, before: otherJob)
    }
    
    /// Job dependencies can be quite messy as they might already be running or scheduled on different queues from the related job, this could result
    /// in some odd inter-dependencies between the JobQueues. Instead of this we want all jobs to run on their original assigned queues (so the
    /// concurrency rules remain consistent and easy to reason with), the only downside to this approach is serial queues could potentially be blocked
    /// waiting on unrelated dependencies to be run as this method will insert jobs at the start of the `pendingJobsQueue`
    public func enqueueDependenciesIfNeeded(_ jobs: [Job]) async {
        /// Do nothing if we weren't given any jobs
        guard !jobs.isEmpty else { return }
        
        /// Group jobs by queue
        let jobsByQueue: [JobQueue: [Job]] = jobs.reduce(into: [:]) { result, next in
            guard let queue: JobQueue = queues[next.variant] else {
                Log.critical(.jobRunner, "Attempted to add dependency \(next) with variant \(next.variant) which has no assigned queue.")
                return
            }
            
            result[queue, default: []].append(next)
        }
        
        await withTaskGroup(of: Void.self) { group in
            for (queue, jobsForQueue) in jobsByQueue {
                group.addTask {
                    await queue.enqueueDependencies(jobsForQueue)
                }
            }
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
    
    public func didCompleteJob(id: Int64, result: JobRunner.JobResult) {
        if let stream: CancellationAwareAsyncStream<JobRunner.JobResult> = resultStreams[id] {
            Task {
                await stream.send(result)
                await stream.finishCurrentStreams()
                resultStreams.removeValue(forKey: id)
            }
        }
    }
    
    public func awaitResult(forFirstJobMatching filters: JobRunner.Filters, in state: JobRunner.JobState) async -> JobRunner.JobResult {
        /// Ensure we know about the job
        let info: [Int64: JobInfo] = await jobInfoFor(state: state, filters: filters)
        
        guard
            let targetJobId: Int64 = info
                .sorted(by: { lhs, rhs in (lhs.value.queueIndex ?? 0) < (rhs.value.queueIndex ?? 0) })
                .first?
                .key
        else { return .notFound }
        
        /// Get or create a stream for the job
        let stream: CancellationAwareAsyncStream<JobRunner.JobResult> = resultStreams[
            targetJobId,
            default: CancellationAwareAsyncStream()
        ]
        resultStreams[targetJobId] = stream
        
        /// Await the first result from the stream
        for await result in stream.stream {
            return result
        }
        
        /// If the stream finishes without a result, something went wrong
        return .notFound
    }
    
    // MARK: - Recurring Jobs
    
    public func registerRecurringJobs(scheduleInfo: [JobRunner.ScheduleInfo]) {
        registeredRecurringJobs.append(contentsOf: scheduleInfo)
    }
    
    public func scheduleRecurringJobsIfNeeded() async {
        let scheduleInfo: [ScheduleInfo] = registeredRecurringJobs
        let variants: Set<Job.Variant> = Set(scheduleInfo.map { $0.variant })
        let maybeExistingJobs: [Job]? = try? await dependencies[singleton: .storage].readAsync { db in
            try Job
                .filter(variants.contains(Job.Columns.variant))
                .fetchAll(db)
        }
        
        guard let existingJobs: [Job] = maybeExistingJobs else {
            Log.warn(.jobRunner, "Failed to load existing recurring jobs from the database")
            return
        }
        
        let missingScheduledJobs: [ScheduleInfo] = scheduleInfo
            .filter { scheduleInfo in
                !existingJobs.contains { existingJob in
                    existingJob.variant == scheduleInfo.variant &&
                    existingJob.behaviour == scheduleInfo.behaviour &&
                    existingJob.shouldBlock == scheduleInfo.shouldBlock &&
                    existingJob.shouldSkipLaunchBecomeActive == scheduleInfo.shouldSkipLaunchBecomeActive
                }
            }
        
        guard !missingScheduledJobs.isEmpty else { return }
        
        do {
            try await dependencies[singleton: .storage].writeAsync { db in
                try missingScheduledJobs.forEach { variant, behaviour, shouldBlock, shouldSkipLaunchBecomeActive in
                    _ = try Job(
                        variant: variant,
                        behaviour: behaviour,
                        shouldBlock: shouldBlock,
                        shouldSkipLaunchBecomeActive: shouldSkipLaunchBecomeActive
                    ).inserted(db)
                }
            }
            Log.info(.jobRunner, "Scheduled \(missingScheduledJobs.count) missing recurring job(s)")
        }
        catch {
            Log.error(.jobRunner, "Failed to schedule \(missingScheduledJobs.count) recurring job(s): \(error)")
        }
    }
    
    // MARK: - Convenience
    
    fileprivate func canAddToQueue(_ job: Job) -> Bool {
        /// A job should not be added to the in-memory queue if it's waiting for a config sync
        guard job.behaviour != .runOnceAfterConfigSyncIgnoringPermanentFailure else {
            return false
        }
        
        /// We can only start the job if it's an "on launch" job or the app has become active
        return (
            job.behaviour == .runOnceNextLaunch ||
            job.behaviour == .recurringOnLaunch ||
            appHasBecomeActive
        )
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
        
        func matches(_ jobInfo: JobRunner.JobInfo) -> Bool {
            let infoSet: Set<FilterType> = Set([
                jobInfo.id.map { .jobId($0) },
                .variant(jobInfo.variant),
                jobInfo.threadId.map { .threadId($0) },
                jobInfo.interactionId.map { .interactionId($0) }
            ].compactMap { $0 })
            
            /// If the job is explicitly excluded then it doesn't match the filters
            if !exclude.intersection(infoSet).isEmpty {
                return false
            }
            
            /// If `include` is empty, or the job is explicitly included then it does match the filters
            return (include.isEmpty || !include.intersection(infoSet).isEmpty)
        }
    }
}

// MARK: - JobRunner.JobState

public extension JobRunner {
    struct JobState: OptionSet, Hashable {
        public let rawValue: UInt8
        
        public init(rawValue: UInt8) {
            self.rawValue = rawValue
        }
        
        public static let pending: JobState = JobState(rawValue: 1 << 0)
        public static let running: JobState = JobState(rawValue: 1 << 1)
        
        public static let any: JobState = [ .pending, .running ]
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

// MARK: - JobRunner.JobState

public extension JobRunner {
    typealias ScheduleInfo = (
        variant: Job.Variant,
        behaviour: Job.Behaviour,
        shouldBlock: Bool,
        shouldSkipLaunchBecomeActive: Bool
    )
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
