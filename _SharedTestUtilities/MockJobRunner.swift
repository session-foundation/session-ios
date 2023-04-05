// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

@testable import SessionMessagingKit

class MockJobRunner: Mock<JobRunnerType>, JobRunnerType {
    // MARK: - Configuration
    
    func setExecutor(_ executor: JobExecutor.Type, for variant: Job.Variant) {
        accept(args: [executor, variant])
    }
    
    func canStart(queue: JobQueue) -> Bool {
        return accept(args: [queue]) as! Bool
    }
    
    // MARK: - State Management
    
    func isCurrentlyRunning(_ job: Job?) -> Bool {
        return accept(args: [job]) as! Bool
    }
    
    func hasJob<T: Encodable>(of variant: Job.Variant, inState state: JobRunner.JobState, with jobDetails: T) -> Bool {
        return accept(args: [variant, state, jobDetails]) as! Bool
    }
    
    func detailsFor(jobs: [Job]?, state: JobRunner.JobState, variant: Job.Variant?) -> [Int64: Data?] {
        return accept(args: [jobs, state, variant]) as! [Int64: Data?]
    }
    
    func appDidFinishLaunching(dependencies: Dependencies) {}
    func appDidBecomeActive(dependencies: Dependencies) {}
    func startNonBlockingQueues(dependencies: Dependencies) {}
    
    func stopAndClearPendingJobs(exceptForVariant: Job.Variant?, onComplete: (() -> ())?) {
        accept(args: [exceptForVariant, onComplete])
        onComplete?()
    }
    
    // MARK: - Job Scheduling
    
    func add(_ db: Database, job: Job?, canStartJob: Bool, dependencies: Dependencies) {
        accept(args: [db, job, canStartJob])
    }
    
    func upsert(_ db: Database, job: Job?, canStartJob: Bool, dependencies: Dependencies) {
        accept(args: [db, job, canStartJob])
    }
    
    func insert(_ db: Database, job: Job?, before otherJob: Job, dependencies: Dependencies) -> (Int64, Job)? {
        return accept(args: [db, job, otherJob]) as? (Int64, Job)
    }
}
