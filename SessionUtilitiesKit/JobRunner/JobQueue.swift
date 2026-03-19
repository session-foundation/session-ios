// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import GRDB

public actor JobQueue: Hashable {
    private static let deferralLoopThreshold: Int = 3
    private static let defaultDeferralDelay: TimeInterval = 1
    private var completedJobCleanupDelay: DispatchTimeInterval {
        .seconds(Int(floor(dependencies[feature: .completedJobCleanupDelay])))
    }
    
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
    
    private var hasStartedAtLeastOnceSinceBecomingActive: Bool = false
    private var canStartJobForVariants: Set<Job.Variant> = []
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
        transientId: UUID? = nil,
        initialDependencies: [JobDependency] = []
    ) async {
        guard let queueId: JobQueueId = JobQueueId(databaseId: job.id, transientId: transientId, queueSizeAtCreation: allJobs.count) else {
            Log.info(.jobRunner, "Prevented attempt to add \(job) without id to queue.")
            return
        }
        
        /// Upsert the job as long as it's not currently running
        if allJobs[queueId] == nil || allJobs[queueId]?.executionState.phase != .running {
            let existingDeps: [JobDependency] = (allJobs[queueId]?.jobDependencies ?? [])
            let combinedDeps: [JobDependency] = Array(Set(existingDeps + initialDependencies))
            
            allJobs[queueId] = JobState(
                queueId: queueId,
                job: job,
                jobDependencies: combinedDeps,
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
        
        let hasNewTimestampDependency: Bool = jobDependencies.contains { $0.variant == .timestamp }
        jobState.jobDependencies = {
            guard hasNewTimestampDependency else {
                return Array(Set(jobState.jobDependencies + jobDependencies))
            }
            
            return Array(Set(
                jobState.jobDependencies.filter { $0.variant != .timestamp } +
                jobDependencies
            ))
        }()
        
        allJobs[queueId] = jobState
        
        /// If we aren't currently running and we just added a `timestamp` dependency then we should call
        /// `tryFillAvailableSlots` because it'll result in `nextTriggerTask` being created if one doesn't exist
        let containsTimestampDependency: Bool = jobDependencies.contains { $0.variant == .timestamp }
        
        if await _state.getCurrent() != .running && containsTimestampDependency {
            await tryFillAvailableSlots()
        }
    }
    
    /// Remove the dependency from a job in the queue
    func removeJobDependencies(_ jobDependencies: [JobDependency]) async {
        let currentTimestamp: TimeInterval = dependencies.dateNow.timeIntervalSince1970
        var hasJobWithNoDependencies: Bool = false
        var hadDependenciesRemovedFromExistingJobs: Bool = false
        
        for jobDependency in jobDependencies {
            let queueId: JobQueueId = JobQueueId(databaseId: jobDependency.jobId)
            
            guard var jobState: JobState = allJobs[queueId] else { return }
            
            jobState.jobDependencies = jobState.jobDependencies.filter { $0 != jobDependency }
            allJobs[queueId] = jobState
            hadDependenciesRemovedFromExistingJobs = true
            
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
        else if hadDependenciesRemovedFromExistingJobs {
            /// Even when jobs still have remaining dependencies (e.g. a timestamp dep), call `tryFillAvailableSlots` so it
            /// can set up a `nextTriggerTask` for them
            ///
            /// Without this a race condition can occurs where `tryFillAvailableSlots` runs (from `executeJob`) while the
            /// `afterCommit` task that removes the job dependency hasn't executed yet. At that point the job appears to still have
            /// a `.job` dependency and is excluded from `maybeNextRunTimestamp`, so no trigger task is scheduled. By the
            /// time `removeJobDependencies` runs, `tryFillAvailableSlots` won't be called again
            /// (`hasJobWithNoDependencies` is `false`), leaving the job permanently stuck.
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
        guard !canStartJobForVariants.isEmpty && canLoadFromDatabase else { return }
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
        let info: JobInfo = ((try? await dependencies[singleton: .storage].read { [jobVariants] db -> JobInfo in
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
            
            /// If the job exists in memory now then it means it was added during the async database read, the in-memory version
            /// is "live" whereas the database version is "stale" (even if only by a few ms) so we should ignore the one retrieved from
            /// the database
            ///
            /// **Note:** This is important to do because it's possible that `removeJobDependenices` was called while the
            /// query was running and a dependency has been removed from memory but not from the database. If we were to
            /// merge the dependencies and add this back to the in-memory job then we would be adding a "Ghost" dependency
            /// which would likely never get resolved causing the job to hang until the next restart
            guard allJobs[queueId] == nil else { continue }
            
            allJobs[queueId] = JobState(
                queueId: queueId,
                job: job,
                jobDependencies: (jobDependencyMap[job.id] ?? []),
                executionState: .pending,
                resultStream: CurrentValueAsyncStream(nil)
            )
        }
    }
    
    // MARK: - Execution Management
    
    func start(drainOnly: Bool) async {
        self.canStartJobForVariants = Set(jobVariants)
        self.canLoadFromDatabase = !drainOnly
        self.hasStartedAtLeastOnceSinceBecomingActive = true
        
        loadTask?.cancel()
        loadTask = nil
        
        if await _state.getCurrent() != .running {
            await _state.send(.running)
        }
        
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
        guard !canStartJobForVariants.isEmpty else {
            if hasStartedAtLeastOnceSinceBecomingActive {
                Log.info(.jobRunner, "JobQueue-\(type.name) ignoring attempt to fill slots due to queue being stopped.")
            }
            return
        }
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
                matching: JobRunner.Filters(
                    include: [.executionPhase(.pending)].appending(
                        contentsOf: canStartJobForVariants.map { .variant($0) }
                    )
                ),
                excludePendingJobsWhichCannotBeStarted: true
            )
            
            if !pendingJobs.isEmpty {
                var slotsRemaining: Int = availableSlots
                let needsStateUpdate: Bool = await (_state.getCurrent() != .running)
                var didStartJob: Bool = false
                
                for pendingJob in pendingJobs {
                    guard slotsRemaining > 0 else { break }
                    
                    /// Retrieve the executor for the job (it should always be there because the jobs gets validated in `sortedJobs`
                    guard let executor: JobExecutor.Type = executorMap[pendingJob.job.variant] else {
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
                        executor.canRunConcurrentlyWith(
                            runningJobs: runningJobs,
                            jobState: pendingJob,
                            using: dependencies
                        )
                    else { continue }
                    
                    /// We have passed the special concurrency check so start the job
                    startJob(queueId: pendingJob.queueId, executor: executor)
                    slotsRemaining -= 1
                    didStartJob = true
                }
                
                /// Update the state of the queue if needed
                if needsStateUpdate && didStartJob {
                    await _state.send(.running)
                }
            }
            else {
                let allPendingJobs: [JobState] = allJobs.values
                    .filter {
                        $0.executionState.phase == .pending &&
                        canStartJobForVariants.contains($0.job.variant)
                    }
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
                    let targetState: State = (allPendingJobs.count == 0 ? .drained : .pending)
                    
                    if await _state.getCurrent() != targetState {
                        await _state.send(targetState)
                    }
                }
                
                /// If there are still jobs in the queue but they are scheduled to run in the future then we should kick off a task to wait
                /// until they are ready to run
                if let nextRunTimestamp: TimeInterval = maybeNextRunTimestamp {
                    let secondsUntilNextJob: TimeInterval = (nextRunTimestamp - dependencies.dateNow.timeIntervalSince1970)
                    Log.info(.jobRunner, "Stopping JobQueue-\(type.name) until next job in \(secondsUntilNextJob)s")
                    
                    nextTriggerTask = Task { [weak self, dependencies] in
                        guard !Task.isCancelled else { return }
                        
                        /// Need to re-calculate this as tasks may not run immediately
                        let updatedSecondsUntilNextJob: TimeInterval = (nextRunTimestamp - dependencies.dateNow.timeIntervalSince1970)
                        
                        if updatedSecondsUntilNextJob > 0 {
                            try? await dependencies.sleep(
                                for: .milliseconds(Int(ceil(updatedSecondsUntilNextJob * 1000)))
                            )
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
        guard !canStartJobForVariants.isEmpty else { return }
        
        /// Ensure we have a pending job
        let pendingJobs: [JobState] = await sortedJobs(
            matching: JobRunner.Filters(
                include: [.executionPhase(.pending)].appending(
                    contentsOf: canStartJobForVariants.map { .variant($0) }
                )
            ),
            excludePendingJobsWhichCannotBeStarted: true
        )
        
        guard
            let highestPriorityPendingJob: JobState = pendingJobs.first,
            let highestPriorityPendingJobState: JobState = allJobs[highestPriorityPendingJob.queueId],
            highestPriorityPendingJobState.isPending,
            let highestPriorityPendingJobExecutor: JobExecutor.Type = executorMap[highestPriorityPendingJobState.job.variant]
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
            startJob(
                queueId: highestPriorityPendingJob.queueId,
                executor: highestPriorityPendingJobExecutor
            )
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
                case .timestamp: return ((dep.timestamp ?? 0) >= currentTimestamp)
                case .job, .configSync: return true
            }
        }
        allJobs[queueId] = jobState
        
        /// Kick off a task to remove the dependency from the database as well
        if let jobId: Int64 = jobState.job.id {
            Task.detached(priority: .high) { [dependencies] in
                try? await dependencies[singleton: .storage].write { db in
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
                guard let self else { return }
                
                try? await Task.sleep(for: completedJobCleanupDelay)
                await remove(jobFor: updatedJobState.queueId)
            }
        }
        
        /// Try to fill available slots (might start new jobs)
        await tryFillAvailableSlots()
    }
    
    // MARK: - State
    
    public func allowStartingJobs(for variants: Set<Job.Variant>) async {
        canStartJobForVariants.insert(contentsOf: variants.intersection(jobVariants))
        
        guard !canStartJobForVariants.isEmpty else { return }
        
        await tryFillAvailableSlots()
    }
    
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
    
    func resetHasStartedSinceBecomingActiveFlag() {
        hasStartedAtLeastOnceSinceBecomingActive = false
    }
    
    func disableLoadingNewJobsFromDatabaseUntilNextStart() {
        canLoadFromDatabase = false
    }
    
    func cancelAndClearJobs(filters: JobRunner.Filters) async {
        /// Cancel and remove any jobs matching the filters
        let initialJobStates: [JobQueueId: JobState] = allJobs
        
        for (_, state) in initialJobStates {
            if filters.matches(state) {
                if case .running(let task) = state.executionState {
                    task.cancel()
                }
                
                allJobs.removeValue(forKey: state.queueId)
            }
        }
        
        /// Remove any variants in the filters from `canStartJobForVariants`
        canStartJobForVariants = canStartJobForVariants.filter {
            !filters.matches([.variant($0)])
        }
        
        if allJobs.isEmpty {
            if await _state.getCurrent() != .drained {
                await _state.send(.drained)
            }
        }
    }
    
    func stopAndClear() async {
        let wasRunning: Bool = (
            loadTask != nil ||
            !allJobs.isEmpty ||
            !canStartJobForVariants.isEmpty ||
            canLoadFromDatabase
        )
        
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
        canStartJobForVariants = []
        
        if await _state.getCurrent() != .drained {
            await _state.send(.drained)
        }
        
        if wasRunning {
            Log.info(.jobRunner, "Stopped and cleared JobQueue-\(type.name)")
        }
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
        /// Retrieve all of the values required to determine whether jobs are ready to run
        let appIsInForeground: Bool = await dependencies[singleton: .appContext].isMainAppAndActive
        let jobQueueIdsWithPendingDependencies: [JobQueueId: Int] = dependencies[singleton: .jobRunner]
            .jobDependencyCoordinator
            .pendingAdditions
        let jobsToCheck: [JobState] = Array(allJobs.values)
        
        let currentTimestamp: TimeInterval = dependencies.dateNow.timeIntervalSince1970
        var candidates: [JobState] = []
        var invalidJobs: [(JobState, JobExecutionPrecheckResult)] = []
        candidates.reserveCapacity(jobsToCheck.count)
        invalidJobs.reserveCapacity(jobsToCheck.count)
        
        /// We **MUST** avoid async processing in this loop as doing so can introduce race-conditions where jobs which should
        /// have dependencies may not have them added at the time they are processed by the loop
        for state in jobsToCheck {
            guard filters.matches(state) else { continue }
            
            /// If we are just inspecting (ie. not trying to fill slots) then we can just add the job
            if !excludePendingJobsWhichCannotBeStarted || state.executionState.phase != .pending {
                candidates.append(state)
                continue
            }
            
            let validationResult: JobExecutionPrecheckResult = validateJobForExecution(
                state,
                pendingDependencyCounts: jobQueueIdsWithPendingDependencies,
                currentTimestamp: currentTimestamp
            )
            
            switch validationResult {
                case .ready(let executor):
                    /// Check if the app is in the foreground or whether the job can run in the background
                    if executor.requiresForeground && !appIsInForeground {
                        continue
                    }
                    candidates.append(state)
                    
                case .deferUntilDependenciesMet:
                    /// Keep the `lastAttempt` info if we are continuing a deferral (don't want to lose the last attempt info)
                    var updatedState: JobState = state
                    updatedState.executionState = {
                        switch state.executionState {
                            case .pending(let lastAttempt): return .pending(lastAttempt: lastAttempt)
                            default:
                                /// Only log if we don't have a `lastAttempt` (otherwise this log will be added every time
                                /// we call `sortedJobs` for this queue resulting in excessive logs)
                                Log.info(.jobRunner, "JobQueue-\(type.name) Deferring \(state.job) until \(state.jobDependencies.count) dependencies are completed")
                                return .pending(lastAttempt: nil)
                        }
                    }()
                    allJobs[state.queueId] = updatedState
                    invalidJobs.append((state, validationResult))
                    
                case .permanentlyFail(let error):
                    Log.info(.jobRunner, "JobQueue-\(type.name) Failing \(state.job) due to validation error: \(error)")
                    
                    var updatedState: JobState = state
                    updatedState.executionState = .completed(
                        result: .failed(error, isPermanent: true)
                    )
                    allJobs[state.queueId] = updatedState
                    invalidJobs.append((state, validationResult))
            }
        }
        
        /// If we had invalid jobs then kick off a task to process them (don't want to block the `sortedJobs` logic to do so)
        if !invalidJobs.isEmpty {
            Task { [weak self, dependencies, invalidJobs] in
                /// Use the specified timestamp or fallback to waiting for `defaultDeferralDelay`
                let deferralTimestamp: TimeInterval = (dependencies.dateNow.timeIntervalSince1970 + JobQueue.defaultDeferralDelay)
                
                var actions: [DatabaseAction] = []
                actions.reserveCapacity(invalidJobs.count)
                
                for (state, validationResult) in invalidJobs {
                    switch validationResult {
                        case .ready: break  /// Invalid case
                        case .permanentlyFail: actions.append(.permanentFailure(state.job))
                        case .deferUntilDependenciesMet:
                            /// If the job doesn't already have `jobDependenices` then add a `timestamp` one
                            if state.jobDependencies.isEmpty {
                                actions.append(.deferral(state.job, waitUntil: deferralTimestamp))
                            }
                    }
                }
                
                await self?.executeDatabaseActions(actions)
            }
        }
        
        /// No need to sort or fetch the data required for sorting if we only have 1 (or 0) jobs
        guard candidates.count > 1 else {
            return candidates
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
            
            return ((try? await dependencies[singleton: .storage].read { db in
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
            try await dependencies[singleton: .storage].write { [dependencies] db in
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
        
        await executeDatabaseActions([.permanentFailure(jobState.job)])
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
        await executeDatabaseActions([
            .transientFailure(updatedJob: updatedJob, waitUntil: nextRunTimestamp)
        ])
        
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
        
        /// Use the specified timestamp or fallback to waiting for `defaultDeferralDelay`
        let targetTimestamp: TimeInterval = (
            nextRunTimestamp ??
            (dependencies.dateNow.timeIntervalSince1970 + JobQueue.defaultDeferralDelay)
        )
        await executeDatabaseActions([.deferral(jobState.job, waitUntil: targetTimestamp)])
        return jobState.job
    }
    
    private func executeDatabaseActions(_ actions: [DatabaseAction]) async {
        guard !actions.isEmpty else { return }
        
        do {
            try await dependencies[singleton: .storage].write { [dependencies] db in
                var cascadedDeletedJobIds: Set<Int64> = []
                
                for action in actions {
                    switch action {
                        case .permanentFailure(let job):
                            /// If the job permanently failed or we have performed all of our retry attempts then delete the job
                            /// and all of it's dependant jobs (it'll probably never succeed)
                            guard let jobId: Int64 = job.id else { continue }
                                                    
                            let jobIdsThatWereDepenantOnThisJob: Set<Int64> = dependencies[singleton: .jobRunner]
                                .removeJobDependencies(db, .job(jobId))
                            cascadedDeletedJobIds.formUnion(jobIdsThatWereDepenantOnThisJob)
                            cascadedDeletedJobIds.insert(jobId)
                            
                        case .deferral(let job, let nextRunTimestamp):
                            guard let jobId: Int64 = job.id else { continue }
                            
                            try dependencies[singleton: .jobRunner].addJobDependency(
                                db,
                                .timestamp(jobId: jobId, waitUntil: nextRunTimestamp)
                            )
                            
                        case .transientFailure(let updatedJob, let nextRunTimestamp):
                            guard let jobId = updatedJob.id else { continue }
                                                    
                            _ = try updatedJob.upserted(db)
                            
                            try dependencies[singleton: .jobRunner].addJobDependency(
                                db,
                                .timestamp(jobId: jobId, waitUntil: nextRunTimestamp)
                            )
                    }
                }
                
                if !cascadedDeletedJobIds.isEmpty {
                    _ = try Job.deleteAll(db, ids: cascadedDeletedJobIds)
                
                    db.afterCommit { [dependencies] in
                        Task { [dependencies] in
                            for jobId in cascadedDeletedJobIds {
                                await dependencies[singleton: .jobRunner].removePendingJob(jobId)
                            }
                        }
                    }
                }
            }
        } catch {
            Log.error(.jobRunner, "Failed to execute batch database actions: \(error)")
        }
    }
    
    // MARK: - Conenience

    private func validateJobForExecution(
        _ jobState: JobState,
        pendingDependencyCounts: [JobQueue.JobQueueId: Int],
        currentTimestamp: TimeInterval
    ) -> JobExecutionPrecheckResult {
        /// If we have pending (to be added) dependencies then we should just defer as we don't know when they will be resolved
        if pendingDependencyCounts[jobState.queueId] != nil {
            return .deferUntilDependenciesMet
        }
        
        guard let executor: JobExecutor.Type = executorMap[jobState.job.variant] else {
            Log.info(.jobRunner, "JobQueue-\(type.name) Unable to run \(jobState.job) due to missing executor")
            return .permanentlyFail(error: JobRunnerError.executorMissing)
        }
        
        /// Validate the job has any required ids
        if executor.requiresThreadId && jobState.job.threadId == nil {
            return .permanentlyFail(error: JobRunnerError.requiredThreadIdMissing)
        }
        
        if executor.requiresInteractionId && jobState.job.interactionId == nil {
            return .permanentlyFail(error: JobRunnerError.requiredInteractionIdMissing)
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
            return .deferUntilDependenciesMet
        }
        
        return .ready(executor)
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
    struct JobQueueId: Equatable, Hashable, Comparable, CustomStringConvertible {
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
        
        public var description: String {
            return "JobQueueId(databaseId: \(String(describing: databaseId)), transientId: \(String(describing: transientId)))"
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
        case ready(JobExecutor.Type)
        case permanentlyFail(error: Error)
        case deferUntilDependenciesMet
    }
}

// MARK: - DatabaseAction

private extension JobQueue {
    enum DatabaseAction {
        case permanentFailure(Job)
        case deferral(Job, waitUntil: TimeInterval)
        
        /// Persists the updated job state (eg. failure count) AND adds a timestamp dependency
        case transientFailure(updatedJob: Job, waitUntil: TimeInterval)
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
