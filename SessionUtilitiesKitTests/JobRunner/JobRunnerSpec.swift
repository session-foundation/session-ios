// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB

import Quick
import Nimble

@testable import SessionUtilitiesKit

class JobRunnerSpec: QuickSpec {
    struct TestDetails: Codable {
        enum ResultType: Codable {
            case success
            case failure
            case permanentFailure
            case deferred
        }
        
        public let result: ResultType
        public let completeTime: Int
        public let intValue: Int64
        public let stringValue: String
        
        init(
            result: ResultType = .success,
            completeTime: Int = 0,
            intValue: Int64 = 100,
            stringValue: String = "200"
        ) {
            self.result = result
            self.completeTime = completeTime
            self.intValue = intValue
            self.stringValue = stringValue
        }
    }
    
    struct InvalidDetails: Codable {
        func encode(to encoder: Encoder) throws { throw HTTP.Error.parsingFailed }
    }
    
    enum TestJob: JobExecutor {
        static let maxFailureCount: Int = 1
        static let requiresThreadId: Bool = false
        static let requiresInteractionId: Bool = false
        
        static func run(
            _ job: Job,
            queue: DispatchQueue,
            success: @escaping (Job, Bool, Dependencies) -> (),
            failure: @escaping (Job, Error?, Bool, Dependencies) -> (),
            deferred: @escaping (Job, Dependencies) -> (),
            dependencies: Dependencies
        ) {
            guard
                let detailsData: Data = job.details,
                let details: TestDetails = try? JSONDecoder().decode(TestDetails.self, from: detailsData)
            else { return success(job, true, dependencies) }
            
            let completeJob: () -> () = {
                // Need to auto-increment the 'completeTime' and 'nextRunTimestamp' to prevent the job
                // from immediately being run again
                let updatedJob: Job = job
                    .with(nextRunTimestamp: (max(1234567890, job.nextRunTimestamp) + 0.5))
                    .with(
                        details: TestDetails(
                            result: details.result,
                            completeTime: (details.completeTime + 1),
                            intValue: details.intValue,
                            stringValue: details.stringValue
                        )
                    )!
                dependencies.storage.write { db in try _ = updatedJob.saved(db) }
                
                switch details.result {
                    case .success: success(job, true, dependencies)
                    case .failure: failure(job, nil, false, dependencies)
                    case .permanentFailure: failure(job, nil, true, dependencies)
                    case .deferred: deferred(updatedJob, dependencies)
                }
            }
            
            guard dependencies.fixedTime < details.completeTime else { return completeJob() }
            
            DispatchQueue.global(qos: .default).async {
                while dependencies.fixedTime < details.completeTime {
                    Thread.sleep(forTimeInterval: 0.01) // Wait for 10ms
                }
                
                queue.async {
                    completeJob()
                }
            }
        }
    }
    
    // MARK: - Spec

    override func spec() {
        var jobRunner: JobRunnerType!
        var job1: Job!
        var job2: Job!
        var mockStorage: Storage!
        var dependencies: Dependencies!
        
        // MARK: - JobRunner
        
        describe("a JobRunner") {
            beforeEach {
                mockStorage = Storage(
                    customWriter: try! DatabaseQueue(),
                    customMigrations: [
                        SNUtilitiesKit.migrations()
                    ]
                )
                dependencies = Dependencies(
                    storage: mockStorage,
                    date: Date(timeIntervalSince1970: 1234567890)
                )
                
                // Migrations add jobs which we don't want so delete them
                mockStorage.write { db in try Job.deleteAll(db) }
                
                job1 = Job(
                    id: 100,
                    failureCount: 0,
                    variant: .messageSend,
                    behaviour: .runOnce,
                    shouldBlock: false,
                    shouldSkipLaunchBecomeActive: false,
                    nextRunTimestamp: 0,
                    threadId: nil,
                    interactionId: nil,
                    details: nil
                )
                job2 = Job(
                    id: 101,
                    failureCount: 0,
                    variant: .attachmentUpload,
                    behaviour: .runOnce,
                    shouldBlock: false,
                    shouldSkipLaunchBecomeActive: false,
                    nextRunTimestamp: 0,
                    threadId: nil,
                    interactionId: nil,
                    details: nil
                )
                
                jobRunner = JobRunner(isTestingJobRunner: true, dependencies: dependencies)
                jobRunner.setExecutor(TestJob.self, for: .messageSend)
                jobRunner.setExecutor(TestJob.self, for: .attachmentUpload)
                jobRunner.setExecutor(TestJob.self, for: .attachmentDownload)
                
                // Need to assign this to ensure it's used by nested dependencies
                dependencies.jobRunner = jobRunner
            }
            
            afterEach {
                /// We **must** set `fixedTime` to ensure we break any loops within the `TestJob` executor
                dependencies.fixedTime = Int.max
                jobRunner.stopAndClearPendingJobs()
                jobRunner = nil
                mockStorage = nil
                dependencies = nil
            }
            // MARK: -- when configuring
            
            context("when configuring") {
                it("adds an executor correctly") {
                    job1 = Job(
                        id: 101,
                        failureCount: 0,
                        variant: .getSnodePool,
                        behaviour: .runOnce,
                        shouldBlock: false,
                        shouldSkipLaunchBecomeActive: false,
                        nextRunTimestamp: 0,
                        threadId: nil,
                        interactionId: nil,
                        details: try? JSONEncoder().encode(TestDetails(completeTime: 1))
                    )
                    jobRunner.appDidFinishLaunching(dependencies: dependencies)
                    
                    mockStorage.write { db in
                        jobRunner.upsert(
                            db,
                            job: job1,
                            canStartJob: true,
                            dependencies: dependencies
                        )
                    }
                    
                    expect(jobRunner.isCurrentlyRunning(job1))
                        .toEventually(
                            beFalse(),
                            timeout: .milliseconds(50)
                        )
                    
                    jobRunner.setExecutor(TestJob.self, for: .getSnodePool)
                    
                    mockStorage.write { db in
                        jobRunner.upsert(
                            db,
                            job: job1,
                            canStartJob: true,
                            dependencies: dependencies
                        )
                    }
                    
                    expect(jobRunner.isCurrentlyRunning(job1))
                        .toEventually(
                            beFalse(),
                            timeout: .milliseconds(50)
                        )
                }
            }
            
            // MARK: -- when managing state
            
            context("when managing state") {
                
                // MARK: ---- by checking if a job is currently running
                
                context("by checking if a job is currently running") {
                    it("returns false when not given a job") {
                        expect(jobRunner.isCurrentlyRunning(nil)).to(beFalse())
                    }
                    
                    it("returns false when given a job that has not been persisted") {
                        job1 = Job(variant: .messageSend)
                        
                        expect(jobRunner.isCurrentlyRunning(job1)).to(beFalse())
                    }
                    
                    it("returns false when given a job that is not running") {
                        expect(jobRunner.isCurrentlyRunning(job1)).to(beFalse())
                    }
                    
                    it("returns true when given a non blocking job that is running") {
                        job1 = job1.with(details: TestDetails(completeTime: 1))
                        jobRunner.appDidFinishLaunching(dependencies: dependencies)
                        
                        mockStorage.write { db in
                            jobRunner.upsert(
                                db,
                                job: job1,
                                canStartJob: true,
                                dependencies: dependencies
                            )
                        }
                        
                        expect(jobRunner.isCurrentlyRunning(job1))
                            .toEventually(
                                beTrue(),
                                timeout: .milliseconds(50)
                            )
                    }
                    
                    it("returns true when given a blocking job that is running") {
                        job2 = Job(
                            id: 101,
                            failureCount: 0,
                            variant: .messageSend,
                            behaviour: .runOnceNextLaunch,
                            shouldBlock: true,
                            shouldSkipLaunchBecomeActive: false,
                            nextRunTimestamp: 0,
                            threadId: nil,
                            interactionId: nil,
                            details: try? JSONEncoder().encode(TestDetails(completeTime: 1))
                        )
                        
                        mockStorage.write { db in
                            try job2.insert(db)
                            
                            jobRunner.upsert(
                                db,
                                job: job2,
                                canStartJob: true,
                                dependencies: dependencies
                            )
                        }
                        
                        jobRunner.appDidFinishLaunching(dependencies: dependencies)
                        
                        expect(jobRunner.isCurrentlyRunning(job2))
                            .toEventually(
                                beTrue(),
                                timeout: .milliseconds(50)
                            )
                    }
                }
                
                // MARK: ---- by getting the details for jobs
                
                context("by getting the details for jobs") {
                    it("returns an empty dictionary when there are no jobs") {
                        expect(jobRunner.details()).to(equal([:]))
                    }
                    
                    it("returns an empty dictionary when there are no jobs matching the filters") {
                        jobRunner.appDidFinishLaunching(dependencies: dependencies)
                        
                        mockStorage.write { db in
                            jobRunner.upsert(
                                db,
                                job: job2,
                                canStartJob: true,
                                dependencies: dependencies
                            )
                        }
                        
                        expect(jobRunner.detailsFor(state: .running, variant: .messageSend))
                            .toEventually(
                                equal([:]),
                                timeout: .milliseconds(50)
                            )
                    }
                    
                    it("can filter to specific jobs") {
                        mockStorage.write { db in
                            jobRunner.upsert(
                                db,
                                job: job2,
                                /// The `canStartJob` value needs to be `true` for the job to be added to the queue but as
                                /// long as `appDidFinishLaunching` hasn't been called it won't actually start running and
                                /// as a result we can test the "pending" state
                                canStartJob: true,
                                dependencies: dependencies
                            )
                        }
                        
                        // Wait for there to be data and the validate the filtering works
                        expect(jobRunner.details())
                            .toEventuallyNot(
                                beEmpty(),
                                timeout: .milliseconds(50)
                            )
                        expect(jobRunner.detailsFor(jobs: [job1])).to(equal([:]))
                        expect(jobRunner.detailsFor(jobs: [job2])).to(equal([101: job2.details]))
                    }
                    
                    it("can filter to running jobs") {
                        job1 = Job(
                            id: 100,
                            failureCount: 0,
                            variant: .attachmentDownload,
                            behaviour: .runOnce,
                            shouldBlock: false,
                            shouldSkipLaunchBecomeActive: false,
                            nextRunTimestamp: 0,
                            threadId: nil,
                            interactionId: nil,
                            details: try? JSONEncoder().encode(TestDetails(completeTime: 1))
                        )
                        job2 = Job(
                            id: 101,
                            failureCount: 0,
                            variant: .attachmentDownload,
                            behaviour: .runOnce,
                            shouldBlock: false,
                            shouldSkipLaunchBecomeActive: false,
                            nextRunTimestamp: 0,
                            threadId: nil,
                            interactionId: nil,
                            details: try? JSONEncoder().encode(TestDetails(completeTime: 1))
                        )
                        jobRunner.appDidFinishLaunching(dependencies: dependencies)
                        
                        mockStorage.write { db in
                            try job1.insert(db)
                            try job2.insert(db)
                            
                            jobRunner.upsert(
                                db,
                                job: job1,
                                canStartJob: true,
                                dependencies: dependencies
                            )
                            
                            jobRunner.upsert(
                                db,
                                job: job2,
                                canStartJob: false,
                                dependencies: dependencies
                            )
                        }
                        
                        // Wait for there to be data and the validate the filtering works
                        expect(jobRunner.detailsFor(state: .running))
                            .toEventually(
                                equal([100: try! JSONEncoder().encode(TestDetails(completeTime: 1))]),
                                timeout: .milliseconds(50)
                            )
                        expect(Array(jobRunner.details().keys).sorted()).to(equal([100, 101]))
                    }
                    
                    it("can filter to pending jobs") {
                        job1 = Job(
                            id: 100,
                            failureCount: 0,
                            variant: .attachmentDownload,
                            behaviour: .runOnce,
                            shouldBlock: false,
                            shouldSkipLaunchBecomeActive: false,
                            nextRunTimestamp: 0,
                            threadId: nil,
                            interactionId: nil,
                            details: try? JSONEncoder().encode(TestDetails(completeTime: 1))
                        )
                        job2 = Job(
                            id: 101,
                            failureCount: 0,
                            variant: .attachmentDownload,
                            behaviour: .runOnce,
                            shouldBlock: false,
                            shouldSkipLaunchBecomeActive: false,
                            nextRunTimestamp: 0,
                            threadId: nil,
                            interactionId: nil,
                            details: try? JSONEncoder().encode(TestDetails(completeTime: 1))
                        )
                        jobRunner.appDidFinishLaunching(dependencies: dependencies)
                        
                        mockStorage.write { db in
                            try job1.insert(db)
                            try job2.insert(db)
                            
                            jobRunner.upsert(
                                db,
                                job: job1,
                                canStartJob: true,
                                dependencies: dependencies
                            )
                            
                            jobRunner.upsert(
                                db,
                                job: job2,
                                canStartJob: true,
                                dependencies: dependencies
                            )
                        }
                        
                        // Wait for there to be data and the validate the filtering works
                        expect(jobRunner.detailsFor(state: .pending))
                            .toEventually(
                                equal([101: try! JSONEncoder().encode(TestDetails(completeTime: 1))]),
                                timeout: .milliseconds(50)
                            )
                        expect(Array(jobRunner.details().keys).sorted()).to(equal([100, 101]))
                    }
                    
                    it("can filter to specific variants") {
                        job1 = job1.with(details: TestDetails(completeTime: 1))
                        job2 = job2.with(details: TestDetails(completeTime: 2))
                        jobRunner.appDidFinishLaunching(dependencies: dependencies)
                        
                        mockStorage.write { db in
                            try job1.insert(db)
                            try job2.insert(db)
                            
                            jobRunner.upsert(
                                db,
                                job: job1,
                                canStartJob: true,
                                dependencies: dependencies
                            )
                            
                            jobRunner.upsert(
                                db,
                                job: job2,
                                canStartJob: true,
                                dependencies: dependencies
                            )
                        }
                        
                        // Wait for there to be data and the validate the filtering works
                        expect(jobRunner.detailsFor(variant: .attachmentUpload))
                            .toEventually(
                                equal([101: try! JSONEncoder().encode(TestDetails(completeTime: 2))]),
                                timeout: .milliseconds(50)
                            )
                        expect(Array(jobRunner.details().keys).sorted())
                            .toEventually(
                                equal([100, 101]),
                                timeout: .milliseconds(50)
                            )
                    }
                    
                    it("includes non blocking jobs") {
                        job2 = job2.with(details: TestDetails(completeTime: 1))
                        jobRunner.appDidFinishLaunching(dependencies: dependencies)
                        
                        mockStorage.write { db in
                            jobRunner.upsert(
                                db,
                                job: job2,
                                canStartJob: true,
                                dependencies: dependencies
                            )
                        }
                        
                        expect(jobRunner.detailsFor(state: .running, variant: .attachmentUpload))
                            .toEventually(
                                equal([101: try! JSONEncoder().encode(TestDetails(completeTime: 1))]),
                                timeout: .milliseconds(50)
                            )
                    }
                    
                    it("includes blocking jobs") {
                        job2 = Job(
                            id: 101,
                            failureCount: 0,
                            variant: .attachmentUpload,
                            behaviour: .runOnceNextLaunch,
                            shouldBlock: true,
                            shouldSkipLaunchBecomeActive: false,
                            nextRunTimestamp: 0,
                            threadId: nil,
                            interactionId: nil,
                            details: try! JSONEncoder().encode(TestDetails(completeTime: 1))
                        )
                        
                        mockStorage.write { db in
                            try job2.insert(db)
                            
                            jobRunner.upsert(
                                db,
                                job: job2,
                                canStartJob: true,
                                dependencies: dependencies
                            )
                        }
                        
                        jobRunner.appDidFinishLaunching(dependencies: dependencies)
                        
                        expect(jobRunner.detailsFor(state: .running, variant: .attachmentUpload))
                            .toEventually(
                                equal([101: try! JSONEncoder().encode(TestDetails(completeTime: 1))]),
                                timeout: .milliseconds(50)
                            )
                    }
                }
                
                // MARK: ---- by checking for an existing job
                
                context("by checking for an existing job") {
                    it("returns false for a queue that doesn't exist") {
                        jobRunner = JobRunner(
                            isTestingJobRunner: true,
                            variantsToExclude: [.attachmentUpload],
                            dependencies: dependencies
                        )
                        
                        expect(jobRunner.hasJob(of: .attachmentUpload, with: TestDetails()))
                            .to(beFalse())
                    }
                    
                    it("returns false when the provided details fail to decode") {
                        expect(jobRunner.hasJob(of: .attachmentUpload, with: InvalidDetails()))
                            .to(beFalse())
                    }
                    
                    it("returns false when there is not a pending or running job") {
                        expect(jobRunner.hasJob(of: .attachmentUpload, with: TestDetails()))
                            .to(beFalse())
                    }
                    
                    it("returns true when there is a pending job") {
                        job2 = job2.with(details: TestDetails(completeTime: 1))
                        mockStorage.write { db in
                            jobRunner.upsert(
                                db,
                                job: job2,
                                /// The `canStartJob` value needs to be `true` for the job to be added to the queue but as
                                /// long as `appDidFinishLaunching` hasn't been called it won't actually start running and
                                /// as a result we can test the "pending" state
                                canStartJob: true,
                                dependencies: dependencies
                            )
                        }
                        
                        expect(Array(jobRunner.detailsFor(state: .pending, variant: .attachmentUpload).keys))
                            .toEventually(
                                equal([101]),
                                timeout: .milliseconds(50)
                            )
                        expect(jobRunner.hasJob(of: .attachmentUpload, with: TestDetails(completeTime: 1)))
                            .to(beTrue())
                    }
                    
                    it("returns true when there is a running job") {
                        job2 = job2.with(details: TestDetails(completeTime: 1))
                        jobRunner.appDidFinishLaunching(dependencies: dependencies)
                        
                        mockStorage.write { db in
                            jobRunner.upsert(
                                db,
                                job: job2,
                                canStartJob: true,
                                dependencies: dependencies
                            )
                        }
                        
                        expect(Array(jobRunner.detailsFor(state: .running, variant: .attachmentUpload).keys))
                            .toEventually(
                                equal([101]),
                                timeout: .milliseconds(50)
                            )
                        expect(jobRunner.hasJob(of: .attachmentUpload, with: TestDetails(completeTime: 1)))
                            .to(beTrue())
                    }
                    
                    it("returns true when there is a blocking job") {
                        job2 = Job(
                            id: 101,
                            failureCount: 0,
                            variant: .attachmentUpload,
                            behaviour: .runOnceNextLaunch,
                            shouldBlock: true,
                            shouldSkipLaunchBecomeActive: false,
                            nextRunTimestamp: 0,
                            threadId: nil,
                            interactionId: nil,
                            details: try! JSONEncoder().encode(TestDetails(completeTime: 1))
                        )
                        
                        mockStorage.write { db in
                            try job2.insert(db)
                            
                            jobRunner.upsert(
                                db,
                                job: job2,
                                canStartJob: true,
                                dependencies: dependencies
                            )
                        }
                        
                        jobRunner.appDidFinishLaunching(dependencies: dependencies)
                        
                        expect(Array(jobRunner.detailsFor(state: .running, variant: .attachmentUpload).keys))
                            .toEventually(
                                equal([101]),
                                timeout: .milliseconds(50)
                            )
                        expect(jobRunner.hasJob(of: .attachmentUpload, with: TestDetails(completeTime: 1)))
                            .to(beTrue())
                    }
                    
                    it("returns true when there is a non blocking job") {
                        job2 = job2.with(details: TestDetails(completeTime: 1))
                        jobRunner.appDidFinishLaunching(dependencies: dependencies)
                        
                        mockStorage.write { db in
                            jobRunner.upsert(
                                db,
                                job: job2,
                                canStartJob: true,
                                dependencies: dependencies
                            )
                        }
                        
                        expect(Array(jobRunner.detailsFor(state: .running, variant: .attachmentUpload).keys))
                            .toEventually(
                                equal([101]),
                                timeout: .milliseconds(50)
                            )
                        expect(jobRunner.hasJob(of: .attachmentUpload, with: TestDetails(completeTime: 1)))
                            .to(beTrue())
                    }
                }
                
                // MARK: ---- by being notified of app launch
                
                context("by being notified of app launch") {
                    it("does not start a job before getting the app launch call") {
                        job1 = job1.with(details: TestDetails(completeTime: 1))
                        
                        mockStorage.write { db in
                            jobRunner.upsert(
                                db,
                                job: job1,
                                canStartJob: true,
                                dependencies: dependencies
                            )
                        }
                        
                        expect(jobRunner.isCurrentlyRunning(job1))
                            .toEventually(
                                beFalse(),
                                timeout: .milliseconds(50)
                            )
                    }
                    
                    it("does nothing if there are no app launch jobs") {
                        job1 = job1.with(details: TestDetails(completeTime: 1))
                        
                        mockStorage.write { db in
                            jobRunner.upsert(
                                db,
                                job: job1,
                                canStartJob: true,
                                dependencies: dependencies
                            )
                        }
                        
                        jobRunner.appDidFinishLaunching(dependencies: dependencies)
                        
                        expect(jobRunner.isCurrentlyRunning(job1))
                            .toEventually(
                                beFalse(),
                                timeout: .milliseconds(50)
                            )
                    }
                    
                    it("starts the job queues after completing blocking app launch jobs") {
                        job1 = job1.with(details: TestDetails(completeTime: 2))
                        job2 = Job(
                            id: 101,
                            failureCount: 0,
                            variant: .messageSend,
                            behaviour: .runOnceNextLaunch,
                            shouldBlock: true,
                            shouldSkipLaunchBecomeActive: false,
                            nextRunTimestamp: 0,
                            threadId: nil,
                            interactionId: nil,
                            details: try! JSONEncoder().encode(TestDetails(completeTime: 1))
                        )
                        
                        mockStorage.write { db in
                            try job2.insert(db)
                            
                            jobRunner.upsert(
                                db,
                                job: job1,
                                canStartJob: true,
                                dependencies: dependencies
                            )
                            jobRunner.upsert(
                                db,
                                job: job2,
                                canStartJob: true,
                                dependencies: dependencies
                            )
                        }
                        
                        // Not currently running
                        expect(jobRunner.isCurrentlyRunning(job1))
                            .toEventually(
                                beFalse(),
                                timeout: .milliseconds(50)
                            )
                        expect(jobRunner.isCurrentlyRunning(job2)).to(beFalse())
                        
                        // Make sure it starts
                        jobRunner.appDidFinishLaunching(dependencies: dependencies)
                        
                        // Blocking job running but blocked job not
                        expect(jobRunner.isCurrentlyRunning(job2))
                            .toEventually(
                                beTrue(),
                                timeout: .milliseconds(50)
                            )
                        expect(jobRunner.isCurrentlyRunning(job1)).to(beFalse())
                        
                        // Complete 'job2'
                        dependencies.fixedTime = 1
                        
                        // Blocked job eventually starts
                        expect(jobRunner.isCurrentlyRunning(job1))
                            .toEventually(
                                beTrue(),
                                timeout: .milliseconds(50)
                            )
                    }
                    
                    it("starts the job queues alongside non blocking app launch jobs") {
                        job1 = job1.with(details: TestDetails(completeTime: 1))
                        job2 = Job(
                            id: 101,
                            failureCount: 0,
                            variant: .messageSend,
                            behaviour: .runOnceNextLaunch,
                            shouldBlock: false,
                            shouldSkipLaunchBecomeActive: false,
                            nextRunTimestamp: 0,
                            threadId: nil,
                            interactionId: nil,
                            details: try! JSONEncoder().encode(TestDetails(completeTime: 1))
                        )
                        
                        mockStorage.write { db in
                            try job2.insert(db)
                            
                            jobRunner.upsert(
                                db,
                                job: job1,
                                canStartJob: true,
                                dependencies: dependencies
                            )
                            jobRunner.upsert(
                                db,
                                job: job2,
                                canStartJob: true,
                                dependencies: dependencies
                            )
                        }
                        
                        // Not currently running
                        expect(jobRunner.isCurrentlyRunning(job1))
                            .toEventually(
                                beFalse(),
                                timeout: .milliseconds(50)
                            )
                        
                        // Make sure it starts
                        jobRunner.appDidFinishLaunching(dependencies: dependencies)
                        
                        expect(jobRunner.isCurrentlyRunning(job1))
                            .toEventually(
                                beTrue(),
                                timeout: .milliseconds(50)
                            )
                        expect(jobRunner.isCurrentlyRunning(job2))
                            .toEventually(
                                beTrue(),
                                timeout: .milliseconds(50)
                            )
                    }
                }
                
                // MARK: ---- by being notified of app becoming active
                
                context("by being notified of app becoming active") {
                    it("does not start a job before getting the app active call") {
                        job1 = job1.with(details: TestDetails(completeTime: 1))
                        
                        mockStorage.write { db in
                            jobRunner.upsert(
                                db,
                                job: job1,
                                canStartJob: true,
                                dependencies: dependencies
                            )
                        }
                        
                        expect(jobRunner.isCurrentlyRunning(job1))
                            .toEventually(
                                beFalse(),
                                timeout: .milliseconds(50)
                            )
                    }
                    
                    it("does not start the job queues if there are no app active jobs and blocking jobs are running") {
                        job1 = job1.with(details: TestDetails(completeTime: 2))
                        job2 = Job(
                            id: 101,
                            failureCount: 0,
                            variant: .messageSend,
                            behaviour: .runOnceNextLaunch,
                            shouldBlock: true,
                            shouldSkipLaunchBecomeActive: false,
                            nextRunTimestamp: 0,
                            threadId: nil,
                            interactionId: nil,
                            details: try? JSONEncoder().encode(TestDetails(completeTime: 1))
                        )
                        
                        mockStorage.write { db in
                            try job2.insert(db)
                            
                            jobRunner.upsert(
                                db,
                                job: job1,
                                canStartJob: true,
                                dependencies: dependencies
                            )
                            jobRunner.upsert(
                                db,
                                job: job2,
                                canStartJob: true,
                                dependencies: dependencies
                            )
                        }
                        
                        // Not currently running
                        expect(jobRunner.isCurrentlyRunning(job1))
                            .toEventually(
                                beFalse(),
                                timeout: .milliseconds(50)
                            )
                        
                        // Start the blocking job
                        jobRunner.appDidFinishLaunching(dependencies: dependencies)
                        
                        // Make sure the other queues don't start
                        jobRunner.appDidBecomeActive(dependencies: dependencies)
                        
                        expect(jobRunner.isCurrentlyRunning(job1))
                            .toEventually(
                                beFalse(),
                                timeout: .milliseconds(50)
                            )
                    }
                    
                    it("does not start the job queues if there are app active jobs and blocking jobs are running") {
                        job1 = Job(
                            id: 100,
                            failureCount: 0,
                            variant: .messageSend,
                            behaviour: .recurringOnActive,
                            shouldBlock: false,
                            shouldSkipLaunchBecomeActive: false,
                            nextRunTimestamp: 0,
                            threadId: nil,
                            interactionId: nil,
                            details: try? JSONEncoder().encode(TestDetails(completeTime: 2))
                        )
                        job2 = Job(
                            id: 101,
                            failureCount: 0,
                            variant: .messageSend,
                            behaviour: .runOnceNextLaunch,
                            shouldBlock: true,
                            shouldSkipLaunchBecomeActive: false,
                            nextRunTimestamp: 0,
                            threadId: nil,
                            interactionId: nil,
                            details: try? JSONEncoder().encode(TestDetails(completeTime: 1))
                        )
                        
                        mockStorage.write { db in
                            try job1.insert(db)
                            try job2.insert(db)
                            
                            jobRunner.upsert(
                                db,
                                job: job1,
                                canStartJob: true,
                                dependencies: dependencies
                            )
                            jobRunner.upsert(
                                db,
                                job: job2,
                                canStartJob: true,
                                dependencies: dependencies
                            )
                        }
                        
                        // Not currently running
                        expect(jobRunner.isCurrentlyRunning(job1))
                            .toEventually(
                                beFalse(),
                                timeout: .milliseconds(50)
                            )
                        
                        // Start the blocking queue
                        jobRunner.appDidFinishLaunching(dependencies: dependencies)
                        
                        // Make sure the other queues don't start
                        jobRunner.appDidBecomeActive(dependencies: dependencies)
                        
                        expect(jobRunner.isCurrentlyRunning(job1))
                            .toEventually(
                                beFalse(),
                                timeout: .milliseconds(50)
                            )
                    }
                    
                    it("starts the job queues if there are no app active jobs") {
                        job1 = job1.with(details: TestDetails(completeTime: 1))
                        
                        mockStorage.write { db in
                            jobRunner.upsert(
                                db,
                                job: job1,
                                canStartJob: true,
                                dependencies: dependencies
                            )
                        }
                        
                        jobRunner.appDidBecomeActive(dependencies: dependencies)
                        
                        expect(jobRunner.isCurrentlyRunning(job1))
                            .toEventually(
                                beTrue(),
                                timeout: .milliseconds(50)
                            )
                    }
                    
                    it("starts the job queues if there are app active jobs") {
                        job1 = Job(
                            id: 100,
                            failureCount: 0,
                            variant: .messageSend,
                            behaviour: .recurringOnActive,
                            shouldBlock: false,
                            shouldSkipLaunchBecomeActive: false,
                            nextRunTimestamp: 0,
                            threadId: nil,
                            interactionId: nil,
                            details: try? JSONEncoder().encode(TestDetails(completeTime: 1))
                        )
                        job2 = Job(
                            id: 101,
                            failureCount: 0,
                            variant: .messageSend,
                            behaviour: .runOnce,
                            shouldBlock: false,
                            shouldSkipLaunchBecomeActive: false,
                            nextRunTimestamp: 0,
                            threadId: nil,
                            interactionId: nil,
                            details: try? JSONEncoder().encode(TestDetails(completeTime: 1))
                        )
                        
                        mockStorage.write { db in
                            try job1.insert(db)
                            try job2.insert(db)
                            
                            jobRunner.upsert(
                                db,
                                job: job1,
                                canStartJob: true,
                                dependencies: dependencies
                            )
                            jobRunner.upsert(
                                db,
                                job: job2,
                                canStartJob: true,
                                dependencies: dependencies
                            )
                        }
                        
                        // Not currently running
                        expect(jobRunner.isCurrentlyRunning(job1))
                            .toEventually(
                                beFalse(),
                                timeout: .milliseconds(50)
                            )
                        
                        // Make sure the queues are started
                        jobRunner.appDidBecomeActive(dependencies: dependencies)
                        
                        expect(jobRunner.isCurrentlyRunning(job1))
                            .toEventually(
                                beTrue(),
                                timeout: .milliseconds(50)
                            )
                        expect(jobRunner.isCurrentlyRunning(job2)).to(beTrue())
                    }
                }
            }
            
            // MARK: -- when running jobs
            
            context("when running jobs") {
                beforeEach {
                    jobRunner.appDidFinishLaunching(dependencies: dependencies)
                }
                
                // MARK: ---- by adding
                
                context("by adding") {
                    it("does not start until after the db transaction completes") {
                        job1 = job1.with(details: TestDetails(completeTime: 1))
                        
                        mockStorage.write { db in
                            jobRunner.add(db, job: job1, canStartJob: true, dependencies: dependencies)
                            
                            // Wait for 10ms to give the job the chance to be added
                            Thread.sleep(forTimeInterval: 0.01)
                            expect(Array(jobRunner.detailsFor(state: .running).keys))
                                .to(beEmpty())
                        }
                        
                        // Wait for 10ms for the job to actually be added
                        Thread.sleep(forTimeInterval: 0.01)
                        expect(Array(jobRunner.detailsFor(state: .running).keys))
                            .to(equal([100]))
                    }
                }
                // MARK: ---- with dependencies
                
                context("with dependencies") {
                    it("starts dependencies first") {
                        job1 = job1.with(details: TestDetails(completeTime: 1))
                        job2 = job2.with(details: TestDetails(completeTime: 2))
                        
                        mockStorage.write { db in
                            try job1.insert(db)
                            try job2.insert(db)
                            try JobDependencies(jobId: job1.id!, dependantId: job2.id!).insert(db)
                            
                            jobRunner.upsert(db, job: job1, canStartJob: true, dependencies: dependencies)
                        }
                        
                        // Make sure the dependency is run
                        expect(Array(jobRunner.detailsFor(state: .running, variant: .attachmentUpload).keys))
                            .toEventually(
                                equal([101]),
                                timeout: .milliseconds(50)
                            )
                    }
                    
                    it("removes the initial job from the queue") {
                        job1 = job1.with(details: TestDetails(completeTime: 1))
                        job2 = job2.with(details: TestDetails(completeTime: 2))
                        
                        mockStorage.write { db in
                            try job1.insert(db)
                            try job2.insert(db)
                            try JobDependencies(jobId: job1.id!, dependantId: job2.id!).insert(db)
                            
                            jobRunner.upsert(db, job: job1, canStartJob: true, dependencies: dependencies)
                        }
                        
                        // Make sure the initial job is removed from the queue
                        expect(Array(jobRunner.detailsFor(state: .running, variant: .attachmentUpload).keys))
                            .toEventually(
                                equal([101]),
                                timeout: .milliseconds(50)
                            )
                        expect(jobRunner.detailsFor(state: .running, variant: .messageSend).keys).toNot(contain(100))
                    }
                
                    it("starts the initial job when the dependencies succeed") {
                        job1 = job1.with(details: TestDetails(completeTime: 2))
                        job2 = job2.with(details: TestDetails(completeTime: 1))
                        
                        mockStorage.write { db in
                            try job1.insert(db)
                            try job2.insert(db)
                            try JobDependencies(jobId: job1.id!, dependantId: job2.id!).insert(db)
                            
                            jobRunner.upsert(db, job: job1, canStartJob: true, dependencies: dependencies)
                        }
                        
                        // Make sure the dependency is run
                        expect(Array(jobRunner.detailsFor(state: .running, variant: .attachmentUpload).keys))
                            .toEventually(
                                equal([101]),
                                timeout: .milliseconds(50)
                            )
                        expect(jobRunner.detailsFor(state: .running, variant: .messageSend).keys).toNot(contain(100))
                        
                        // Make sure the initial job starts
                        dependencies.fixedTime = 1
                        expect(Array(jobRunner.detailsFor(state: .running, variant: .messageSend).keys))
                            .toEventually(
                                equal([100]),
                                timeout: .milliseconds(50)
                            )
                    }
                    
                    it("does not start the initial job if the dependencies are deferred") {
                        job1 = job1.with(details: TestDetails(result: .failure, completeTime: 2))
                        job2 = job2.with(details: TestDetails(result: .deferred, completeTime: 1))
                        
                        mockStorage.write { db in
                            try job1.insert(db)
                            try job2.insert(db)
                            try JobDependencies(jobId: job1.id!, dependantId: job2.id!).insert(db)
                            
                            jobRunner.upsert(db, job: job1, canStartJob: true, dependencies: dependencies)
                        }
                        
                        // Make sure the dependency is run
                        expect(Array(jobRunner.detailsFor(state: .running, variant: .attachmentUpload).keys))
                            .toEventually(
                                equal([101]),
                                timeout: .milliseconds(50)
                            )
                        expect(jobRunner.detailsFor(state: .running, variant: .messageSend).keys).toNot(contain(100))
                        
                        // Make sure there are no running jobs
                        dependencies.fixedTime = 1
                        expect(Array(jobRunner.detailsFor(state: .running).keys))
                            .toEventually(
                                beEmpty(),
                                timeout: .milliseconds(50)
                            )
                    }
                    
                    it("does not start the initial job if the dependencies fail") {
                        job1 = job1.with(details: TestDetails(result: .failure, completeTime: 2))
                        job2 = job2.with(details: TestDetails(result: .failure, completeTime: 1))
                        
                        mockStorage.write { db in
                            try job1.insert(db)
                            try job2.insert(db)
                            try JobDependencies(jobId: job1.id!, dependantId: job2.id!).insert(db)
                            
                            jobRunner.upsert(db, job: job1, canStartJob: true, dependencies: dependencies)
                        }
                        
                        // Make sure the dependency is run
                        expect(Array(jobRunner.detailsFor(state: .running, variant: .attachmentUpload).keys))
                            .toEventually(
                                equal([101]),
                                timeout: .milliseconds(50)
                            )
                        expect(jobRunner.detailsFor(state: .running, variant: .messageSend).keys).toNot(contain(100))
                        
                        // Make sure there are no running jobs
                        dependencies.fixedTime = 1
                        expect(Array(jobRunner.detailsFor(state: .running).keys))
                            .toEventually(
                                beEmpty(),
                                timeout: .milliseconds(50)
                            )
                    }
                    
                    it("does not delete the initial job if the dependencies fail") {
                        job1 = job1.with(details: TestDetails(result: .failure, completeTime: 2))
                        job2 = job2.with(details: TestDetails(result: .failure, completeTime: 1))
                        
                        mockStorage.write { db in
                            try job1.insert(db)
                            try job2.insert(db)
                            try JobDependencies(jobId: job1.id!, dependantId: job2.id!).insert(db)
                            
                            jobRunner.upsert(db, job: job1, canStartJob: true, dependencies: dependencies)
                        }
                        
                        // Make sure the dependency is run
                        expect(Array(jobRunner.detailsFor(state: .running, variant: .attachmentUpload).keys))
                            .toEventually(
                                equal([101]),
                                timeout: .milliseconds(50)
                            )
                        expect(jobRunner.detailsFor(state: .running, variant: .messageSend).keys).toNot(contain(100))
                        
                        // Make sure there are no running jobs
                        dependencies.fixedTime = 1
                        expect(Array(jobRunner.detailsFor(state: .running, variant: .attachmentUpload).keys))
                            .toEventually(
                                beEmpty(),
                                timeout: .milliseconds(50)
                            )
                        
                        // Stop the queues so it doesn't run out of retry attempts
                        jobRunner.stopAndClearPendingJobs(exceptForVariant: nil, onComplete: nil)
                        
                        // Make sure the jobs still exist
                        expect(mockStorage.read { db in try Job.fetchCount(db) }).to(equal(2))
                    }
                    
                    it("deletes the initial job if the dependencies permanently fail") {
                        job1 = job1.with(details: TestDetails(result: .failure, completeTime: 2))
                        job2 = job2.with(details: TestDetails(result: .permanentFailure, completeTime: 1))
                        
                        mockStorage.write { db in
                            try job1.insert(db)
                            try job2.insert(db)
                            try JobDependencies(jobId: job1.id!, dependantId: job2.id!).insert(db)
                            
                            jobRunner.upsert(db, job: job1, canStartJob: true, dependencies: dependencies)
                        }
                        
                        // Make sure the dependency is run
                        expect(Array(jobRunner.detailsFor(state: .running, variant: .attachmentUpload).keys))
                            .toEventually(
                                equal([101]),
                                timeout: .milliseconds(50)
                            )
                        expect(jobRunner.detailsFor(state: .running, variant: .messageSend).keys).toNot(contain(100))
                        
                        // Make sure there are no running jobs
                        dependencies.fixedTime = 1
                        expect(Array(jobRunner.detailsFor(state: .running, variant: .attachmentUpload).keys))
                            .toEventually(
                                beEmpty(),
                                timeout: .milliseconds(50)
                            )
                        
                        // Make sure the jobs were deleted
                        expect(mockStorage.read { db in try Job.fetchCount(db) }).to(equal(0))
                    }
                }
            }
            
            // MARK: -- when completing jobs
            
            context("when completing jobs") {
                beforeEach {
                    jobRunner.appDidFinishLaunching(dependencies: dependencies)
                }
                
                // MARK: ---- by succeeding
                
                context("by succeeding") {
                    it("removes the job from the queue") {
                        job1 = job1.with(details: TestDetails(result: .success, completeTime: 1))
                        
                        mockStorage.write { db in
                            try job1.insert(db)
                            
                            jobRunner.upsert(db, job: job1, canStartJob: true, dependencies: dependencies)
                        }
                        
                        // Make sure the dependency is run
                        expect(Array(jobRunner.detailsFor(state: .running).keys))
                            .toEventually(
                                equal([100]),
                                timeout: .milliseconds(50)
                            )
                        
                        // Make sure there are no running jobs
                        dependencies.fixedTime = 1
                        expect(Array(jobRunner.detailsFor(state: .running).keys))
                            .toEventually(
                                beEmpty(),
                                timeout: .milliseconds(50)
                            )
                    }
                    
                    it("deletes the job") {
                        job1 = job1.with(details: TestDetails(result: .success, completeTime: 1))
                        
                        mockStorage.write { db in
                            try job1.insert(db)
                            
                            jobRunner.upsert(db, job: job1, canStartJob: true, dependencies: dependencies)
                        }
                        
                        // Make sure the dependency is run
                        expect(Array(jobRunner.detailsFor(state: .running).keys))
                            .toEventually(
                                equal([100]),
                                timeout: .milliseconds(50)
                            )
                        
                        // Make sure there are no running jobs
                        dependencies.fixedTime = 1
                        expect(Array(jobRunner.detailsFor(state: .running).keys))
                            .toEventually(
                                beEmpty(),
                                timeout: .milliseconds(50)
                            )
                        
                        // Make sure the jobs were deleted
                        expect(mockStorage.read { db in try Job.fetchCount(db) }).to(equal(0))
                    }
                }
                
                // MARK: ---- by deferring
                
                context("by deferring") {
                    it("reschedules the job to run again later") {
                        job1 = job1.with(details: TestDetails(result: .deferred, completeTime: 1))
                        
                        mockStorage.write { db in
                            try job1.insert(db)
                            
                            jobRunner.upsert(db, job: job1, canStartJob: true, dependencies: dependencies)
                        }
                        
                        // Make sure the dependency is run
                        expect(Array(jobRunner.detailsFor(state: .running).keys))
                            .toEventually(
                                equal([100]),
                                timeout: .milliseconds(50)
                            )
                        
                        // Make sure there are no running jobs
                        dependencies.fixedTime = 1
                        dependencies.date = Date(timeIntervalSince1970: 1234567890 + 1)
                        expect(jobRunner.detailsFor(state: .running))
                            .toEventually(
                                equal([100: try! JSONEncoder().encode(TestDetails(result: .deferred, completeTime: 2))]),
                                timeout: .milliseconds(50)
                            )
                    }
                    
                    it("does not delete the job") {
                        job1 = job1.with(details: TestDetails(result: .deferred, completeTime: 1))
                        
                        mockStorage.write { db in
                            try job1.insert(db)
                            
                            jobRunner.upsert(db, job: job1, canStartJob: true, dependencies: dependencies)
                        }
                        
                        // Make sure the dependency is run
                        expect(Array(jobRunner.detailsFor(state: .running).keys))
                            .toEventually(
                                equal([100]),
                                timeout: .milliseconds(50)
                            )
                        
                        // Make sure there are no running jobs
                        dependencies.fixedTime = 1
                        dependencies.date = Date(timeIntervalSince1970: 1234567890 + 1)
                        expect(jobRunner.detailsFor(state: .running))
                            .toEventually(
                                equal([100: try! JSONEncoder().encode(TestDetails(result: .deferred, completeTime: 2))]),
                                timeout: .milliseconds(50)
                            )
                        
                        // Make sure the jobs were deleted
                        expect(mockStorage.read { db in try Job.fetchCount(db) }).toNot(equal(0))
                    }
                    
                    it("fails the job if it is deferred too many times") {
                        job1 = job1.with(details: TestDetails(result: .deferred, completeTime: 1))
                        
                        mockStorage.write { db in
                            try job1.insert(db)
                            
                            jobRunner.upsert(db, job: job1, canStartJob: true, dependencies: dependencies)
                        }
                        
                        // Make sure it runs
                        expect(Array(jobRunner.detailsFor(state: .running).keys))
                            .toEventually(
                                equal([100]),
                                timeout: .milliseconds(50)
                            )
                        dependencies.fixedTime = 1
                        expect(Array(jobRunner.detailsFor(state: .running).keys))
                            .toEventually(
                                beEmpty(),
                                timeout: .milliseconds(50)
                            )
                        
                        // Restart the JobRunner
                        dependencies.date = Date(timeIntervalSince1970: 1234567890 + 0.5)
                        jobRunner.startNonBlockingQueues(dependencies: dependencies)
                        
                        // Make sure it finishes once
                        expect(jobRunner.detailsFor(state: .running))
                            .toEventually(
                                equal([100: try! JSONEncoder().encode(TestDetails(result: .deferred, completeTime: 2))]),
                                timeout: .milliseconds(50)
                            )
                        dependencies.fixedTime = 2
                        expect(Array(jobRunner.detailsFor(state: .running).keys))
                            .toEventually(
                                beEmpty(),
                                timeout: .milliseconds(50)
                            )
                        
                        // Restart the JobRunner
                        dependencies.date = Date(timeIntervalSince1970: 1234567890 + 1)
                        jobRunner.startNonBlockingQueues(dependencies: dependencies)
                        
                        // Make sure it finishes twice
                        expect(jobRunner.detailsFor(state: .running))
                            .toEventually(
                                equal([100: try! JSONEncoder().encode(TestDetails(result: .deferred, completeTime: 3))]),
                                timeout: .milliseconds(50)
                            )
                        dependencies.fixedTime = 3
                        expect(Array(jobRunner.detailsFor(state: .running).keys))
                            .toEventually(
                                beEmpty(),
                                timeout: .milliseconds(50)
                            )
                        
                        // Restart the JobRunner
                        dependencies.date = Date(timeIntervalSince1970: 1234567890 + 1.5)
                        jobRunner.startNonBlockingQueues(dependencies: dependencies)
                        
                        // Make sure it's finishes the last time
                        expect(jobRunner.detailsFor(state: .running))
                            .toEventually(
                                equal([100: try! JSONEncoder().encode(TestDetails(result: .deferred, completeTime: 4))]),
                                timeout: .milliseconds(50)
                            )
                        dependencies.fixedTime = 4
                        expect(Array(jobRunner.detailsFor(state: .running).keys))
                            .toEventually(
                                beEmpty(),
                                timeout: .milliseconds(50)
                            )
                        
                        // Make sure the job was marked as failed
                        expect(mockStorage.read { db in try Job.fetchOne(db, id: 100)?.failureCount }).to(equal(1))
                    }
                }
                
                // MARK: ---- by failing
                
                context("by failing") {
                    it("removes the job from the queue") {
                        job1 = job1.with(details: TestDetails(result: .failure, completeTime: 1))
                        
                        mockStorage.write { db in
                            try job1.insert(db)
                            
                            jobRunner.upsert(db, job: job1, canStartJob: true, dependencies: dependencies)
                        }
                        
                        // Make sure the dependency is run
                        expect(Array(jobRunner.detailsFor(state: .running).keys))
                            .toEventually(
                                equal([100]),
                                timeout: .milliseconds(50)
                            )
                        
                        // Make sure there are no running jobs
                        dependencies.fixedTime = 1
                        dependencies.date = Date(timeIntervalSince1970: 1234567890 + 1)
                        expect(Array(jobRunner.detailsFor(state: .running).keys))
                            .toEventually(
                                beEmpty(),
                                timeout: .milliseconds(50)
                            )
                    }
                    
                    it("does not delete the job") {
                        job1 = job1.with(details: TestDetails(result: .failure, completeTime: 1))
                        
                        mockStorage.write { db in
                            try job1.insert(db)
                            
                            jobRunner.upsert(db, job: job1, canStartJob: true, dependencies: dependencies)
                        }
                        
                        // Make sure the dependency is run
                        expect(Array(jobRunner.detailsFor(state: .running).keys))
                            .toEventually(
                                equal([100]),
                                timeout: .milliseconds(50)
                            )
                        
                        // Make sure there are no running jobs
                        dependencies.fixedTime = 1
                        dependencies.date = Date(timeIntervalSince1970: 1234567890 + 1)
                        expect(Array(jobRunner.detailsFor(state: .running).keys))
                            .toEventually(
                                beEmpty(),
                                timeout: .milliseconds(50)
                            )
                        
                        // Make sure the jobs were deleted
                        expect(mockStorage.read { db in try Job.fetchCount(db) }).toNot(equal(0))
                    }
                }
                
                // MARK: ---- by permanently failing
                
                context("by permanently failing") {
                    it("removes the job from the queue") {
                        job1 = job1.with(details: TestDetails(result: .permanentFailure, completeTime: 1))
                        
                        mockStorage.write { db in
                            try job1.insert(db)
                            
                            jobRunner.upsert(db, job: job1, canStartJob: true, dependencies: dependencies)
                        }
                        
                        // Make sure the dependency is run
                        expect(Array(jobRunner.detailsFor(state: .running).keys))
                            .toEventually(
                                equal([100]),
                                timeout: .milliseconds(50)
                            )
                        
                        // Make sure there are no running jobs
                        dependencies.fixedTime = 1
                        dependencies.date = Date(timeIntervalSince1970: 1234567890 + 1)
                        expect(Array(jobRunner.detailsFor(state: .running).keys))
                            .toEventually(
                                beEmpty(),
                                timeout: .milliseconds(50)
                            )
                    }
                    
                    it("deletes the job") {
                        job1 = job1.with(details: TestDetails(result: .permanentFailure, completeTime: 1))
                        
                        mockStorage.write { db in
                            try job1.insert(db)
                            
                            jobRunner.upsert(db, job: job1, canStartJob: true, dependencies: dependencies)
                        }
                        
                        // Make sure the dependency is run
                        expect(Array(jobRunner.detailsFor(state: .running).keys))
                            .toEventually(
                                equal([100]),
                                timeout: .milliseconds(50)
                            )
                        
                        // Make sure there are no running jobs
                        dependencies.fixedTime = 1
                        dependencies.date = Date(timeIntervalSince1970: 1234567890 + 1)
                        expect(Array(jobRunner.detailsFor(state: .running).keys))
                            .toEventually(
                                beEmpty(),
                                timeout: .milliseconds(50)
                            )
                        
                        // Make sure the jobs were deleted
                        expect(mockStorage.read { db in try Job.fetchCount(db) }).to(equal(0))
                    }
                }
            }
        }
    }
}
