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
    
    func canStart(queue: JobQueue?) -> Bool {
        return accept(args: [queue]) as! Bool
    }
    
    func afterBlockingQueue(callback: @escaping () -> ()) {
        callback()
    }
    
    // MARK: - State Management
    
    func jobInfoFor(jobs: [Job]?, state: JobRunner.JobState, variant: Job.Variant?) -> [Int64: JobRunner.JobInfo] {
        return accept(args: [jobs, state, variant]) as! [Int64: JobRunner.JobInfo]
    }
    
    func appDidFinishLaunching(using dependencies: Dependencies) {}
    func appDidBecomeActive(using dependencies: Dependencies) {}
    func startNonBlockingQueues(using dependencies: Dependencies) {}
    
    func stopAndClearPendingJobs(exceptForVariant: Job.Variant?, onComplete: (() -> ())?) {
        accept(args: [exceptForVariant, onComplete])
        onComplete?()
    }
    
    // MARK: - Job Scheduling
    
    @discardableResult func add(_ db: Database, job: Job?, canStartJob: Bool, using dependencies: Dependencies) -> Job? {
        return accept(args: [db, job, canStartJob]) as? Job
    }
    
    func upsert(_ db: Database, job: Job?, canStartJob: Bool, using dependencies: Dependencies) {
        accept(args: [db, job, canStartJob])
    }
    
    func insert(_ db: Database, job: Job?, before otherJob: Job) -> (Int64, Job)? {
        return accept(args: [db, job, otherJob]) as? (Int64, Job)
    }
}
