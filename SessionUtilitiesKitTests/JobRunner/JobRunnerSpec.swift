// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB

import Quick
import Nimble

@testable import SessionUtilitiesKit

class JobRunnerSpec: QuickSpec {
    enum TestSuccessfulJob: JobExecutor {
        static let maxFailureCount: Int = 0
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
            guard dependencies.date.timeIntervalSinceNow > 0 else { return success(job, true, dependencies) }
            
            queue.asyncAfter(deadline: .now() + .milliseconds(Int(dependencies.date.timeIntervalSinceNow * 1000))) {
                success(job, true, dependencies)
            }
        }
    }
    
    enum TestFailedJob: JobExecutor {
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
            guard dependencies.date.timeIntervalSinceNow > 0 else { return failure(job, nil, false, dependencies) }
            
            queue.asyncAfter(deadline: .now() + .milliseconds(Int(dependencies.date.timeIntervalSinceNow * 1000))) {
                failure(job, nil, false, dependencies)
            }
        }
    }
    
    enum TestPermanentFailureJob: JobExecutor {
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
            guard dependencies.date.timeIntervalSinceNow > 0 else { return failure(job, nil, true, dependencies) }
            
            queue.asyncAfter(deadline: .now() + .milliseconds(Int(dependencies.date.timeIntervalSinceNow * 1000))) {
                failure(job, nil, true, dependencies)
            }
        }
    }
    
    enum TestDeferredJob: JobExecutor {
        static let maxFailureCount: Int = 0
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
            guard dependencies.date.timeIntervalSinceNow > 0 else { return deferred(job, dependencies) }
            
            queue.asyncAfter(deadline: .now() + .milliseconds(Int(dependencies.date.timeIntervalSinceNow * 1000))) {
                deferred(job, dependencies)
            }
        }
    }
    
    struct TestDetails: Codable {
        public let intValue: Int64
        public let stringValue: String
    }
    
    struct InvalidDetails: Codable {
        func encode(to encoder: Encoder) throws { throw HTTP.Error.parsingFailed }
    }
    
    // MARK: - Spec

    override func spec() {
        var jobRunner: JobRunnerType!
        var job1: Job!
        var job2: Job!
        var jobDetails: TestDetails!
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
                jobDetails = TestDetails(
                    intValue: 100,
                    stringValue: "200"
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
                    details: try! JSONEncoder().encode(jobDetails)
                )
                
                jobRunner = JobRunner(isTestingJobRunner: true, dependencies: dependencies)
                
                // Need to assign this to ensure it's used by nested dependencies
                dependencies.jobRunner = jobRunner
            }
            
            afterEach {
                jobRunner.stopAndClearPendingJobs()
                jobRunner = nil
                mockStorage = nil
                dependencies = nil
            }
            // MARK: -- when configuring
            
            context("when configuring") {
                it("adds an executor correctly") {
                    jobRunner.appDidFinishLaunching(dependencies: dependencies)
                    
                    // First check that it fails to start
                    dependencies.date = Date().addingTimeInterval(20 / 1000)    // Complete job after delay
                    
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
                            timeout: .milliseconds(10)
                        )
                    
                    jobRunner.setExecutor(TestSuccessfulJob.self, for: .messageSend)
                    
                    // Then check that it succeeded to start
                    dependencies.date = Date().addingTimeInterval(20 / 1000)    // Complete job after delay
                    
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
                            timeout: .milliseconds(10)
                        )
                }
            }
            
            // MARK: -- when managing state
            
            context("when managing state") {
                
                // MARK: ---- by checking if a job is currently running
                
                context("by checking if a job is currently running") {
                    beforeEach {
                        jobRunner.setExecutor(TestSuccessfulJob.self, for: .messageSend)
                    }
                    
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
                        jobRunner.appDidFinishLaunching(dependencies: dependencies)
                        
                        dependencies.date = Date().addingTimeInterval(20 / 1000)    // Complete job after delay
                        
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
                                timeout: .milliseconds(10)
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
                            details: nil
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
                        
                        dependencies.date = Date().addingTimeInterval(20 / 1000)    // Complete job after delay
                        jobRunner.appDidFinishLaunching(dependencies: dependencies)
                        
                        expect(jobRunner.isCurrentlyRunning(job2))
                            .toEventually(
                                beTrue(),
                                timeout: .milliseconds(10)
                            )
                    }
                }
                
                // MARK: ---- by getting the details for jobs
                
                context("by getting the details for jobs") {
                    beforeEach {
                        jobRunner.setExecutor(TestSuccessfulJob.self, for: .messageSend)
                        jobRunner.setExecutor(TestSuccessfulJob.self, for: .attachmentUpload)
                        jobRunner.setExecutor(TestSuccessfulJob.self, for: .attachmentDownload)
                    }
                    
                    it("returns an empty dictionary when there are no jobs") {
                        expect(jobRunner.details()).to(equal([:]))
                    }
                    
                    it("returns an empty dictionary when there are no jobs matching the filters") {
                        jobRunner.appDidFinishLaunching(dependencies: dependencies)
                        
                        dependencies.date = Date().addingTimeInterval(20 / 1000)    // Complete job after delay
                        
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
                                timeout: .milliseconds(10)
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
                                timeout: .milliseconds(10)
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
                            details: try! JSONEncoder().encode(jobDetails)
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
                            details: nil
                        )
                        dependencies.date = Date().addingTimeInterval(20 / 1000)    // Complete job after delay
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
                        expect(jobRunner.detailsFor(state: .running))
                            .toEventually(
                                equal([100: try! JSONEncoder().encode(jobDetails)]),
                                timeout: .milliseconds(10)
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
                            details: nil
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
                            details: try! JSONEncoder().encode(jobDetails)
                        )
                        dependencies.date = Date().addingTimeInterval(20 / 1000)    // Complete job after delay
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
                                equal([101: try! JSONEncoder().encode(jobDetails)]),
                                timeout: .milliseconds(10)
                            )
                        expect(Array(jobRunner.details().keys).sorted()).to(equal([100, 101]))
                    }
                    
                    it("can filter to specific variants") {
                        dependencies.date = Date().addingTimeInterval(20 / 1000)    // Complete job after delay
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
                                equal([101: try! JSONEncoder().encode(jobDetails)]),
                                timeout: .milliseconds(10)
                            )
                        expect(Array(jobRunner.details().keys).sorted()).to(equal([100, 101]))
                    }
                    
                    it("includes non blocking jobs") {
                        jobRunner.appDidFinishLaunching(dependencies: dependencies)
                        
                        dependencies.date = Date().addingTimeInterval(20 / 1000)    // Complete job after delay
                        
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
                                equal([101: try! JSONEncoder().encode(jobDetails)]),
                                timeout: .milliseconds(10)
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
                            details: try! JSONEncoder().encode(jobDetails)
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
                        
                        dependencies.date = Date().addingTimeInterval(20 / 1000)    // Complete job after delay
                        jobRunner.appDidFinishLaunching(dependencies: dependencies)
                        
                        expect(jobRunner.detailsFor(state: .running, variant: .attachmentUpload))
                            .toEventually(
                                equal([101: try! JSONEncoder().encode(jobDetails)]),
                                timeout: .milliseconds(10)
                            )
                    }
                }
                
                // MARK: ---- by checking for an existing job
                
                context("by checking for an existing job") {
                    beforeEach {
                        jobRunner.setExecutor(TestSuccessfulJob.self, for: .attachmentUpload)
                    }
                    
                    it("returns false for a queue that doesn't exist") {
                        jobRunner = JobRunner(
                            isTestingJobRunner: true,
                            variantsToExclude: [.attachmentUpload],
                            dependencies: dependencies
                        )
                        
                        expect(jobRunner.hasJob(of: .attachmentUpload, with: jobDetails))
                            .to(beFalse())
                    }
                    
                    it("returns false when the provided details fail to decode") {
                        expect(jobRunner.hasJob(of: .attachmentUpload, with: InvalidDetails()))
                            .to(beFalse())
                    }
                    
                    it("returns false when there is not a pending or running job") {
                        expect(jobRunner.hasJob(of: .attachmentUpload, with: jobDetails))
                            .to(beFalse())
                    }
                    
                    it("returns true when there is a pending job") {
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
                                timeout: .milliseconds(10)
                            )
                        expect(jobRunner.hasJob(of: .attachmentUpload, with: jobDetails))
                            .to(beTrue())
                    }
                    
                    it("returns true when there is a running job") {
                        jobRunner.appDidFinishLaunching(dependencies: dependencies)
                        
                        dependencies.date = Date().addingTimeInterval(20 / 1000)    // Complete job after delay
                        
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
                                timeout: .milliseconds(10)
                            )
                        expect(jobRunner.hasJob(of: .attachmentUpload, with: jobDetails))
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
                            details: try! JSONEncoder().encode(jobDetails)
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
                        
                        dependencies.date = Date().addingTimeInterval(20 / 1000)    // Complete job after delay
                        jobRunner.appDidFinishLaunching(dependencies: dependencies)
                        
                        expect(Array(jobRunner.detailsFor(state: .running, variant: .attachmentUpload).keys))
                            .toEventually(
                                equal([101]),
                                timeout: .milliseconds(10)
                            )
                        expect(jobRunner.hasJob(of: .attachmentUpload, with: jobDetails))
                            .to(beTrue())
                    }
                    
                    it("returns true when there is a non blocking job") {
                        dependencies.date = Date().addingTimeInterval(20 / 1000)    // Complete job after delay
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
                                timeout: .milliseconds(10)
                            )
                        expect(jobRunner.hasJob(of: .attachmentUpload, with: jobDetails))
                            .to(beTrue())
                    }
                }
                
                // MARK: ---- by being notified of app launch
                
                context("by being notified of app launch") {
                    beforeEach {
                        jobRunner.setExecutor(TestSuccessfulJob.self, for: .messageSend)
                    }
                    
                    it("does not start a job before getting the app launch call") {
                        dependencies.date = Date().addingTimeInterval(20 / 1000)    // Complete job after delay
                        
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
                                timeout: .milliseconds(10)
                            )
                    }
                    
                    it("does nothing if there are no app launch jobs") {
                        dependencies.date = Date().addingTimeInterval(20 / 1000)    // Complete job after delay
                        
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
                                timeout: .milliseconds(10)
                            )
                    }
                    
                    it("starts the job queues after completing blocking app launch jobs") {
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
                            details: nil
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
                                timeout: .milliseconds(10)
                            )
                        expect(jobRunner.isCurrentlyRunning(job2)).to(beFalse())
                        
                        // Make sure it starts
                        dependencies.date = Date().addingTimeInterval(20 / 1000)    // Complete job after delay
                        jobRunner.appDidFinishLaunching(dependencies: dependencies)
                        
                        // Blocking job running but blocked job not
                        expect(jobRunner.isCurrentlyRunning(job2))
                            .toEventually(
                                beTrue(),
                                timeout: .milliseconds(10)
                            )
                        expect(jobRunner.isCurrentlyRunning(job1)).to(beFalse())
                        
                        // Blocked job eventually starts
                        dependencies.date = Date().addingTimeInterval(20 / 1000)    // Complete job after delay
                        expect(jobRunner.isCurrentlyRunning(job1))
                            .toEventually(
                                beTrue(),
                                timeout: .milliseconds(20)
                            )
                    }
                    
                    it("starts the job queues alongside non blocking app launch jobs") {
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
                            details: nil
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
                                timeout: .milliseconds(10)
                            )
                        
                        // Make sure it starts
                        dependencies.date = Date().addingTimeInterval(20 / 1000)    // Complete job after delay
                        jobRunner.appDidFinishLaunching(dependencies: dependencies)
                        
                        expect(jobRunner.isCurrentlyRunning(job1))
                            .toEventually(
                                beTrue(),
                                timeout: .milliseconds(10)
                            )
                        expect(jobRunner.isCurrentlyRunning(job2))
                            .toEventually(
                                beTrue(),
                                timeout: .milliseconds(10)
                            )
                    }
                }
                
                // MARK: ---- by being notified of app becoming active
                
                context("by being notified of app becoming active") {
                    beforeEach {
                        jobRunner.setExecutor(TestSuccessfulJob.self, for: .messageSend)
                    }
                    
                    it("does not start a job before getting the app active call") {
                        dependencies.date = Date().addingTimeInterval(20 / 1000)    // Complete job after delay
                        
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
                                timeout: .milliseconds(10)
                            )
                    }
                    
                    it("does not start the job queues if there are no app active jobs and blocking jobs are running") {
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
                            details: nil
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
                                timeout: .milliseconds(10)
                            )
                        
                        // Start the blocking job
                        dependencies.date = Date().addingTimeInterval(20 / 1000)    // Complete job after delay
                        jobRunner.appDidFinishLaunching(dependencies: dependencies)
                        
                        // Make sure the other queues don't start
                        dependencies.date = Date().addingTimeInterval(30 / 1000)    // Complete job after delay
                        jobRunner.appDidBecomeActive(dependencies: dependencies)
                        
                        expect(jobRunner.isCurrentlyRunning(job1))
                            .toEventually(
                                beFalse(),
                                timeout: .milliseconds(10)
                            )
                        expect(jobRunner.isCurrentlyRunning(job1))
                            .toEventually(
                                beFalse(),
                                timeout: .milliseconds(20)
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
                            details: nil
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
                            details: nil
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
                                timeout: .milliseconds(10)
                            )
                        
                        // Start the blocking queue
                        dependencies.date = Date().addingTimeInterval(20 / 1000)    // Complete job after delay
                        jobRunner.appDidFinishLaunching(dependencies: dependencies)
                        
                        // Make sure the other queues don't start
                        dependencies.date = Date().addingTimeInterval(30 / 1000)    // Complete job after delay
                        jobRunner.appDidBecomeActive(dependencies: dependencies)
                        
                        expect(jobRunner.isCurrentlyRunning(job1))
                            .toEventually(
                                beFalse(),
                                timeout: .milliseconds(10)
                            )
                        expect(jobRunner.isCurrentlyRunning(job1))
                            .toEventually(
                                beFalse(),
                                timeout: .milliseconds(20)
                            )
                    }
                    
                    it("starts the job queues if there are no app active jobs") {
                        dependencies.date = Date().addingTimeInterval(20 / 1000)    // Complete job after delay
                        
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
                                timeout: .milliseconds(10)
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
                            details: nil
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
                            details: nil
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
                                timeout: .milliseconds(10)
                            )
                        
                        // Make sure the queues are started
                        dependencies.date = Date().addingTimeInterval(20 / 1000)    // Complete job after delay
                        jobRunner.appDidBecomeActive(dependencies: dependencies)
                        
                        expect(jobRunner.isCurrentlyRunning(job1))
                            .toEventually(
                                beTrue(),
                                timeout: .milliseconds(10)
                            )
                        expect(jobRunner.isCurrentlyRunning(job2)).to(beTrue())
                    }
                }
            }
            
            // MARK: -- when running jobs
            
            context("when running jobs") {
                beforeEach {
                    jobRunner.setExecutor(TestSuccessfulJob.self, for: .messageSend)
                    jobRunner.setExecutor(TestSuccessfulJob.self, for: .attachmentUpload)
                    jobRunner.appDidFinishLaunching(dependencies: dependencies)
                }
                
                // MARK: ---- with dependencies
                
                context("with dependencies") {
                    it("starts dependencies first") {
                        dependencies.date = Date().addingTimeInterval(20 / 1000)    // Complete job after delay
                        
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
                                timeout: .milliseconds(10)
                            )
                    }
                    
                    it("removes the initial job from the queue") {
                        dependencies.date = Date().addingTimeInterval(20 / 1000)    // Complete job after delay
                        
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
                                timeout: .milliseconds(10)
                            )
                        expect(jobRunner.detailsFor(state: .running, variant: .messageSend).keys).toNot(contain(100))
                    }
                
                    it("starts the initial job when the dependencies succeed") {
                        dependencies.date = Date().addingTimeInterval(20 / 1000)    // Complete job after delay
                        
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
                                timeout: .milliseconds(10)
                            )
                        expect(jobRunner.detailsFor(state: .running, variant: .messageSend).keys).toNot(contain(100))
                        
                        // Make sure the initial job starts
                        dependencies.date = Date().addingTimeInterval(20 / 1000)    // Complete job after delay
                        expect(Array(jobRunner.detailsFor(state: .running, variant: .messageSend).keys))
                            .toEventually(
                                equal([100]),
                                timeout: .milliseconds(20)
                            )
                    }
                    
                    it("does not start the initial job if the dependencies fail") {
                        jobRunner.setExecutor(TestFailedJob.self, for: .attachmentUpload)
                        
                        dependencies.date = Date().addingTimeInterval(20 / 1000)    // Fail job after delay
                        
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
                                timeout: .milliseconds(10)
                            )
                        expect(jobRunner.detailsFor(state: .running, variant: .messageSend).keys).toNot(contain(100))
                        
                        // Make sure there are no running jobs
                        expect(Array(jobRunner.detailsFor(state: .running).keys))
                            .toEventually(
                                beEmpty(),
                                timeout: .milliseconds(20)
                            )
                    }
                    
                    it("does not delete the initial job if the dependencies fail") {
                        jobRunner.setExecutor(TestFailedJob.self, for: .attachmentUpload)
                        
                        dependencies.date = Date().addingTimeInterval(20 / 1000)    // Fail job after delay
                        
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
                                timeout: .milliseconds(10)
                            )
                        expect(jobRunner.detailsFor(state: .running, variant: .messageSend).keys).toNot(contain(100))
                        
                        // Make sure there are no running jobs
                        dependencies.date = Date().addingTimeInterval(20 / 1000)    // Delay subsequent runs
                        expect(Array(jobRunner.detailsFor(state: .running, variant: .attachmentUpload).keys))
                            .toEventually(
                                beEmpty(),
                                timeout: .milliseconds(20)
                            )
                        
                        // Stop the queues so it doesn't run out of retry attempts
                        jobRunner.stopAndClearPendingJobs(exceptForVariant: nil, onComplete: nil)
                        
                        // Make sure the jobs still exist
                        expect(mockStorage.read { db in try Job.fetchCount(db) }).to(equal(2))
                    }
                    
                    it("deletes the initial job if the dependencies permanently fail") {
                        jobRunner.setExecutor(TestPermanentFailureJob.self, for: .attachmentUpload)
                        
                        dependencies.date = Date().addingTimeInterval(20 / 1000)    // Fail job after delay
                        
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
                                timeout: .milliseconds(10)
                            )
                        expect(jobRunner.detailsFor(state: .running, variant: .messageSend).keys).toNot(contain(100))
                        
                        // Make sure there are no running jobs
                        expect(Array(jobRunner.detailsFor(state: .running, variant: .attachmentUpload).keys))
                            .toEventually(
                                beEmpty(),
                                timeout: .milliseconds(20)
                            )
                        
                        // Make sure the jobs were deleted
                        expect(mockStorage.read { db in try Job.fetchCount(db) }).to(equal(0))
                    }
                }
                
            }
        }
    }
}
