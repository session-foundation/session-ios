// Copyright © 2026 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import TestUtilities

@testable import SessionUtilitiesKit

actor MockJobRunner: JobRunnerType, Mockable {
    public let handler: MockHandler<JobRunnerType>
    
    init(handler: MockHandler<JobRunnerType>) {
        self.handler = handler
    }
    
    init(handlerForBuilder: any MockFunctionHandler) {
        self.handler = MockHandler(forwardingHandler: handlerForBuilder)
    }
    
    // MARK: - Configuration
    
    func setExecutor(_ executor: JobExecutor.Type, for variant: Job.Variant) {
        handler.mockNoReturn(args: [executor, variant])
    }
    
    func setSortDataRetriever(
        _ sortDataRetriever: JobSorterDataRetriever.Type,
        for type: JobQueue.QueueType
    ) async {
        handler.mockNoReturn(args: [sortDataRetriever, type])
    }
    
    func updatePriorityContext(_ context: JobPriorityContext) async {
        handler.mockNoReturn(args: [context])
    }
    
    // MARK: - State Management
    
    func registerStartupJobs(jobInfo: [JobRunner.StartupJobInfo]) {
        handler.mockNoReturn(args: [jobInfo])
    }
    
    func appDidBecomeActive() async {
        handler.mockNoReturn()
    }
    
    func jobsMatching(filters: JobRunner.Filters) async -> [JobQueue.JobQueueId: JobState] {
        return handler.mock(args: [filters])
    }
    
    func deferCount(for jobId: Int64?, of variant: Job.Variant) async -> Int {
        return handler.mock(args: [jobId, variant])
    }
    
    func stopAndClearJobs(filters: JobRunner.Filters) async {
        return handler.mock(args: [filters])
    }
    
    func allQueuesDrained() async {
        return handler.mockNoReturn()
    }
    
    // MARK: - Job Scheduling
    
    @discardableResult nonisolated func add(
        _ db: ObservingDatabase,
        job: Job?,
        initialDependencies: [JobDependencyInitialInfo]
    ) -> Job? {
        return handler.mock(args: [db, job, initialDependencies])
    }
    
    nonisolated func update(_ db: ObservingDatabase, job: Job) throws {
        return handler.mock(args: [db, job])
    }
    
    func getJobDependencyCoordinator() -> JobDependencyCoordinator {
        return handler.mock()
    }
    
    nonisolated func addJobDependency(
        _ db: ObservingDatabase,
        _ info: JobDependencyInfo
    ) throws {
        return handler.mockNoReturn(args: [db, info])
    }
    
    @discardableResult nonisolated func removeJobDependencies(
        _ db: ObservingDatabase,
        _ info: JobDependencyRemovalInfo,
        fromJobIds targetJobIds: Set<Int64>?
    ) -> Set<Int64> {
        return handler.mock(args: [db, info, targetJobIds])
    }
    
    func tryFillCapacityForVariants(_ variants: Set<Job.Variant>) async {
        return handler.mock(args: [variants])
    }
    
    func removePendingJob(_ jobId: Int64?) async {
        return handler.mock(args: [jobId])
    }
    
    // MARK: - Awaiting Job Resules
    
    func blockingQueueCompleted() async {
        handler.mockNoReturn()
    }
    @discardableResult func finalResult(forFirstJobMatching filters: JobRunner.Filters) async throws -> JobRunner.JobResult {
        return try handler.mockThrowing(args: [filters])
    }
    
    func executionPhase(forFirstJobMatching filters: JobRunner.Filters) async -> JobState.ExecutionPhase? {
        return handler.mock(args: [filters])
    }
}

