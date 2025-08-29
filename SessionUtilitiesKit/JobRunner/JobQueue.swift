// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB

public actor JobQueue: Hashable {
    private static let deferralLoopThreshold: Int = 3
    
    private let dependencies: Dependencies
    nonisolated private let id: UUID = UUID()
    private let type: QueueType
    private let executionType: ExecutionType
    private let priority: TaskPriority
    nonisolated public let jobVariants: [Job.Variant]
    private let maxDeferralsPerSecond: Int
    
    private var executorMap: [Job.Variant: JobExecutor.Type] = [:]
    private var pendingJobsQueue: [Job] = []
    private var currentlyRunningJobs: [Int64: (info: JobRunner.JobInfo, task: Task<JobExecutionResult, Error>)] = [:]
    private var deferLoopTracker: [Int64: (count: Int, times: [TimeInterval])] = [:]
    
    private var processingTask: Task<Void, Never>? = nil
    private var nextTriggerTask: Task<Void, Never>? = nil
    
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
    
    // MARK: - State
    
    func infoForAllCurrentlyRunningJobs() -> [Int64: JobRunner.JobInfo] {
        return currentlyRunningJobs.mapValues { $0.info }
    }
    
    func infoForAllPendingJobs() -> [Int64: JobRunner.JobInfo] {
        pendingJobsQueue.reduce(into: [:]) { result, job in
            guard let jobId: Int64 = job.id else { return }
            
            result[jobId] = JobRunner.JobInfo(job: job)
        }
    }
    
    // MARK: - Scheduling
    
    @discardableResult func add(_ job: Job, canStart: Bool) -> Bool {
        /// Check if the job should be added to the queue
        guard
            canStart,
            job.behaviour != .runOnceNextLaunch,
            job.nextRunTimestamp <= dependencies.dateNow.timeIntervalSince1970
        else { return false }
        guard job.id != nil else {
            Log.info(.jobRunner, "Prevented attempt to add \(job) without id to queue")
            return false
        }
        
        pendingJobsQueue.append(job)
        start(canStart: canStart, drainOnly: false)
        return true
    }
    
    @discardableResult func upsert(_ job: Job, canStart: Bool) -> Bool {
        guard let jobId: Int64 = job.id else {
            Log.warn(.jobRunner, "Prevented attempt to upsert \(job) without id to queue")
            return false
        }
        
        /// If the job is currently running, we can't update it
        guard currentlyRunningJobs[jobId] == nil else {
            Log.warn(.jobRunner, "Prevented attempt to upsert a currently running job: \(job)")
            return false
        }
        
        /// If it's already in the queue then just update the existing job
        if let index: Array<Job>.Index = pendingJobsQueue.firstIndex(where: { $0.id == jobId }) {
            pendingJobsQueue[index] = job
            start(canStart: canStart, drainOnly: false)
            return true
        }
        
        /// Otherwise add it to the queue
        return add(job, canStart: canStart)
    }
    
    @discardableResult func insert(_ job: Job, before otherJob: Job) -> Bool {
        guard job.id != nil else {
            Log.info(.jobRunner, "Prevented attempt to insert \(job) without id to queue")
            return false
        }

        /// Insert the job before the current job (re-adding the current job to the start of the `pendingJobsQueue` if it's not in
        /// there) - this will mean the new job will run and then the `otherJob` will run (or run again) once it's done
        if let otherJobIndex: Array<Job>.Index = pendingJobsQueue.firstIndex(of: otherJob) {
            pendingJobsQueue.insert(job, at: otherJobIndex)
            return true
        }
        
        /// The `otherJob` wasn't already in the queue so just add them both at the start (we add at the start because generally
        /// this function only gets called when dealing with dependencies at runtime - ie. in situations where we would want the jobs
        /// to run immediately)
        pendingJobsQueue.insert(contentsOf: [job, otherJob], at: 0)
        return true
    }
    
    func enqueueDependencies(_ jobs: [Job]) {
        let jobIdsToMove: Set<Int64> = Set(jobs.compactMap { $0.id })
        
        /// Pull out any existing jobs that need to be prioritised
        var existingJobs: [Job] = []
        pendingJobsQueue.removeAll { job in
            if jobIdsToMove.contains(job.id ?? -1) {
                existingJobs.append(job)
                return true
            }
            
            return false
        }
        
        /// Use the instances of jobs that were already in the queue (in case they have state that is relevant)
        let jobsToPrepend: [Job] = jobs.reduce(into: []) { result, next in
            result.append(existingJobs.first(where: { $0.id == next.id }) ?? next)
        }
        
        pendingJobsQueue.insert(contentsOf: jobsToPrepend, at: 0)
    }
    
    func removePendingJob(_ jobId: Int64?) {
        guard let jobId: Int64 = jobId else { return }
        
        pendingJobsQueue.removeAll { $0.id == jobId }
    }
    
    func addJobsFromLifecycle(_ jobs: [Job], canStart: Bool) {
        let currentJobIds: Set<Int64> = Set(pendingJobsQueue.compactMap(\.id) + currentlyRunningJobs.keys)
        let newJobs: [Job] = jobs.filter { !currentJobIds.contains($0.id ?? -1) }
        pendingJobsQueue.append(contentsOf: newJobs)
        start(canStart: canStart, drainOnly: false)
    }
    
    func drainInBackground() -> Task<Void, Never>? {
        return start(canStart: true, drainOnly: true)
    }
    
    // MARK: - Execution Management
    
    @discardableResult func start(canStart: Bool, drainOnly: Bool) -> Task<Void, Never>? {
        guard canStart, processingTask == nil else { return processingTask }
        
        /// Cancel any scheduled future work (since we are starting now)
        nextTriggerTask?.cancel()
        nextTriggerTask = nil
        
        Log.info(.jobRunner, "Starting JobQueue-\(type.name)... (Drain only: \(drainOnly))")
        
        processingTask = Task(priority: priority) {
            await processQueue(drainOnly: drainOnly)
            processingTask = nil
            Log.info(.jobRunner, "JobQueue-\(type.name) has drained and is now idle")
        }
        
        return processingTask
    }
    
    func stopAndClear() {
        nextTriggerTask?.cancel()
        nextTriggerTask = nil
        processingTask?.cancel()
        processingTask = nil
        
        /// Cancel all individual jobs that are currently running
        currentlyRunningJobs.values.forEach { _, task in task.cancel() }
        
        /// Clear the state
        currentlyRunningJobs.removeAll()
        pendingJobsQueue.removeAll()
        deferLoopTracker.removeAll()
        
        Log.info(.jobRunner, "Stopped and cleared JobQueue-\(type.name)")
    }
    
    func deferCount(for jobId: Int64) -> Int {
        return (deferLoopTracker[jobId]?.count ?? 0)
    }
    
    func matches(filters: JobRunner.Filters) -> Bool {
        /// A queue matches if *any* of its variants match the filter
        for variant in jobVariants {
            let pseudoInfo: JobRunner.JobInfo = JobRunner.JobInfo(
                id: nil,
                variant: variant,
                threadId: nil,
                interactionId: nil,
                detailsData: nil
            )
            
            if filters.matches(pseudoInfo) {
                return true
            }
        }
        
        return false
    }
    
    // MARK: - Processing Loop
    
    private func processQueue(drainOnly: Bool) async {
        /// If we aren't just draining the queue then load and add any pending jobs from the database into the queue
        if !drainOnly {
            await loadPendingJobsFromDatabase()
        }
        
        while let nextJob: Job = fetchNextJob() {
            guard !Task.isCancelled else { break }
            
            switch executionType {
                case .serial:
                    /// Wait for each task to be complete
                    await executeJob(nextJob)
                    
                case .concurrent:
                    /// Spin up an individual task for each job
                    Task { await executeJob(nextJob) }
            }
        }
        
        /// If we aren't just draining the queue then when it's empty we should schedule the next job based on `nextRunTimestamp`
        if !drainOnly {
            await scheduleNextSoonestJob()
        }
    }
    
    private func fetchNextJob() -> Job? {
        guard !pendingJobsQueue.isEmpty else { return nil }
        
        return pendingJobsQueue.removeFirst()
    }
    
    private func executeJob(_ job: Job) async {
        guard
            let jobId: Int64 = job.id,
            let executor: (any JobExecutor.Type) = executorMap[job.variant]
        else {
            await handleJobFailed(job, error: JobRunnerError.executorMissing, permanentFailure: true)
            return
        }
        
        /// Ensure the job has everything is needs before trying to start it
        let precheckResult: JobExecutionPrecheckResult = await prepareToExecute(job)
        
        switch precheckResult {
            case .permanentlyFail(let error):
                await handleJobFailed(job, error: error, permanentFailure: true)
                return
                
            case .deferUntilDependenciesMet:
                await handleJobDeferred(job)
                return
                
            case .ready: break
        }
        
        /// Create a task to execute the job (this allows us to cancel if needed without impacting the queue)
        let jobTask: Task<JobExecutionResult, Error> = Task {
            try await executor.run(job, using: dependencies)
        }
        
        /// Track the running job
        currentlyRunningJobs[jobId] = (info: JobRunner.JobInfo(job: job), task: jobTask)
        Log.info(.jobRunner, "JobQueue-\(type.name) started \(job)")
        
        /// Wait for the task to complete
        let executionOutcome: Result<JobExecutionResult, Error> = await jobTask.result
        let finalResult: JobRunner.JobResult
        
        switch executionOutcome {
            case .success(let result):
                await handleJobResult(result)
                finalResult = result.publicResult
                
            case .failure(let error):
                let isPermanent: Bool = (error as? JobError)?.isPermanent ?? false
                await handleJobFailed(job, error: error, permanentFailure: isPermanent)
                finalResult = .failed(error, isPermanent)
        }
        
        /// Cleanup after the job is finished
        currentlyRunningJobs.removeValue(forKey: jobId)
        Log.info(.jobRunner, "JobQueue-\(type.name) finished \(job)")
        
        await dependencies[singleton: .jobRunner].didCompleteJob(id: jobId, result: finalResult)
    }
    
    // MARK: - Result Handling
    
    private func handleJobResult(_ result: JobExecutionResult) async {
        switch result {
            case .success(let updatedJob, let stop): await handleJobSucceeded(updatedJob, shouldStop: stop)
            case .deferred(let updatedJob): await handleJobDeferred(updatedJob)
        }
    }
    
    private func handleJobSucceeded(_ job: Job, shouldStop: Bool) async {
        do {
            let dependantJobs: [Job] = try await dependencies[singleton: .storage].writeAsync { [dependencies] db in
                /// Retrieve the dependant jobs first (the `JobDependecies` table has cascading deletion when the original `Job` is
                /// removed so we need to retrieve these records before that happens)
                let dependantJobIds: Set<Int64> = try JobDependencies
                    .select(.jobId)
                    .filter(JobDependencies.Columns.dependantId == job.id)
                    .asRequest(of: Int64.self)
                    .fetchSet(db)
                let dependantJobs: [Job] = try Job.fetchAll(db, ids: dependantJobIds)
                // TODO: Need to test that the above is the same as this
                let dependantJobs2: [Job] = try job.dependantJobs.fetchAll(db)
                
                switch job.behaviour {
                    /// Since this job has been completed we can update the dependencies so other job that were dependant
                    /// on this one can be run
                    case .runOnce, .runOnceNextLaunch, .runOnceAfterConfigSyncIgnoringPermanentFailure:
                        _ = try JobDependencies
                            .filter(JobDependencies.Columns.dependantId == job.id)
                            .deleteAll(db)
                        _ = try job.delete(db)
                        
                    /// Since this job has been completed we can update the dependencies so other job that were dependant
                    /// on this one can be run
                    case .recurring where shouldStop == true:
                        _ = try JobDependencies
                            .filter(JobDependencies.Columns.dependantId == job.id)
                            .deleteAll(db)
                        _ = try job.delete(db)
                        
                    /// For `recurring` jobs which have already run, they should automatically run again but we want at least 1 second
                    /// to pass before doing so - the job itself should really update it's own `nextRunTimestamp` (this is just a safety net)
                    case .recurring where job.nextRunTimestamp <= dependencies.dateNow.timeIntervalSince1970:
                        guard let jobId: Int64 = job.id else { break }
                        
                        _ = try Job
                            .filter(id: jobId)
                            .updateAll(
                                db,
                                Job.Columns.failureCount.set(to: 0),
                                Job.Columns.nextRunTimestamp.set(to: (dependencies.dateNow.timeIntervalSince1970 + 1))
                            )
                        
                    /// For `recurringOnLaunch/Active` jobs which have already run but failed once, we need to clear their
                    /// `failureCount` and `nextRunTimestamp` to prevent them from endlessly running over and over again
                    case .recurringOnLaunch, .recurringOnActive:
                        guard
                            let jobId: Int64 = job.id,
                            job.failureCount != 0 &&
                            job.nextRunTimestamp > TimeInterval.leastNonzeroMagnitude
                        else { break }
                        
                        _ = try Job
                            .filter(id: jobId)
                            .updateAll(
                                db,
                                Job.Columns.failureCount.set(to: 0),
                                Job.Columns.nextRunTimestamp.set(to: 0)
                            )
                        
                    default: break
                }
                
                return dependantJobs
            }
            
            /// This needs to call back to the JobRunner to enqueue these jobs on their correct queues
            await dependencies[singleton: .jobRunner].enqueueDependenciesIfNeeded(dependantJobs)
        } catch {
            Log.error(.jobRunner, "Failed to process successful job \(job) in database: \(error)")
        }
    }

    private func handleJobFailed(_ job: Job, error: Error, permanentFailure: Bool) async {
        let jobExists: Bool = ((try? await dependencies[singleton: .storage]
            .readAsync { db in
                try Job.exists(db, id: job.id ?? -1)
            }) ?? false)
        
        guard jobExists else {
            Log.info(.jobRunner, "JobQueue-\(type.name) \(job) canceled")
            return
        }
        
        // TODO: Should this be moved into the `JobRunner` instead????
        if self.type == .blocking && job.shouldBlock && (error as? JobRunnerError)?.wasPossibleDeferralLoop != true {
             Log.info(.jobRunner, "JobQueue-\(type.name) \(job) failed due to error: \(error); retrying immediately")
            pendingJobsQueue.insert(job, at: 0)
            return
        }
        
        /// Get the max failure count for the job (a value of '-1' means it will retry indefinitely)
        let maxFailureCount: Int = (executorMap[job.variant]?.maxFailureCount ?? 0)
        let tooManyRetries: Bool = (maxFailureCount >= 0 && (job.failureCount + 1) > maxFailureCount)
        let isPermanent: Bool = (permanentFailure || tooManyRetries)
        
        do {
            let dependantJobIds: Set<Int64> = try await dependencies[singleton: .storage].writeAsync { [type, dependencies] db in
                let dependantJobIds: Set<Int64> = try JobDependencies
                    .select(.jobId)
                    .filter(JobDependencies.Columns.dependantId == job.id)
                    .asRequest(of: Int64.self)
                    .fetchSet(db)
                
                guard !isPermanent || job.behaviour == .runOnceAfterConfigSyncIgnoringPermanentFailure else {
                    Log.error(.jobRunner, "JobQueue-\(type.name) \(job) failed permanently due to error: \(error)\(tooManyRetries ? "; too many retries" : "")")
                    
                    /// If the job permanently failed or we have performed all of our retry attempts then delete the job and all of it's
                    /// dependant jobs (it'll probably never succeed)
                    _ = try job.dependantJobs.deleteAll(db)
                    _ = try job.delete(db)
                    return dependantJobIds
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
                // TODO: Need to confirm these match
                let dependantJobs1: [Job] = try Job.fetchAll(db, ids: dependantJobIds)
                // TODO: Need to test that the above is the same as this
                let dependantJobs2: [Job] = try job.dependantJobs.fetchAll(db)
                
                try Job
                    .filter(dependantJobIds.contains(Job.Columns.id))
                    .updateAll(
                        db,
                        Job.Columns.failureCount.set(to: updatedFailureCount),
                        Job.Columns.nextRunTimestamp.set(to: (nextRunTimestamp + (1 / 1000)))
                    )
                
                return dependantJobIds
            }
            
            if !dependantJobIds.isEmpty {
                pendingJobsQueue.removeAll { dependantJobIds.contains($0.id ?? -1) }
            }
        }
        catch {
            Log.error(.jobRunner, "Failed to update database for failed job \(job): \(error)")
        }
    }
    
    private func handleJobDeferred(_ job: Job) async {
        var stuckInDeferLoop: Bool = false
        let jobId: Int64 = (job.id ?? -1)
        
        if let record: (count: Int, times: [TimeInterval]) = deferLoopTracker[jobId] {
            let timeNow: TimeInterval = dependencies.dateNow.timeIntervalSince1970
            stuckInDeferLoop = (
                record.count >= JobQueue.deferralLoopThreshold &&
                (timeNow - record.times[0]) < CGFloat(record.count * maxDeferralsPerSecond)
            )
            
            /// Only store the last `deferralLoopThreshold` times to ensure we aren't running faster than one loop per second
            deferLoopTracker[jobId] = (
                record.count + 1,
                record.times.suffix(JobQueue.deferralLoopThreshold - 1) + [timeNow]
            )
        } else {
            deferLoopTracker[jobId] = (1, [dependencies.dateNow.timeIntervalSince1970])
        }
        
        /// It's possible (by introducing bugs) to create a loop where a `Job` tries to run and immediately defers itself but then attempts
        /// to run again (resulting in an infinite loop); this won't block the app since it's on a background thread but can result in 100% of
        /// a CPU being used (and a battery drain)
        ///
        /// This code will maintain an in-memory store for any jobs which are deferred too quickly (ie. more than `deferralLoopThreshold`
        /// times within `deferralLoopThreshold` seconds)
        if stuckInDeferLoop {
            deferLoopTracker.removeValue(forKey: jobId)
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
    
    private func loadPendingJobsFromDatabase() async {
        let currentJobIds: Set<Int64> = Set(pendingJobsQueue.compactMap(\.id) + currentlyRunningJobs.keys)
        let jobsToRun: [Job] = ((try? await dependencies[singleton: .storage].readAsync { db in
            try Job.filterPendingJobs(
                variants: self.jobVariants,
                excludeFutureJobs: true,
                includeJobsWithDependencies: false
            )
            .filter(!currentJobIds.contains(Job.Columns.id)) /// Exclude jobs already running/queued
            .fetchAll(db)
        }) ?? [])
        
        guard !jobsToRun.isEmpty else { return }
        
        pendingJobsQueue.append(contentsOf: jobsToRun)
    }
    
    private func scheduleNextSoonestJob() async {
        /// Retrieve the soonest `nextRunTimestamp` for jobs that should be running on this queue from the database
        let jobVariants: [Job.Variant] = self.jobVariants
        let jobIdsAlreadyRunning: Set<Int64> = Set(currentlyRunningJobs.keys)
        let maybeNextTimestamp: TimeInterval? = try? await dependencies[singleton: .storage].readAsync { db in
            try Job.filterPendingJobs(
                variants: jobVariants,
                excludeFutureJobs: false,
                includeJobsWithDependencies: false
            )
            .select(.nextRunTimestamp)
            .filter(!jobIdsAlreadyRunning.contains(Job.Columns.id)) /// Exclude jobs already running
            .asRequest(of: TimeInterval.self)
            .fetchOne(db)
        }
        
        guard let nextTimestamp: TimeInterval = maybeNextTimestamp else { return }

        let delay: TimeInterval = (nextTimestamp - dependencies.dateNow.timeIntervalSince1970)
        
        /// If the job isn't ready then schedule a future restart
        guard delay <= 0 else {
            Log.info(.jobRunner, "Stopping JobQueue-\(type.name) until next job in \(.seconds(delay), unit: .s)")
            nextTriggerTask = Task {
                try? await Task.sleep(for: .seconds(Int(floor(delay))))
                
                guard !Task.isCancelled else { return }
                
                start(canStart: true, drainOnly: false)
            }
            return
        }
        
        /// Job is ready now so process it immediately (only add a log if the queue is getting restarted)
        if executionType != .concurrent || currentlyRunningJobs.isEmpty {
            let timingString: String = (nextTimestamp == 0 ?
                "that should be in the queue" :
                "scheduled \(.seconds(delay), unit: .s) ago"
            )
            Log.info(.jobRunner, "Restarting JobQueue-\(type.name) queue immediately for job \(timingString)")
        }
        
        start(canStart: true, drainOnly: false)
    }

    private func prepareToExecute(_ job: Job) async -> JobExecutionPrecheckResult {
        guard let executor: JobExecutor.Type = executorMap[job.variant] else {
            Log.info(.jobRunner, "JobQueue-\(type.name) Unable to run \(job) due to missing executor")
            return .permanentlyFail(error: JobRunnerError.executorMissing)
        }
        guard !executor.requiresThreadId || job.threadId != nil else {
            Log.info(.jobRunner, "JobQueue-\(type.name) Unable to run \(job) due to missing required threadId")
            return .permanentlyFail(error: JobRunnerError.requiredThreadIdMissing)
        }
        guard !executor.requiresInteractionId || job.interactionId != nil else {
            Log.info(.jobRunner, "JobQueue-\(type.name) Unable to run \(job) due to missing required interactionId")
            return .permanentlyFail(error: JobRunnerError.requiredInteractionIdMissing)
        }
        
        /// Check if the next job has any dependencies
        let dependencyInfo: (expectedCount: Int, jobs: Set<Job>) = ((try? await dependencies[singleton: .storage].readAsync { db in
            let expectedDependencies: Set<JobDependencies> = try JobDependencies
                .filter(JobDependencies.Columns.jobId == job.id)
                .fetchSet(db)
            let jobDependencies: Set<Job> = try Job
                .filter(ids: expectedDependencies.compactMap { $0.dependantId })
                .fetchSet(db)
            
            return (expectedDependencies.count, jobDependencies)
        }) ?? (0, []))
        
        guard dependencyInfo.jobs.count == dependencyInfo.expectedCount else {
            Log.info(.jobRunner, "JobQueue-\(type.name) Removing \(job) due to missing dependencies")
            return .permanentlyFail(error: JobRunnerError.missingDependencies)
        }
        guard dependencyInfo.jobs.isEmpty else {
            Log.info(.jobRunner, "JobQueue-\(type.name) Deferring \(job) until \(dependencyInfo.jobs.count) dependencies are completed")
            
            /// Enqueue the dependencies then defer the current job
            await dependencies[singleton: .jobRunner].enqueueDependenciesIfNeeded(Array(dependencyInfo.jobs))
            return .deferUntilDependenciesMet
        }
        
        return .ready
    }
}

// MARK: - QueueType

public extension JobQueue {
    enum QueueType: Hashable {
        case blocking
        case general(number: Int)
        case messageSend
        case messageReceive
        case attachmentDownload
        case displayPictureDownload
        case expirationUpdate
        
        var name: String {
            switch self {
                case .blocking: return "Blocking"
                case .general(let number): return "General-\(number)"
                case .messageSend: return "MessageSend"
                case .messageReceive: return "MessageReceive"
                case .attachmentDownload: return "AttachmentDownload"
                case .displayPictureDownload: return "DisplayPictureDownload"
                case .expirationUpdate: return "ExpirationUpdate"
            }
        }
    }
}

// MARK: - ExecutionType

public extension JobQueue {
    enum ExecutionType {
        /// A serial queue will execute one job at a time until the queue is empty, then will load any new/deferred
        /// jobs and run those one at a time
        case serial
        
        /// A concurrent queue will execute as many jobs as the device supports at once until the queue is empty,
        /// then will load any new/deferred jobs and try to start them all
        case concurrent
    }
}

// MARK: - JobExecutionPrecheckResult

private extension JobQueue {
    enum JobExecutionPrecheckResult {
        case ready
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
