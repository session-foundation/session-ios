// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import TestUtilities

@testable import SessionUtilitiesKit

class MockJobRunner: JobRunnerType, Mockable {
    public var handler: MockHandler<JobRunnerType>
    
    required init(handler: MockHandler<JobRunnerType>) {
        self.handler = handler
    }
    
    required init(handlerForBuilder: any MockFunctionHandler) {
        self.handler = MockHandler(forwardingHandler: handlerForBuilder)
    }
    
    // MARK: - Configuration
    
    func setExecutor(_ executor: JobExecutor.Type, for variant: Job.Variant) {
        handler.mockNoReturn(args: [executor, variant])
    }
    
    func canStart(queue: JobQueue?) -> Bool {
        return handler.mock(args: [queue])
    }
    
    func afterBlockingQueue(callback: @escaping () -> ()) {
        handler.mockNoReturn()
    }
    
    func queue(for variant: Job.Variant) -> DispatchQueue? { DispatchQueue.main }
    
    // MARK: - State Management
    
    func jobInfoFor(jobs: [Job]?, state: JobRunner.JobState, variant: Job.Variant?) -> [Int64: JobRunner.JobInfo] {
        return handler.mock(args: [jobs, state, variant])
    }
    
    func deferCount(for jobId: Int64?, of variant: Job.Variant) -> Int {
        return handler.mock(args: [jobId, variant])
    }
    
    func appDidFinishLaunching() {}
    func appDidBecomeActive() {}
    func startNonBlockingQueues() {}
    
    func stopAndClearPendingJobs(exceptForVariant: Job.Variant?, onComplete: ((Bool) -> ())?) {
        handler.mockNoReturn(args: [exceptForVariant, onComplete])
        onComplete?(false)
    }
    
    // MARK: - Job Scheduling
    
    @discardableResult func add(_ db: ObservingDatabase, job: Job?, dependantJob: Job?, canStartJob: Bool) -> Job? {
        return handler.mock(args: [db, job, dependantJob, canStartJob])
    }
    
    func upsert(_ db: ObservingDatabase, job: Job?, canStartJob: Bool) -> Job? {
        return handler.mock(args: [db, job, canStartJob])
    }
    
    func insert(_ db: ObservingDatabase, job: Job?, before otherJob: Job) -> (Int64, Job)? {
        return handler.mock(args: [db, job, otherJob])
    }
    
    func enqueueDependenciesIfNeeded(_ jobs: [Job]) {
        handler.mockNoReturn(args: [jobs])
    }
    
    func afterJob(_ job: Job?, state: JobRunner.JobState) -> AnyPublisher<JobRunner.JobResult, Never> {
        handler.mock(args: [job, state])
    }
    
    func manuallyTriggerResult(_ job: Job?, result: JobRunner.JobResult) {
        handler.mockNoReturn(args: [job, result])
    }
    
    func removePendingJob(_ job: Job?) {
        handler.mockNoReturn(args: [job])
    }
    
    
    func registerRecurringJobs(scheduleInfo: [JobRunner.ScheduleInfo]) {
        handler.mockNoReturn(args: [scheduleInfo])
    }
    
    func scheduleRecurringJobsIfNeeded() {
        handler.mockNoReturn()
    }
}
