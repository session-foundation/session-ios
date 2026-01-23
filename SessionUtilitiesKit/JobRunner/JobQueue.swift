// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import GRDB

public actor JobQueue: Hashable {
    private static let deferralLoopThreshold: Int = 3
    private static let defaultDeferralDelay: TimeInterval = 1
    private static let completedJobCleanupDelay: DispatchTimeInterval = .seconds(5)
    
    private let dependencies: Dependencies
    nonisolated private let id: UUID = UUID()
    nonisolated internal let type: QueueType
    private let executionType: ExecutionType
    private let priority: TaskPriority
    nonisolated public let jobVariants: [Job.Variant]
    private let maxDeferralsPerSecond: Int
    private let _state: CurrentValueAsyncStream<State> = CurrentValueAsyncStream(.notStarted)
    
    private var executorMap: [Job.Variant: JobExecutor.Type] = [:]
    private var sortDataRetriever: JobSorterDataRetriever.Type = JobSorter.EmptyRetriever.self
    
    private var allJobs: [JobQueueId: JobState] = [:]
    private var deferLoopTracker: [JobQueueId: (count: Int, times: [TimeInterval])] = [:]
    
    private var canStartJobs: Bool = false
    private var canLoadFromDatabase: Bool = false
    private var isTryingToFillSlots: Bool = false
    private var needsReschedule: Bool = false
    private var priorityContext: JobPriorityContext = .empty
    private var loadTask: Task<Void, Never>? = nil
    private var nextTriggerTask: Task<Void, Never>? = nil
    
    public var state: AsyncStream<State> { _state.stream }
    
    // MARK: - Initialization
    
    public init(
        type: QueueType,
        executionType: ExecutionType,
        priority: TaskPriority,
        isTestingJobRunner: Bool,
        jobVariants: [Job.Variant],
        using dependencies: Dependencies
    ) {
        self.dependencies = dependencies
        self.type = type
        self.executionType = executionType
        self.priority = priority
        self.jobVariants = jobVariants
        self.maxDeferralsPerSecond = (isTestingJobRunner ? 10 : 1) /// Allow for tripping the defer loop in tests
    }
    
    // MARK: - Hashable
    
    nonisolated public func hash(into hasher: inout Hasher) {
        id.hash(into: &hasher)
    }
    
    public static func == (lhs: JobQueue, rhs: JobQueue) -> Bool {
        return (lhs.id == rhs.id)
    }
    
    // MARK: - Configuration
    
    func setExecutor(_ executor: JobExecutor.Type, for variant: Job.Variant) {
        executorMap[variant] = executor
    }
    
    func setSortDataRetriever(_ sortDataRetriever: JobSorterDataRetriever.Type) {
        self.sortDataRetriever = sortDataRetriever
    }
    
    func updatePriorityContext(_ context: JobPriorityContext) async {
        self.priorityContext = context
        await tryFillAvailableSlots()
    }
    
    // MARK: - Scheduling
    
    func add(
        _ job: Job,
        transientId: UUID? = nil
    ) async {
        guard let queueId: JobQueueId = JobQueueId(databaseId: job.id, transientId: transientId, queueSizeAtCreation: allJobs.count) else {
            Log.info(.jobRunner, "Prevented attempt to add \(job) without id to queue.")
            return
        }
        
        /// Upsert the job as long as it's not currently running
        if allJobs[queueId] == nil || allJobs[queueId]?.executionState.phase != .running {
            allJobs[queueId] = JobState(
                queueId: queueId,
                job: job,
                jobDependencies: (allJobs[queueId]?.jobDependencies ?? []),
                executionState: (allJobs[queueId]?.executionState ?? .pending),
                resultStream: (allJobs[queueId]?.resultStream ?? CurrentValueAsyncStream(nil))
            )
        }
        
        /// Fill available execution slots if there are any
        await tryFillAvailableSlots()
    }
    
    func update(_ job: Job) async {
        guard let queueId: JobQueueId = JobQueueId(databaseId: job.id, transientId: nil, queueSizeAtCreation: allJobs.count) else {
            Log.info(.jobRunner, "Failed to update \(job) without id.")
            return
        }
        
        /// Only update the job if it's still pending
        guard
            let oldState: JobState = allJobs[queueId],
            case .pending = oldState.executionState
        else { return }
        
        allJobs[queueId] = JobState(
            queueId: queueId,
            job: job,
            jobDependencies: oldState.jobDependencies,
            executionState: oldState.executionState,
            resultStream: oldState.resultStream
        )
    }
    
    private func remove(jobFor queueId: JobQueueId) async {
        allJobs.removeValue(forKey: queueId)
    }
    
    /// Indicate that another job needs to be completed before this job can be started
    func addJobDependencies(
        queueId: JobQueueId,
        jobDependencies: Set<JobDependency>
    ) async {
        guard var jobState: JobState = allJobs[queueId] else { return }
        
        jobState.jobDependencies.append(contentsOf: jobDependencies)
        allJobs[queueId] = jobState
    }
    
    /// Remove the dependency from a job in the queue
    func removeJobDependencies(_ jobDependencies: [JobDependency]) async {
        let currentTimestamp: TimeInterval = dependencies.dateNow.timeIntervalSince1970
        var hasJobWithNoDependencies: Bool = false
        
        for jobDependency in jobDependencies {
            let queueId: JobQueueId = JobQueueId(databaseId: jobDependency.jobId)
            
            guard var jobState: JobState = allJobs[queueId] else { return }
            
            jobState.jobDependencies = jobState.jobDependencies.filter { $0 != jobDependency }
            allJobs[queueId] = jobState
            
            if !hasJobWithNoDependencies {
                /// The `timestamp` dependency won't automatically get remove so we need to ignore it when determining
                /// if a job has any remaining dependencies
                let unmetDependencies: [JobDependency] = jobState.jobDependencies.filter { dep in
                    switch dep.variant {
                        case .timestamp: return ((dep.timestamp ?? 0) > currentTimestamp)
                        case .job, .configSync: return true
                    }
                }
                
                if unmetDependencies.isEmpty {
                    hasJobWithNoDependencies = true
                }
            }
        }
        
        /// If we have a job with no dependencies then we should load any pending jobs from the database (just in case we somehow
        /// lost a dependency) and then try to fill any available capacity the queue has
        if hasJobWithNoDependencies {
            await loadPendingJobsFromDatabase()
            guard !Task.isCancelled else { return }
            
            await tryFillAvailableSlots()
        }
    }
    
    func removePendingJob(_ jobId: Int64?) {
        /// Only remove if pending
        guard
            let queueId: JobQueueId = JobQueueId(databaseId: jobId),
            allJobs[queueId]?.isPending == true
        else { return }
        
        allJobs.removeValue(forKey: queueId)
    }
    
    internal func loadPendingJobsFromDatabase() async {
        /// No need to do anything if we don't have any registered variants
        guard canStartJobs && canLoadFromDatabase else { return }
        guard !jobVariants.isEmpty else { return }
        
        struct JobIdVariant: Decodable, FetchableRecord {
            let jobId: Int64
            let variant: Job.Variant
        }
        typealias JobInfo = (
            jobs: [Job],
            jobDependencies: [JobDependency]
        )
        
        /// Fetch any jobs and dependencies we may not know about
        let currentJobIds: Set<Int64> = Set(allJobs.keys.compactMap { $0.databaseId })
        let info: JobInfo = ((try? await dependencies[singleton: .storage].readAsync { [jobVariants] db -> JobInfo in
            let missingJobs: [Job] = try Job
                .filter(!currentJobIds.contains(Job.Columns.id))
                .filter(jobVariants.contains(Job.Columns.variant))
                .fetchAll(db)
            let missingJobIds: Set<Int64> = Set(missingJobs.compactMap(\.id))
            let missingJobDependencies: [JobDependency] = try JobDependency
                .filter(JobDependency.Columns.variant == JobDependency.Variant.job)
                .filter(
                    currentJobIds.contains(JobDependency.Columns.jobId) ||
                    missingJobIds.contains(JobDependency.Columns.jobId) ||
                    missingJobIds.contains(JobDependency.Columns.otherJobId)
                )
                .fetchAll(db)
            
            return (missingJobs, missingJobDependencies)
        }) ?? ([], []))
        
        let jobDependencyMap: [Int64: [JobDependency]] = info.jobDependencies.grouped(by: \.jobId)
        
        /// Create the state for the job and store in memory
        for job in info.jobs {
            guard let queueId: JobQueueId = JobQueueId(databaseId: job.id) else { continue }
            
            if var existingState: JobState = allJobs[queueId] {
                /// Can only update an existing job if it's still pending
                if existingState.isPending {
                    existingState.jobDependencies = (jobDependencyMap[job.id] ?? [])
                    allJobs[queueId] = existingState
                }
            }
            else {
                allJobs[queueId] = JobState(
                    queueId: queueId,
                    job: job,
                    jobDependencies: (jobDependencyMap[job.id] ?? []),
                    executionState: .pending,
                    resultStream: CurrentValueAsyncStream(nil)
                )
            }
        }
    }
    
    // MARK: - Execution Management
    
    func start(drainOnly: Bool) async {
        self.canStartJobs = true
        self.canLoadFromDatabase = !drainOnly
        
        loadTask?.cancel()
        loadTask = nil
        await _state.send(.running)
        
        if !drainOnly {
            loadTask = Task {
                guard !Task.isCancelled else { return }
                await loadPendingJobsFromDatabase()
                
                guard !Task.isCancelled else { return }
                await tryFillAvailableSlots()
            }
        } else {
            await tryFillAvailableSlots()
        }
    }
    
    func tryFillAvailableSlots() async {
        /// Yield the task to give other tasks the chance to update job states before we fetch the latest values and schedule the next
        /// highest priority job
        await Task.yield()
        
        /// If we can't start jobs, or we are already in the process of filling available slots, then don't continue (we don't want to
        /// incorrectly start more jobs than should be available due to `sortedJobs` being async)
        guard canStartJobs else { return }
        guard !isTryingToFillSlots else {
            needsReschedule = true
            return
        }
        
        /// Keep scheduling as long as other tasks keep setting `needsReschedule` to `true`
        repeat {
            /// Prevent the queue from trying to fill slots
            isTryingToFillSlots = true
            needsReschedule = false
            defer { isTryingToFillSlots = false }
            
            let runningCount: Int = allJobs.values.filter(\.isRunning).count
            let availableSlots: Int = (executionType.limit - runningCount)
            
            /// If there are no slots available then check if there are any lower priority jobs which should be cancelled and replaced
            /// with higher priority jobs
            if availableSlots <= 0 {
                await tryPreemptLowerPriorityJobs()
                continue    /// Immediately loop, if needed, to fill any slots that may have become available while preempting
            }
            
            /// Cancel any `nextTriggerTask` since we are trying to load new jobs (if none are ready then we will schedule a new one)
            nextTriggerTask?.cancel()
            nextTriggerTask = nil
            
            /// Get pending jobs sorted by priority and start jobs until we hit the limit
            let pendingJobs: [JobState] = await sortedJobs(
                matching: JobRunner.Filters(include: [.executionPhase(.pending)]),
                excludePendingJobsWhichCannotBeStarted: true
            )
            
            if !pendingJobs.isEmpty {
                var slotsRemaining: Int = availableSlots
                
                for pendingJob in pendingJobs {
                    guard slotsRemaining > 0 else { break }
                    
                    /// Ensure the job has everything is needs before trying to start it
                    guard let executor: JobExecutor.Type = await prepareToExecute(pendingJob) else {
                        continue
                    }
                    
                    /// Some job variants have special concurrency rules where only one may be allowed to run at a time even if
                    /// they are run in a queue that supports maximum concurrency, this validates that we are allowed to start a
                    /// given job with those rules in mind
                    let runningJobs: [JobState] = allJobs.values.filter {
                        $0.executionState.phase == .running &&
                        $0.job.variant == pendingJob.job.variant
                    }
                    
                    /// If there are no running jobs of this variant then there is no need to check special concurrency rules
                    guard
                        runningJobs.isEmpty ||
                        executor.canStart(
                            jobState: pendingJob,
                            alongside: runningJobs,
                            using: dependencies
                        )
                    else { continue }
                    
                    /// We have passed the special concurrency check so start the job
                    startJob(queueId: pendingJob.queueId, executor: executor)
                    slotsRemaining -= 1
                }
            }
            else {
                let allPendingJobs: [JobState] = allJobs.values
                    .filter { $0.executionState.phase == .pending }
                let maybeNextRunTimestamp: TimeInterval? = allPendingJobs
                    .compactMap { jobState in
                        /// We want to get the maximum timestamp JobDependency (if a job somehow has multiple then we should
                        /// wait for the later one to be resolved)
                        var maxTimestamp: TimeInterval = 0
                        
                        /// Exclude any jobs which have non-timestamp dependencies (the queue will be restarted for those when
                        /// they are removed)
                        for jobDependency in jobState.jobDependencies {
                            switch jobDependency.variant {
                                case .job, .configSync: return nil
                                case .timestamp:
                                    maxTimestamp = max(maxTimestamp, (jobDependency.timestamp ?? 0))
                            }
                        }
                        
                        /// Exclude invalid timestamps
                        guard maxTimestamp > 0 else { return nil }
                        
                        return maxTimestamp
                    }
                    .min()
                let hasRunningJobs: Bool = (allJobs.values
                    .filter { $0.executionState.phase == .running }
                    .isEmpty == false)
                
                /// Only update the state if we have no running jobs (if we do have other running jobs then they will trigger
                /// `tryFillAvailableSlots` when they complete and update the state)
                if !hasRunningJobs {
                    await _state.send(allPendingJobs.count == 0 ? .drained : .pending)
                }
                
                /// If there are still jobs in the queue but they are scheduled to run in the future then we should kick off a task to wait
                /// until they are ready to run
                if let nextRunTimestamp: TimeInterval = maybeNextRunTimestamp {
                    let secondsUntilNextJob: TimeInterval = (nextRunTimestamp - dependencies.dateNow.timeIntervalSince1970)
                    Log.info(.jobRunner, "Stopping JobQueue-\(type.name) until next job in \(secondsUntilNextJob)s")
                    
                    nextTriggerTask = Task { [weak self, dependencies] in
                        /// Need to re-calculate this as tasks may not run immediately
                        let updatedSecondsUntilNextJob: TimeInterval = (nextRunTimestamp - dependencies.dateNow.timeIntervalSince1970)
                        
                        if updatedSecondsUntilNextJob > 0 {
                            try? await Task.sleep(for: .seconds(Int(floor(updatedSecondsUntilNextJob))))
                            guard !Task.isCancelled else { return }
                        }
                        
                        await self?.loadPendingJobsFromDatabase()
                        guard !Task.isCancelled else { return }
                        
                        await self?.tryFillAvailableSlots()
                    }
                }
            }
        } while needsReschedule
    }
    
    private func tryPreemptLowerPriorityJobs() async {
        guard canStartJobs else { return }
        
        /// Ensure we have a pending job
        let pendingJobs: [JobState] = await sortedJobs(
            matching: JobRunner.Filters(include: [.executionPhase(.pending)]),
            excludePendingJobsWhichCannotBeStarted: true
        )
        
        guard
            let highestPriorityPendingJob: JobState = pendingJobs.first,
            let highestPriorityPendingJobState: JobState = allJobs[highestPriorityPendingJob.queueId],
            highestPriorityPendingJobState.isPending
        else { return }
        
        /// Check if the lowest priority running job can be preempted and
        let runningJobs: [JobState] = await sortedJobs(
            matching: JobRunner.Filters(include: [.executionPhase(.running)]),
            excludePendingJobsWhichCannotBeStarted: true
        )
        
        guard
            let lowestPriorityRunningJob: JobState = runningJobs.last,
            let lowestPriorityJobExecutor: JobExecutor.Type = executorMap[lowestPriorityRunningJob.job.variant],
            lowestPriorityJobExecutor.canBePreempted
        else { return }
        
        /// Since it can be preempted we should check if it has a higher priority than the highest priority pending job
        let jobsToCheck: [JobState] = [lowestPriorityRunningJob, highestPriorityPendingJob]
        let sortedJobs: [JobState] = await type.jobSorter(
            jobsToCheck,
            priorityContext,
            sortDataRetriever.retrieveData(jobsToCheck, using: dependencies)
        )
        
        guard sortedJobs.first?.queueId == highestPriorityPendingJob.queueId else { return }
        
        /// Ensure the job has everything is needs before trying to start it
        guard let executor: JobExecutor.Type = await prepareToExecute(highestPriorityPendingJob) else {
            return
        }
        
        /// Since it has a higher priority we should cancel the lowest priority running job and start this new job
        if
            let state: JobState = allJobs[lowestPriorityRunningJob.queueId],
            case .running(let task) = state.executionState
        {
            Log.info(.jobRunner, "JobQueue-\(type.name) preempting \(lowestPriorityRunningJob) for higher priority \(highestPriorityPendingJob)")
            
            task.cancel()
            
            /// Mark as pending again so it can be retried later
            allJobs[state.queueId] = JobState(
                queueId: state.queueId,
                job: state.job,
                jobDependencies: state.jobDependencies,
                executionState: .pending(lastAttempt: .preempted),
                resultStream: state.resultStream
            )
            
            /// Now start the higher priority job
            startJob(queueId: highestPriorityPendingJob.queueId, executor: executor)
        }
    }
    
    private func startJob(queueId: JobQueueId, executor: JobExecutor.Type) {
        guard var jobState: JobState = allJobs[queueId], jobState.isPending else { return }
        
        let task = Task(priority: priority) {
            await executeJob(queueId, executor: executor)
        }
        
        /// Remove any expired dependencies
        let currentTimestamp: TimeInterval = dependencies.dateNow.timeIntervalSince1970
        jobState.executionState = .running(task: task)
        jobState.jobDependencies = jobState.jobDependencies.filter { dep in
            switch dep.variant {
                case .timestamp: return ((dep.timestamp ?? 0) > currentTimestamp)
                case .job, .configSync: return true
            }
        }
        allJobs[queueId] = jobState
        
        /// Kick off a task to remove the dependency from the database as well
        if let jobId: Int64 = jobState.job.id {
            Task.detached(priority: .high) { [dependencies] in
                try? await dependencies[singleton: .storage].writeAsync { db in
                    dependencies[singleton: .jobRunner].removeJobDependencies(
                        db,
                        .timestamp,
                        fromJobIds: [jobId]
                    )
                }
            }
        }
    }
    
    private func executeJob(_ queueId: JobQueueId, executor: JobExecutor.Type) async {
        /// To avoid odd edge-cases we:
        /// - Ensure the job hasn't been cancelled (eg. by preemption or `stopAndClear`)
        /// - Retrieve the latest version of the job (will have the current `executionState`)
        /// - Ensure the `executionState` is still `.running` (preemption could change this)
        ///
        /// If this check fails then we should call through to `tryFillAvailableSlots` just in case there are any available slots
        /// which could run other pending jobs
        guard
            !Task.isCancelled,
            let jobState: JobState = allJobs[queueId],
            jobState.executionState.phase == .running
        else { return await tryFillAvailableSlots() }
        
        /// Wait for the task to complete
        let executionOutcome: Result<JobExecutionResult, Error> = await Result {
            return try await executor.run(jobState.job, using: dependencies)
        }
        
        /// Determine if the job had too many retries
        let tooManyRetries: Bool = (executor.maxFailureCount >= 0 && (jobState.job.failureCount + 1) > executor.maxFailureCount)
        
        /// Handle the execution outcome
        let finalExecutionState: JobState.ExecutionState
        var updatedJob: Job = jobState.job
        
        switch executionOutcome {
            case .success(.success):
                await updateDatabaseForSuccess(jobState.job)
                finalExecutionState = .completed(result: .succeeded)
                
            case .success(.deferred(let nextRunTimestamp)):
                updatedJob = await updateDatabaseForDeferral(jobState, nextRunTimestamp)
                finalExecutionState = .pending(lastAttempt: .deferred)
                
            case .failure(let error) where (error as? JobError)?.isPermanent == true,
                .failure(let error) where tooManyRetries:
                await updateDatabaseForPermanentFailure(jobState, error: error, tooManyRetries: tooManyRetries)
                finalExecutionState = .completed(result: .failed(error, isPermanent: true))
            
            case .failure(let error):
                updatedJob = await updateDatabaseForTransientFailure(jobState, error: error)
                finalExecutionState = .pending(lastAttempt: .failed(error, isPermanent: false))
        }
        
        /// Update states, notify streams and cleanup
        guard var updatedJobState: JobState = allJobs[jobState.queueId] else {
            /// Job was removed (e.g., queue cleared), nothing to finalize
            await tryFillAvailableSlots()
            return
        }
        
        /// Update execution state
        updatedJobState.job = updatedJob
        updatedJobState.executionState = finalExecutionState
        allJobs[updatedJobState.queueId] = updatedJobState
        
        /// Notify result stream only when truly completed
        if case .completed(let result) = finalExecutionState {
            await updatedJobState.resultStream.send(result)
            
            /// Keep completed jobs around briefly for result observation, then clean up
            Task.detached(priority: .utility) { [weak self] in
                try? await Task.sleep(for: JobQueue.completedJobCleanupDelay)
                await self?.remove(jobFor: updatedJobState.queueId)
            }
        }
        
        /// Try to fill available slots (might start new jobs)
        await tryFillAvailableSlots()
    }
    
    // MARK: - State
    
    public func jobsMatching(
        filters: JobRunner.Filters
    ) async -> [JobQueueId: JobState] {
        return allJobs.values.reduce(into: [:]) { result, jobState in
            if filters.matches(jobState) {
                result[jobState.queueId] = jobState
            }
        }
    }
    
    func finalResult(for queueId: JobQueueId) async throws -> JobRunner.JobResult {
        /// Check if already completed
        if case .completed(let result) = allJobs[queueId]?.executionState {
            return result
        }
        
        /// Otherwise wait for result
        return try await allJobs[queueId]?.resultStream
            .stream
            .compactMap { $0 }
            .first { _ in true } ?? { throw JobRunnerError.noJobsMatchingFilters }()
    }
    
    func deferCount(for jobId: Int64) -> Int {
        return (deferLoopTracker[JobQueueId(databaseId: jobId)]?.count ?? 0)
    }
    // TODO: [JOBRUNNER] Probably need a function which just sets 'canLoadFromDatabase' but doesn't cancel everything (eg. to finish sending a message with an attachment after entering the background)
    func stopAndClear() {
        /// Cancel the load task first to prevent race conditions
        loadTask?.cancel()
        loadTask = nil
        
        /// Cancel all running jobs
        for (_, state) in allJobs {
            if case .running(let task) = state.executionState {
                task.cancel()
            }
        }
        
        /// Clear the state
        allJobs.removeAll()
        deferLoopTracker.removeAll()
        canLoadFromDatabase = false
        canStartJobs = false
        
        Log.info(.jobRunner, "Stopped and cleared JobQueue-\(type.name)")
    }
    
    func matches(filters: JobRunner.Filters) -> Bool {
        /// A queue matches if *any* of its variants match the filter
        return filters.matches(jobVariants.map { .variant($0) })
    }
    
    // MARK: - Helpers
    
    internal func sortedJobs(
        matching filters: JobRunner.Filters,
        excludePendingJobsWhichCannotBeStarted: Bool
    ) async -> [JobState] {
        let jobQueueIdsWithPendingDependencies: [JobQueueId: Int] = await dependencies[singleton: .jobRunner]
            .getJobDependencyCoordinator()
            .pendingAdditions
        let currentTimestamp: TimeInterval = dependencies.dateNow.timeIntervalSince1970
        var candidates: [JobState] = []
        candidates.reserveCapacity(allJobs.count)
        
        for state in allJobs.values {
            guard filters.matches(state) else { continue }
            
            /// If we are looking for `pending` jobs then ensure they can be started
            if excludePendingJobsWhichCannotBeStarted && state.executionState.phase == .pending {
                let unmetDependencies: [JobDependency] = state.jobDependencies
                    .filter { dep in
                        switch dep.variant {
                            case .timestamp: return ((dep.timestamp ?? 0) > currentTimestamp)
                            case .job, .configSync: return true
                        }
                    }
                
                guard
                    unmetDependencies.isEmpty,
                    jobQueueIdsWithPendingDependencies[state.queueId] == nil
                else { continue }
            }
            
            candidates.append(state)
        }
        
        return await type.jobSorter(
            candidates,
            priorityContext,
            sortDataRetriever.retrieveData(candidates, using: dependencies)
        )
    }
    
    private func shouldUpdateDatabaseForFailure(_ jobState: JobState) async -> Bool {
        let jobExists: Bool = await {
            guard let databaseId: Int64 = jobState.job.id else { return false }
            
            return ((try? await dependencies[singleton: .storage].readAsync { db in
                try Job.exists(db, id: databaseId)
            }) ?? false)
        }()
        
        guard jobExists || (self.type == .blocking && jobState.queueId.transientId != nil) else {
            Log.info(.jobRunner, "JobQueue-\(type.name) \(jobState.job) canceled")
            return false
        }
        
        return true
    }
    
    // MARK: - Database Operations
    
    private func updateDatabaseForSuccess(_ job: Job) async {
        do {
            /// Call to the `JobRunner` to remove the job if it was dependency for any other job, this will also start any jobs that
            /// have no other dependencies and no other jobs in their queues
            try await dependencies[singleton: .storage].writeAsync { [dependencies] db in
                if let jobId: Int64 = job.id {
                    dependencies[singleton: .jobRunner].removeJobDependencies(db, .job(jobId))
                }
                
                _ = try? job.delete(db)
            }
        } catch {
            Log.error(.jobRunner, "Failed to process successful job \(job) in database: \(error)")
        }
    }
    
    private func updateDatabaseForPermanentFailure(_ jobState: JobState, error: Error, tooManyRetries: Bool) async {
        guard await shouldUpdateDatabaseForFailure(jobState) else { return }
        
        Log.error(.jobRunner, "JobQueue-\(type.name) \(jobState.job) failed permanently due to error: \(error)\(tooManyRetries ? "; too many retries" : "")")
        
        do {
            try await dependencies[singleton: .storage].writeAsync { [dependencies] db in
                /// If the job permanently failed or we have performed all of our retry attempts then delete the job and all of it's
                /// dependant jobs (it'll probably never succeed)
                if let jobId: Int64 = jobState.job.id {
                    let jobIdsThatWereDepenantOnThisJob: Set<Int64> = dependencies[singleton: .jobRunner]
                        .removeJobDependencies(db, .job(jobId))
                    
                    if !jobIdsThatWereDepenantOnThisJob.isEmpty {
                        _ = try Job.deleteAll(db, ids: jobIdsThatWereDepenantOnThisJob)
                    
                        db.afterCommit {
                            Task { [dependencies] in
                                for jobId in jobIdsThatWereDepenantOnThisJob {
                                    await dependencies[singleton: .jobRunner].removePendingJob(jobId)
                                }
                            }
                        }
                    }
                }
                _ = try jobState.job.delete(db)
                return
            }
        }
        catch {
            Log.error(.jobRunner, "Failed to delete permanently failed job \(jobState.job) from database: \(error)")
        }
    }

    private func updateDatabaseForTransientFailure(_ jobState: JobState, error: Error) async -> Job {
        guard await shouldUpdateDatabaseForFailure(jobState) else { return jobState.job }
        
        if self.type == .blocking && (error as? JobRunnerError)?.wasPossibleDeferralLoop != true {
            Log.info(.jobRunner, "JobQueue-\(type.name) \(jobState.job) failed due to error: \(error); retrying immediately")
            Task { await tryFillAvailableSlots() }
            return jobState.job
        }
        
        /// Get the max failure count for the job (a value of '-1' means it will retry indefinitely)
        let updatedFailureCount: UInt = (jobState.job.failureCount + 1)
        let nextRunTimestamp: TimeInterval = (dependencies.dateNow.timeIntervalSince1970 + jobState.job.retryInterval)
        let updatedJob: Job = jobState.job.with(
            failureCount: updatedFailureCount
        )
        
        Log.error(.jobRunner, "JobQueue-\(type.name) \(jobState.job) failed due to error: \(error); scheduling retry (failure count is \(updatedFailureCount))")
        
        do {
            try await dependencies[singleton: .storage].writeAsync { [dependencies] db in
                /// Save the updated job directly (can't' use `jobRunner.update` because it only allows updating jobs which
                /// are `pending`)
                _ = try updatedJob.upserted(db)
                
                /// Need to add a dependency to this job to prevent it from running until `nextRunTimestamp`
                if let jobId: Int64 = jobState.job.id {
                    try dependencies[singleton: .jobRunner].addJobDependency(
                        db,
                        .timestamp(jobId: jobId, waitUntil: nextRunTimestamp)
                    )
                }
            }
        }
        catch {
            Log.error(.jobRunner, "Failed to update database for failed job \(jobState.job): \(error)")
        }
        
        return updatedJob
    }
    
    private func updateDatabaseForDeferral(_ jobState: JobState, _ nextRunTimestamp: TimeInterval?) async -> Job {
        var stuckInDeferLoop: Bool = false
        
        if let record: (count: Int, times: [TimeInterval]) = deferLoopTracker[jobState.queueId] {
            let timeNow: TimeInterval = dependencies.dateNow.timeIntervalSince1970
            stuckInDeferLoop = (
                record.count >= JobQueue.deferralLoopThreshold &&
                (timeNow - record.times[0]) < CGFloat(record.count * maxDeferralsPerSecond)
            )
            
            /// Only store the last `deferralLoopThreshold` times to ensure we aren't running faster than one loop per second
            deferLoopTracker[jobState.queueId] = (
                record.count + 1,
                record.times.suffix(JobQueue.deferralLoopThreshold - 1) + [timeNow]
            )
        } else {
            deferLoopTracker[jobState.queueId] = (1, [dependencies.dateNow.timeIntervalSince1970])
        }
        
        /// It's possible (by introducing bugs) to create a loop where a `Job` tries to run and immediately defers itself but then attempts
        /// to run again (resulting in an infinite loop); this won't block the app since it's on a background thread but can result in 100% of
        /// a CPU being used (and a battery drain)
        ///
        /// This code will maintain an in-memory store for any jobs which are deferred too quickly (ie. more than `deferralLoopThreshold`
        /// times within `deferralLoopThreshold` seconds)
        if stuckInDeferLoop {
            deferLoopTracker.removeValue(forKey: jobState.queueId)
            return await updateDatabaseForTransientFailure(
                jobState,
                error: JobRunnerError.possibleDeferralLoop
            )
        }
        
        do {
            guard let jobId: Int64 = jobState.job.id else {
                throw JobRunnerError.jobIdMissing
            }
            
            /// Use the specified timestamp or fallback to waiting for `defaultDeferralDelay`
            let targetTimestamp: TimeInterval = (
                nextRunTimestamp ??
                (dependencies.dateNow.timeIntervalSince1970 + JobQueue.defaultDeferralDelay)
            )
            try await dependencies[singleton: .storage].writeAsync { [dependencies] db in
                try dependencies[singleton: .jobRunner].addJobDependency(
                    db,
                    .timestamp(jobId: jobId, waitUntil: targetTimestamp)
                )
            }
        } catch {
            Log.error(.jobRunner, "Failed to save deferred job \(jobState.job): \(error)")
        }
        
        return jobState.job
    }
    
    // MARK: - Conenience

    private func prepareToExecute(_ jobState: JobState) async -> JobExecutor.Type? {
        let executor: JobExecutor.Type
        
        do {
            guard let validExecutor: JobExecutor.Type = executorMap[jobState.job.variant] else {
                Log.info(.jobRunner, "JobQueue-\(type.name) Unable to run \(jobState.job) due to missing executor")
                throw JobRunnerError.executorMissing
            }
            guard !validExecutor.requiresThreadId || jobState.job.threadId != nil else {
                Log.info(.jobRunner, "JobQueue-\(type.name) Unable to run \(jobState.job) due to missing required threadId")
                throw JobRunnerError.requiredThreadIdMissing
            }
            guard !validExecutor.requiresInteractionId || jobState.job.interactionId != nil else {
                Log.info(.jobRunner, "JobQueue-\(type.name) Unable to run \(jobState.job) due to missing required interactionId")
                throw JobRunnerError.requiredInteractionIdMissing
            }
            
            executor = validExecutor
        }
        catch {
            var updatedJobState: JobState = jobState
            await updateDatabaseForPermanentFailure(jobState, error: error, tooManyRetries: false)
            
            updatedJobState.executionState = .completed(
                result: .failed(error, isPermanent: true)
            )
            allJobs[updatedJobState.queueId] = updatedJobState
            return nil
        }
        
        /// Make sure there are no dependencies for the job
        ///
        /// **Note:** The `timestamp` dependency won't automatically get remove so we need to ignore it when determining
        /// if a job has any remaining dependencies
        let currentTimestamp: TimeInterval = dependencies.dateNow.timeIntervalSince1970
        let unmetDependencies: [JobDependency] = jobState.jobDependencies.filter { dep in
            switch dep.variant {
                case .timestamp: return ((dep.timestamp ?? 0) > currentTimestamp)
                case .job, .configSync: return true
            }
        }
        
        guard unmetDependencies.isEmpty else {
            Log.info(.jobRunner, "JobQueue-\(type.name) Deferring \(jobState.job) until \(jobState.jobDependencies.count) dependencies are completed")
            
            var updatedJobState: JobState = jobState
            updatedJobState.job = await updateDatabaseForDeferral(jobState, nil)
            updatedJobState.executionState = .pending(lastAttempt: .deferred)
            allJobs[updatedJobState.queueId] = updatedJobState
            return nil
        }
        
        return executor
    }
}

// MARK: - State

public extension JobQueue {
    enum State: Equatable {
        case notStarted
        case pending
        case running
        case drained
    }
}

// MARK: - QueueType

public extension JobQueue {
    enum QueueType: Hashable {
        case blocking
        case messageSend
        case messageReceive
        case file
        case expirationUpdate
        case startupProcesses
        
        var name: String {
            switch self {
                case .blocking: return "Blocking"
                case .messageSend: return "MessageSend"
                case .messageReceive: return "MessageReceive"
                case .file: return "File"
                case .expirationUpdate: return "ExpirationUpdate"
                case .startupProcesses: return "StartupProcesses"
            }
        }
        
        fileprivate var jobSorter: (([JobState], JobPriorityContext, Any?) -> [JobState]) {
            switch self {
                case .blocking, .startupProcesses: return JobSorter.sortById
                case .messageSend, .messageReceive, .expirationUpdate: return JobSorter.sortById
                case .file: return JobSorter.sortByFilePriority
            }
        }
    }
}

// MARK: - JobQueueId

public extension JobQueue {
    struct JobQueueId: Equatable, Hashable, Comparable {
        let databaseId: Int64?
        let transientId: UUID?
        let queueSizeAtCreation: Int
        
        init?(
            databaseId: Int64?,
            transientId: UUID? = nil,
            queueSizeAtCreation: Int = -1
        ) {
            /// Need either a `databaseId` or a `transientId`
            guard databaseId != nil || transientId != nil else { return nil }
            
            self.databaseId = databaseId
            self.transientId = transientId
            self.queueSizeAtCreation = queueSizeAtCreation
        }
        
        init(databaseId: Int64) {
            self.databaseId = databaseId
            self.transientId = nil
            self.queueSizeAtCreation = -1
            
        }
        
        // MARK: - --Hashable
        
        public func hash(into hasher: inout Hasher) {
            databaseId?.hash(into: &hasher)
            transientId?.hash(into: &hasher)
            /// We exclude `queueSizeAtCreation` as we don't want to match on it (it's only for sorting transient jobs)
        }
        
        // MARK: - --Comparable
        
        public static func == (lhs: JobQueueId, rhs: JobQueueId) -> Bool {
            return (
                lhs.databaseId == rhs.databaseId &&
                lhs.transientId == rhs.transientId
                /// We exclude `queueSizeAtCreation` as we don't want to match on it (it's only for sorting transient jobs)
            )
        }

        public static func < (lhs: JobQueueId, rhs: JobQueueId) -> Bool {
            switch (lhs.databaseId, rhs.databaseId, lhs.transientId, rhs.transientId) {
                case (.some(let lhsId), .some(let rhsId), _, _): return lhsId < rhsId
                case (_, _, .some, .some):
                    /// Sort by order it was inserted into the queue
                    return lhs.queueSizeAtCreation < rhs.queueSizeAtCreation
                    
                case (.none, .some, .some, .none): return true  /// Transient over database
                case (.some, .none, .none, .some): return false /// Transient over database
                case (.none, _, .none, _): return false         /// LHS is invalid
                case (_, .none, _, .none): return true          /// RHS is invalid
            }
        }
    }
}

// MARK: - ExecutionType

public extension JobQueue {
    enum ExecutionType {
        /// A serial queue will execute one job at a time until the queue is empty, then will load any new/deferred jobs and run those
        /// one at a time
        case serial
        
        /// A concurrent queue will execute jobs concurrently up to the `max` limit, once it hits the limit any subsequent jobs will wait
        /// in the queue until a currently executing job has completed
        case concurrent(max: Int)
        
        var limit: Int {
            switch self {
                case .serial: return 1
                case .concurrent(let max): return max
            }
        }
    }
}

// MARK: - JobExecutionPrecheckResult

private extension JobQueue {
    enum JobExecutionPrecheckResult {
        case ready(JobExecutor.Type, maxFailureCount: Int)
        case permanentlyFail(error: Error)
        case deferUntilDependenciesMet
    }
}

// MARK: - Convenience

private extension Job {
    var retryInterval: TimeInterval {
        // Arbitrary backoff factor...
        // try  1 delay: 0.5s
        // try  2 delay: 1s
        // ...
        // try  5 delay: 16s
        // ...
        // try 11 delay: 512s
        let maxBackoff: Double = 10 * 60 // 10 minutes
        return 0.25 * min(maxBackoff, pow(2, Double(failureCount)))
    }
}

// MARK: - Formatting

private extension String.StringInterpolation {
    mutating func appendInterpolation(_ job: Job) {
        appendLiteral("\(job.variant) job (\(job.id.map { "id: \($0)" } ?? "direct run"))")
    }
    
    mutating func appendInterpolation(_ job: Job?) {
        switch job {
            case .some(let job): appendInterpolation(job)
            case .none: appendLiteral("null job")
        }
    }
}
