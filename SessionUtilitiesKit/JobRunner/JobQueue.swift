// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB

public actor JobQueue: Hashable {
    private static let deferralLoopThreshold: Int = 3
    
    private let dependencies: Dependencies
    nonisolated private let id: UUID = UUID()
    internal let type: QueueType
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
            Log.info(.jobRunner, "Prevented attempt to add \(job) without id to queue")
            return
        }
        
        /// Upsert the job as long as it's not currently running
        if allJobs[queueId] == nil || allJobs[queueId]?.status.erasedStatus != .running {
            allJobs[queueId] = JobState(
                queueId: queueId,
                job: job,
                jobDependencies: [],
                status: (allJobs[queueId]?.status ?? .pending),
                resultStream: CurrentValueAsyncStream(nil)
            )
        }
        
        /// Fill available execution slots if there are any
        await tryFillAvailableSlots()
    }
    
    func update(_ job: Job) async {
        guard let queueId: JobQueueId = JobQueueId(databaseId: job.id, transientId: nil, queueSizeAtCreation: allJobs.count) else {
            Log.info(.jobRunner, "Failed to update \(job) without id to queue")
            return
        }
        
        /// Only update the job if it's still pending
        guard
            let oldState: JobState = allJobs[queueId],
            case .pending = oldState.status
        else { return }
        
        allJobs[queueId] = JobState(
            queueId: queueId,
            job: job,
            jobDependencies: oldState.jobDependencies,
            status: oldState.status,
            resultStream: oldState.resultStream
        )
    }
    
    /// Indicate that another job needs to be completed before this job can be started
    func addJobDependencies(_ jobDependencies: Set<JobDependency>) async {
        jobDependencies.forEach { jobDependency in
            guard
                let queueId: JobQueueId = JobQueueId(databaseId: jobDependency.jobId),
                var jobState: JobState = allJobs[queueId]
            else { return }
            
            jobState.jobDependencies.append(jobDependency)
            allJobs[queueId] = jobState
        }
    }
    
    /// Remove the dependency from a job in the queue
    func removeJobDependencies(_ jobDependencies: [JobDependency]) async {
        var hasJobWithNoDependencies: Bool = false
        
        for jobDependency in jobDependencies {
            guard
                let queueId: JobQueueId = JobQueueId(databaseId: jobDependency.jobId),
                var jobState: JobState = allJobs[queueId]
            else { return }
            
            jobState.jobDependencies = jobState.jobDependencies.filter { $0 != jobDependency }
            allJobs[queueId] = jobState
            
            if jobState.jobDependencies.isEmpty {
                hasJobWithNoDependencies = true
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
                    status: .pending,
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
        guard canStartJobs else { return }
        
        let runningCount: Int = allJobs.values.filter(\.isRunning).count
        let availableSlots: Int = (executionType.limit - runningCount)
        
        /// If there are no slots available then check if there are any lower priority jobs which can be cancelled and rerun later
        guard availableSlots > 0 else {
            await tryPreemptLowerPriorityJobs()
            return
        }
        
        /// Cancel any `nextTriggerTask` since we are trying to load new jobs (if none are ready then we will schedule a new one)
        nextTriggerTask?.cancel()
        nextTriggerTask = nil
        
        /// Get pending jobs sorted by priority and start jobs until we hit the limit
        let pendingJobs: [JobState] = await sortedJobs(
            matching: JobRunner.Filters(include: [.status(.pending)]),
            excludePendingJobsWhichCannotBeStarted: true
        )
        
        /// If there are no more pending jobs then the queue has been drained
        guard !pendingJobs.isEmpty else {
            await _state.send(allJobs.isEmpty ? .drained : .pending)
            
            /// If there are still jobs in the queue but they are scheduled to run in the future then we should kick off a task to wait
            /// until they are ready to run
            var maybeSecondsUntilNextJob: TimeInterval?
            
            for state in allJobs.values {
                guard state.job.nextRunTimestamp != 0 else { continue }
                
                maybeSecondsUntilNextJob = min(
                    state.job.nextRunTimestamp,
                    (maybeSecondsUntilNextJob ?? TimeInterval.greatestFiniteMagnitude)
                )
            }
            
            if let secondsUntilNextJob: TimeInterval = maybeSecondsUntilNextJob {
                Log.info(.jobRunner, "Stopping JobQueue-\(type.name) until next job in \(secondsUntilNextJob)s")
                nextTriggerTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(Int(floor(secondsUntilNextJob))))
                    guard !Task.isCancelled else { return }
                    
                    await self?.loadPendingJobsFromDatabase()
                    guard !Task.isCancelled else { return }
                    
                    await self?.tryFillAvailableSlots()
                }
            }
            return
        }
        
        for job in pendingJobs.prefix(availableSlots) {
            startJob(queueId: job.queueId)
        }
    }
    
    private func tryPreemptLowerPriorityJobs() async {
        guard canStartJobs else { return }
        
        /// Ensure we have a pending job
        let pendingJobs: [JobState] = await sortedJobs(
            matching: JobRunner.Filters(include: [.status(.pending)]),
            excludePendingJobsWhichCannotBeStarted: true
        )
        
        guard
            let highestPriorityPendingJob: JobState = pendingJobs.first,
            let highestPriorityPendingJobState: JobState = allJobs[highestPriorityPendingJob.queueId],
            highestPriorityPendingJobState.isPending
        else { return }
        
        /// Check if the lowest priority running job can be preempted and
        let runningJobs: [JobState] = await sortedJobs(
            matching: JobRunner.Filters(include: [.status(.running)]),
            excludePendingJobsWhichCannotBeStarted: true
        )
        
        guard
            let lowestPriorityRunningJob: JobState = runningJobs.last,
            let executor: JobExecutor.Type = executorMap[lowestPriorityRunningJob.job.variant],
            executor.canBePreempted
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
            case .running(let task) = state.status
        {
            Log.info(.jobRunner, "JobQueue-\(type.name) preempting \(lowestPriorityRunningJob) for higher priority \(highestPriorityPendingJob)")
            
            task.cancel()
            
            /// Mark as pending again so it can be retried later
            allJobs[state.queueId] = JobState(
                queueId: state.queueId,
                job: state.job,
                jobDependencies: state.jobDependencies,
                status: .pending,
                resultStream: state.resultStream
            )
            
            /// Now start the higher priority job
            startJob(queueId: highestPriorityPendingJob.queueId)
        }
    }
    
    private func startJob(queueId: JobQueueId) {
        guard var jobState: JobState = allJobs[queueId], jobState.isPending else { return }
        
        let task = Task(priority: priority) {
            await executeJob(jobState, queueId: queueId)
            await completeJob(queueId: queueId)
        }
        
        jobState.status = .running(task: task)
        allJobs[queueId] = jobState
    }
    
    private func completeJob(queueId: JobQueueId) async {
        guard allJobs[queueId] != nil else { return }
        
        /// Job completion is handled in `executeJob`, just trigger refill
        await tryFillAvailableSlots()
    }
    
    private func executeJob(_ jobState: JobState, queueId: JobQueueId) async {
        /// Ensure the job has everything is needs before trying to start it
        let executor: JobExecutor.Type
        let precheckResult: JobExecutionPrecheckResult = await prepareToExecute(jobState)
        
        switch precheckResult {
            case .permanentlyFail(let error):
                await handleJobFailed(jobState.job, error: error, permanentFailure: true)
                return
                
            case .deferUntilDependenciesMet:
                await handleJobDeferred(jobState.queueId, jobState.job)
                return
                
            case .ready(let targetExecutor): executor = targetExecutor
        }
        
        /// Wait for the task to complete
        let executionOutcome: Result<JobExecutionResult, Error> = await Result {
            try await executor.run(jobState.job, using: dependencies)
        }
        let finalResult: JobRunner.JobResult
        
        switch executionOutcome {
            case .success(let result):
                await handleJobResult(result, jobState.queueId, jobState.job)
                finalResult = result.publicResult
                
            case .failure(let error):
                let isPermanent: Bool = ((error as? JobError)?.isPermanent ?? false)
                await handleJobFailed(jobState.job, error: error, permanentFailure: isPermanent)
                finalResult = .failed(error, isPermanent)
        }
        
        /// Cleanup after the job is finished
        Log.info(.jobRunner, "JobQueue-\(type.name) finished \(jobState.job)")
        await finalizeJob(queueId: queueId, result: finalResult)
    }
    
    private func finalizeJob(queueId: JobQueueId, result: JobRunner.JobResult) async {
        guard var jobState: JobState = allJobs[queueId] else { return }
        
        /// Update status
        jobState.status = .completed(result: result)
        allJobs[queueId] = jobState
        
        /// Notify result stream
        await jobState.resultStream.send(result)
        
        /// Remove any dependencies on this job
        _ = try? await dependencies[singleton: .storage].writeAsync { [dependencies] db in
            dependencies[singleton: .jobRunner].removeJobDependency(
                db,
                variant: .job,
                jobId: jobState.job.id,
                threadId: nil
            )
        }
        
        /// Keep completed jobs around briefly for result observation (to avoid a race condition where a job can complete before an
        /// observer can start observing the result), then clean up
        Task {
            try? await Task.sleep(for: .seconds(5))
            allJobs.removeValue(forKey: queueId)
        }
    }
    
    // MARK: - State
    
    func hasJob(jobId: Int64) async -> Bool {
        guard let queueId: JobQueueId = JobQueueId(databaseId: jobId) else { return false }
        
        return (allJobs[queueId] != nil)
    }
    
    func status(for jobId: Int64) async -> JobRunner.JobStatus? {
        guard let queueId: JobQueueId = JobQueueId(databaseId: jobId) else { return nil }
        
        return allJobs[queueId]?.status.erasedStatus
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
    
    func awaitResult(for queueId: JobQueueId) async -> JobRunner.JobResult {
        /// Check if already completed
        if case .completed(let result) = allJobs[queueId]?.status {
            return result
        }
        
        /// Otherwise wait for result
        guard let stream: CurrentValueAsyncStream<JobRunner.JobResult?> = allJobs[queueId]?.resultStream else {
            return .notFound
        }
        
        for await result in stream.stream.compactMap({ $0 }) {
            return result
        }
        
        return .notFound
    }
    
    func deferCount(for jobId: Int64) -> Int {
        guard let queueId: JobQueueId = JobQueueId(databaseId: jobId) else { return 0 }
        
        return (deferLoopTracker[queueId]?.count ?? 0)
    }
    // TODO: [JOBRUNNER] Probably need a function which just sets 'canLoadFromDatabase' but doesn't cancel everything (eg. to finish sending a message with an attachment after entering the background)
    func stopAndClear() {
        /// Cancel the load task first to prevent race conditions
        loadTask?.cancel()
        loadTask = nil
        
        /// Cancel all running jobs
        for (_, state) in allJobs {
            if case .running(let task) = state.status {
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
        var candidates: [JobState] = []
        candidates.reserveCapacity(allJobs.count)
        
        for state in allJobs.values {
            guard filters.matches(state) else { continue }
            
            /// If we are looking for `pending` jobs then ensure they can be started
            if excludePendingJobsWhichCannotBeStarted && state.status.erasedStatus == .pending {
                guard
                    state.job.nextRunTimestamp <= dependencies.dateNow.timeIntervalSince1970,
                    state.jobDependencies.isEmpty
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
    
    // MARK: - Result Handling
    
    private func handleJobResult(_ result: JobExecutionResult, _ queueId: JobQueueId, _ job: Job) async {
        switch result {
            case .success: await handleJobSucceeded(job)
            case .deferred(let updatedJob): await handleJobDeferred(queueId, updatedJob)
        }
    }
    
    private func handleJobSucceeded(_ job: Job) async {
        do {
            /// Call to the `JobRunner` to remove the job if it was dependency for any other job, this will also start any jobs that
            /// have no other dependencies and no other jobs in their queues
            try await dependencies[singleton: .storage].writeAsync { [dependencies] db in
                dependencies[singleton: .jobRunner].removeJobDependency(
                    db,
                    variant: .job,
                    jobId: job.id,
                    threadId: nil
                )
                _ = try? job.delete(db)
            }
        } catch {
            Log.error(.jobRunner, "Failed to process successful job \(job) in database: \(error)")
        }
    }

    private func handleJobFailed(_ job: Job, error: Error, permanentFailure: Bool) async {
        let jobExists: Bool? = try? await dependencies[singleton: .storage].readAsync { db in
            try Job.exists(db, id: job.id ?? -1)
        }
        
        guard jobExists == true else {
            Log.info(.jobRunner, "JobQueue-\(type.name) \(job) canceled")
            return
        }
        
        if self.type == .blocking && (error as? JobRunnerError)?.wasPossibleDeferralLoop != true {
             Log.info(.jobRunner, "JobQueue-\(type.name) \(job) failed due to error: \(error); retrying immediately")
            Task { await tryFillAvailableSlots() }
            return
        }
        
        /// Get the max failure count for the job (a value of '-1' means it will retry indefinitely)
        let maxFailureCount: Int = (executorMap[job.variant]?.maxFailureCount ?? 0)
        let tooManyRetries: Bool = (maxFailureCount >= 0 && (job.failureCount + 1) > maxFailureCount)
        let isPermanent: Bool = (permanentFailure || tooManyRetries)
        
        do {
            try await dependencies[singleton: .storage].writeAsync { [type, dependencies] db in
                guard !isPermanent else {
                    Log.error(.jobRunner, "JobQueue-\(type.name) \(job) failed permanently due to error: \(error)\(tooManyRetries ? "; too many retries" : "")")
                    
                    /// If the job permanently failed or we have performed all of our retry attempts then delete the job and all of it's
                    /// dependant jobs (it'll probably never succeed)
                    let jobDependencies: [JobDependency] = dependencies[singleton: .jobRunner].removeJobDependency(
                        db,
                        variant: .job,
                        jobId: job.id,
                        threadId: nil
                    )
                    
                    _ = try Job.deleteAll(db, ids: Set(jobDependencies.map { $0.jobId }))
                    _ = try job.delete(db)
                    
                    db.afterCommit {
                        Task { [dependencies] in
                            for dependency in jobDependencies {
                                await dependencies[singleton: .jobRunner].removePendingJob(dependency.jobId)
                            }
                        }
                    }
                    return
                }
                
                let updatedFailureCount: UInt = (job.failureCount + 1)
                let nextRunTimestamp: TimeInterval = (dependencies.dateNow.timeIntervalSince1970 + job.retryInterval)
                Log.error(.jobRunner, "JobQueue-\(type.name) \(job) failed due to error: \(error); scheduling retry (failure count is \(updatedFailureCount))")
                
                let updatedJob: Job = job.with(
                    failureCount: updatedFailureCount,
                    nextRunTimestamp: nextRunTimestamp
                )
                _ = try updatedJob.upserted(db)
                
                /// Update the `failureCount` and `nextRunTimestamp` on dependant jobs as well (update the
                /// `nextRunTimestamp` value to be 1ms later so when the queue gets regenerated they'll come after the dependency)
                let jobDependencies: [JobDependency] = dependencies[singleton: .jobRunner].removeJobDependency(
                    db,
                    variant: .job,
                    jobId: job.id,
                    threadId: nil
                )
                let jobs: [Job] = try Job.fetchAll(db, ids: Set(jobDependencies.map { $0.jobId }))
                
                for job in jobs {
                    try dependencies[singleton: .jobRunner].update(
                        db,
                        job: job.with(
                            failureCount: updatedFailureCount,
                            nextRunTimestamp: (nextRunTimestamp + (1 / 1000))
                        )
                    )
                }
            }
        }
        catch {
            Log.error(.jobRunner, "Failed to update database for failed job \(job): \(error)")
        }
    }
    
    private func handleJobDeferred(_ queueId: JobQueueId, _ job: Job) async {
        var stuckInDeferLoop: Bool = false
        
        if let record: (count: Int, times: [TimeInterval]) = deferLoopTracker[queueId] {
            let timeNow: TimeInterval = dependencies.dateNow.timeIntervalSince1970
            stuckInDeferLoop = (
                record.count >= JobQueue.deferralLoopThreshold &&
                (timeNow - record.times[0]) < CGFloat(record.count * maxDeferralsPerSecond)
            )
            
            /// Only store the last `deferralLoopThreshold` times to ensure we aren't running faster than one loop per second
            deferLoopTracker[queueId] = (
                record.count + 1,
                record.times.suffix(JobQueue.deferralLoopThreshold - 1) + [timeNow]
            )
        } else {
            deferLoopTracker[queueId] = (1, [dependencies.dateNow.timeIntervalSince1970])
        }
        
        /// It's possible (by introducing bugs) to create a loop where a `Job` tries to run and immediately defers itself but then attempts
        /// to run again (resulting in an infinite loop); this won't block the app since it's on a background thread but can result in 100% of
        /// a CPU being used (and a battery drain)
        ///
        /// This code will maintain an in-memory store for any jobs which are deferred too quickly (ie. more than `deferralLoopThreshold`
        /// times within `deferralLoopThreshold` seconds)
        if stuckInDeferLoop {
            deferLoopTracker.removeValue(forKey: queueId)
            await handleJobFailed(job, error: JobRunnerError.possibleDeferralLoop, permanentFailure: false)
        }
        
        do {
            try await dependencies[singleton: .storage].writeAsync { db in
                _ = try job.upserted(db)
            }
        } catch {
            Log.error(.jobRunner, "Failed to save deferred job \(job): \(error)")
        }
    }
    
    // MARK: - Conenience

    private func prepareToExecute(_ jobState: JobState) async -> JobExecutionPrecheckResult {
        guard let executor: JobExecutor.Type = executorMap[jobState.job.variant] else {
            Log.info(.jobRunner, "JobQueue-\(type.name) Unable to run \(jobState.job) due to missing executor")
            return .permanentlyFail(error: JobRunnerError.executorMissing)
        }
        guard !executor.requiresThreadId || jobState.job.threadId != nil else {
            Log.info(.jobRunner, "JobQueue-\(type.name) Unable to run \(jobState.job) due to missing required threadId")
            return .permanentlyFail(error: JobRunnerError.requiredThreadIdMissing)
        }
        guard !executor.requiresInteractionId || jobState.job.interactionId != nil else {
            Log.info(.jobRunner, "JobQueue-\(type.name) Unable to run \(jobState.job) due to missing required interactionId")
            return .permanentlyFail(error: JobRunnerError.requiredInteractionIdMissing)
        }
        
        /// Make sure there are no dependencies for the job
        guard jobState.jobDependencies.isEmpty else {
            Log.info(.jobRunner, "JobQueue-\(type.name) Deferring \(jobState.job) until \(jobState.jobDependencies.count) dependencies are completed")
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
        
        fileprivate var jobSorter: (([JobState], JobPriorityContext, Any?) async -> [JobState]) {
            switch self {
                case .blocking, .startupProcesses: return JobSorter.unsorted
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
        
        // MARK: - --Comparable
        
        public static func == (lhs: JobQueueId, rhs: JobQueueId) -> Bool {
            return (
                lhs.databaseId == rhs.databaseId &&
                lhs.transientId == rhs.transientId
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

// MARK: - SortableJob

private extension JobQueue {
    struct SortableJob: Equatable {
        let id: JobQueueId
        let job: Job
        let executor: JobExecutor.Type
        
        public static func == (lhs: SortableJob, rhs: SortableJob) -> Bool {
            return (
                lhs.id == rhs.id &&
                lhs.job == rhs.job
            )
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
