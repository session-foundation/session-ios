// Copyright © 2026 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import TestUtilities

import Quick
import Nimble

@testable import SessionUtilitiesKit

class JobRunnerSpec: AsyncSpec {
    override class func spec() {
        // MARK: Configuration
        @TestState var dependencies: TestDependencies! = TestDependencies { dependencies in
            dependencies.dateNow = Date(timeIntervalSince1970: 0)
            dependencies.forceSynchronous = true
        }
        @TestState var mockStorage: Storage! = SynchronousStorage(
            customWriter: try! DatabaseQueue(),
            using: dependencies
        )
        @TestState var job1: Job! = Job(
            id: 100,
            failureCount: 0,
            variant: .messageSend,
            threadId: nil,
            interactionId: nil,
            details: try? JSONEncoder(using: dependencies)
                .encode(TestDetails(completeTime: 1)),
            transientData: nil
        )
        @TestState var job2: Job! = Job(
            id: 101,
            failureCount: 0,
            variant: .attachmentUpload,
            threadId: nil,
            interactionId: nil,
            details: try? JSONEncoder(using: dependencies)
                .encode(TestDetails(completeTime: 2)),
            transientData: nil
        )
        @TestState var jobRunner: JobRunnerType!
        
        beforeEach {
            dependencies.set(singleton: .storage, to: mockStorage)
            await withCheckedContinuation { continuation in
                mockStorage.perform(
                    migrations: [
                        _001_SUK_InitialSetupMigration.self,
                        _012_AddJobPriority.self,
                        _020_AddJobUniqueHash.self,
                        _049_JobRunnerRefactorChanges.self
                    ],
                    onProgressUpdate: { _, _ in },
                    onComplete: { _ in continuation.resume() }
                )
            }
            
            jobRunner = await JobRunner(
                isTestingJobRunner: true,
                executors: [
                    .messageSend: TestJob.self,
                    .attachmentUpload: TestJob.self,
                    .messageReceive: TestJob.self,
                    .failedMessageSends: TestJob.self
                ],
                using: dependencies
            )
            dependencies.set(singleton: .jobRunner, to: jobRunner)
        }
        
        // MARK: - a JobRunner
        describe("a JobRunner") {
            afterEach {
                /// We **must** set `fixedTime` to ensure we break any loops within the `TestJob` executor
                dependencies.fixedTime = Int.max
                await jobRunner.stopAndClearJobs()
            }
            
            // MARK: -- when configuring
            context("when configuring") {
                // MARK: ---- adds an executor correctly
                it("adds an executor correctly") {
                    job1 = Job(
                        id: 100,
                        failureCount: 0,
                        variant: .disappearingMessages,
                        threadId: nil,
                        interactionId: nil,
                        details: try? JSONEncoder(using: dependencies)
                            .encode(TestDetails(completeTime: 1)),
                        transientData: nil
                    )
                    job2 = Job(
                        id: 101,
                        failureCount: 0,
                        variant: .disappearingMessages,
                        threadId: nil,
                        interactionId: nil,
                        details: try? JSONEncoder(using: dependencies)
                            .encode(TestDetails(completeTime: 1)),
                        transientData: nil
                    )
                    
                    await jobRunner.appDidBecomeActive()
                    
                    // Save the job to the database
                    try await mockStorage.writeAsync { db in _ = try job1.inserted(db) }
                    await expect { try await mockStorage.readAsync { db in try Job.fetchCount(db) } }
                        .to(equal(1))
                    
                    // Try to start the job
                    try await mockStorage.writeAsync { db in
                        jobRunner.add(db, job: job1)
                    }
                    
                    // Ensure the job isn't running, and that it has been deleted (can't retry if there
                    // is no executer so no failure counts)
                    await expect {
                        await jobRunner.jobsMatching(filters: .matchingAll)
                    }.toEventually(
                        equal([
                            JobQueue.JobQueueId(databaseId: 100): JobState(
                                queueId: JobQueue.JobQueueId(databaseId: 100),
                                job: job1,
                                jobDependencies: [],
                                executionState: .completed(
                                    result: .failed(JobRunnerError.executorMissing, isPermanent: true)),
                                resultStream: CurrentValueAsyncStream(nil)
                            )
                        ]),
                        timeout: .milliseconds(100)
                    )
                    expect(mockStorage.read { db in try Job.fetchCount(db) }).to(equal(0))
                    
                    // Add the executor and start the job again
                    await jobRunner.setExecutor(TestJob.self, for: .disappearingMessages)
                    
                    try await mockStorage.writeAsync { db in
                        jobRunner.add(db, job: job2)
                    }
                    
                    // Job is now running
                    await expect {
                        await jobRunner.jobsMatching(filters: .matchingAll)
                    }.toEventually(
                        equal([
                            JobQueue.JobQueueId(databaseId: 100): JobState(
                                queueId: JobQueue.JobQueueId(databaseId: 100),
                                job: job1,
                                jobDependencies: [],
                                executionState: .completed(
                                    result: .failed(JobRunnerError.executorMissing, isPermanent: true)
                                ),
                                resultStream: CurrentValueAsyncStream(nil)
                            ),
                            JobQueue.JobQueueId(databaseId: 101): JobState(
                                queueId: JobQueue.JobQueueId(databaseId: 101),
                                job: job2,
                                jobDependencies: [],
                                executionState: .running(task: Task(operation: {})),
                                resultStream: CurrentValueAsyncStream(nil)
                            )
                        ]),
                        timeout: .milliseconds(100)
                    )
                }
                
                // MARK: ---- by being notified of app becoming active
                context("by being notified of app becoming active") {
                    // MARK: ------ does not start a job before getting the app active call
                    it("does not start a job before getting the app active call") {
                        job1 = job1.with(details: TestDetails(completeTime: 1))
                        
                        try await mockStorage.writeAsync { db in
                            jobRunner.add(db, job: job1)
                        }
                        
                        await expect {
                            await jobRunner.jobsMatching(
                                filters: JobRunner.Filters(
                                    include: [
                                        .jobId(100)
                                    ]
                                )
                            )
                        }.to(equal([
                            JobQueue.JobQueueId(databaseId: 100): JobState(
                                queueId: JobQueue.JobQueueId(databaseId: 100),
                                job: job1,
                                jobDependencies: [],
                                executionState: .pending(lastAttempt: nil),
                                resultStream: CurrentValueAsyncStream(nil)
                            )
                        ]))
                    }
                    
                    // MARK: ------ does not start the job queues if blocking jobs are running
                    it("does not start the job queues if blocking jobs are running") {
                        try await mockStorage.writeAsync { db in
                            jobRunner.add(db, job: job2)
                        }
                        
                        // Not currently running
                        await expect {
                            await jobRunner.jobsMatching(
                                filters: JobRunner.Filters(
                                    include: [
                                        .jobId(101)
                                    ]
                                )
                            )
                        }.to(equal([
                            JobQueue.JobQueueId(databaseId: 101): JobState(
                                queueId: JobQueue.JobQueueId(databaseId: 101),
                                job: job2,
                                jobDependencies: [],
                                executionState: .pending(lastAttempt: nil),
                                resultStream: CurrentValueAsyncStream(nil)
                            )
                        ]))
                        
                        // Add the blocking job
                        await jobRunner.registerStartupJobs(
                            jobInfo: [
                                JobRunner.StartupJobInfo(
                                    variant: .failedMessageSends,
                                    block: true
                                )
                            ]
                        )
                        
                        // Notify of app active
                        await jobRunner.appDidBecomeActive()
                        
                        // Job is still not running
                        await expect {
                            await jobRunner.jobsMatching(
                                filters: JobRunner.Filters(
                                    include: [
                                        .jobId(101)
                                    ]
                                )
                            )
                        }.to(equal([
                            JobQueue.JobQueueId(databaseId: 101): JobState(
                                queueId: JobQueue.JobQueueId(databaseId: 101),
                                job: job2,
                                jobDependencies: [],
                                executionState: .pending(lastAttempt: nil),
                                resultStream: CurrentValueAsyncStream(nil)
                            )
                        ]))
                    }
                    
                    // MARK: ------ starts the job queues if there are no blocking jobs
                    it("starts the job queues if there are no blocking jobs") {
                        try await mockStorage.writeAsync { db in
                            jobRunner.add(db, job: job1)
                        }
                        
                        // Make sure it isn't already started
                        await expect {
                            await jobRunner.jobsMatching(
                                filters: JobRunner.Filters(
                                    include: [
                                        .jobId(100)
                                    ]
                                )
                            )
                        }.to(equal([
                            JobQueue.JobQueueId(databaseId: 100): JobState(
                                queueId: JobQueue.JobQueueId(databaseId: 100),
                                job: job1,
                                jobDependencies: [],
                                executionState: .pending(lastAttempt: nil),
                                resultStream: CurrentValueAsyncStream(nil)
                            )
                        ]))
                        
                        // Make sure it starts after 'appDidBecomeActive' is called
                        await jobRunner.appDidBecomeActive()
                        
                        await expect {
                            await jobRunner.jobsMatching(
                                filters: JobRunner.Filters(
                                    include: [
                                        .jobId(100)
                                    ]
                                )
                            )
                        }.to(equal([
                            JobQueue.JobQueueId(databaseId: 100): JobState(
                                queueId: JobQueue.JobQueueId(databaseId: 100),
                                job: job1,
                                jobDependencies: [],
                                executionState: .running(task: Task(operation: {})),
                                resultStream: CurrentValueAsyncStream(nil)
                            )
                        ]))
                    }
                    
                    // MARK: ------ starts the job queues after completing blocking app launch jobs
                    it("starts the job queues after completing blocking app launch jobs") {
                        let testUUID: UUID? = UUID(uuidString: "00000000-0000-0000-0000-000000000001")
                        dependencies.uuid = testUUID
                        
                        try await mockStorage.writeAsync { db in
                            jobRunner.add(db, job: job2)
                        }
                        
                        // Not currently running
                        await expect {
                            await jobRunner.jobsMatching(
                                filters: JobRunner.Filters(
                                    include: [
                                        .jobId(101)
                                    ]
                                )
                            )
                        }.to(equal([
                            JobQueue.JobQueueId(databaseId: 101): JobState(
                                queueId: JobQueue.JobQueueId(databaseId: 101),
                                job: job2,
                                jobDependencies: [],
                                executionState: .pending(lastAttempt: nil),
                                resultStream: CurrentValueAsyncStream(nil)
                            )
                        ]))
                        
                        // Add the blocking job
                        await jobRunner.registerStartupJobs(
                            jobInfo: [
                                JobRunner.StartupJobInfo(
                                    variant: .failedMessageSends,
                                    block: true
                                )
                            ]
                        )
                        
                        // Make sure it starts
                        await jobRunner.appDidBecomeActive()
                        
                        // Blocking job running but blocked job not
                        await expect {
                            await jobRunner.jobsMatching(filters: .matchingAll)
                        }.to(equal([
                            JobQueue.JobQueueId(databaseId: nil, transientId: testUUID): JobState(
                                queueId: JobQueue.JobQueueId(databaseId: nil, transientId: testUUID)!,
                                job: Job(
                                    id: nil,
                                    failureCount: 0,
                                    variant: .failedMessageSends,
                                    threadId: nil,
                                    interactionId: nil,
                                    details: nil,
                                    transientData: nil
                                ),
                                jobDependencies: [],
                                executionState: .running(task: Task(operation: {})),
                                resultStream: CurrentValueAsyncStream(nil)
                            ),
                            JobQueue.JobQueueId(databaseId: 101): JobState(
                                queueId: JobQueue.JobQueueId(databaseId: 101),
                                job: job2,
                                jobDependencies: [],
                                executionState: .pending(lastAttempt: nil),
                                resultStream: CurrentValueAsyncStream(nil)
                            )
                        ]))
                        
                        // Complete the blocking job
                        await dependencies.stepForwardInTime()
                        
                        // Blocked job eventually starts
                        await expect {
                            await jobRunner.jobsMatching(filters: .matchingAll)
                        }.to(equal([
                            JobQueue.JobQueueId(databaseId: nil, transientId: testUUID): JobState(
                                queueId: JobQueue.JobQueueId(databaseId: nil, transientId: testUUID)!,
                                job: Job(
                                    id: nil,
                                    failureCount: 0,
                                    variant: .failedMessageSends,
                                    threadId: nil,
                                    interactionId: nil,
                                    details: nil,
                                    transientData: nil
                                ),
                                jobDependencies: [],
                                executionState: .completed(result: .succeeded),
                                resultStream: CurrentValueAsyncStream(nil)
                            ),
                            JobQueue.JobQueueId(databaseId: 101): JobState(
                                queueId: JobQueue.JobQueueId(databaseId: 101),
                                job: job2,
                                jobDependencies: [],
                                executionState: .running(task: Task(operation: {})),
                                resultStream: CurrentValueAsyncStream(nil)
                            )
                        ]))
                    }
                }
            }
        }
        
        // MARK: -- when retrieving jobs
        context("when retrieving jobs") {
            // MARK: ---- returns an empty dictionary when there are no jobs
            it("returns an empty dictionary when there are no jobs") {
                await expect { await jobRunner.jobsMatching(filters: .matchingAll) }.to(beEmpty())
            }
            
            // MARK: ---- returns an empty dictionary when there are no jobs matching the filters
            it("returns an empty dictionary when there are no jobs matching the filters") {
                await jobRunner.appDidBecomeActive()
                
                try await mockStorage.writeAsync { db in
                    jobRunner.add(db, job: job2)
                }
                
                await expect {
                    await jobRunner.jobsMatching(
                        filters: JobRunner.Filters(
                            include: [.variant(.syncPushTokens)]
                        )
                    )
                }.to(beEmpty())
            }
            
            // MARK: ---- includes startup jobs
            it("includes startup jobs") {
                let testUUID: UUID? = UUID(uuidString: "00000000-0000-0000-0000-000000000001")
                dependencies.uuid = testUUID
                
                await jobRunner.registerStartupJobs(
                    jobInfo: [
                        JobRunner.StartupJobInfo(
                            variant: .failedMessageSends,
                            block: true
                        )
                    ]
                )
                await jobRunner.appDidBecomeActive()
                
                await expect {
                    await jobRunner.jobsMatching(
                        filters: JobRunner.Filters(
                            include: [
                                .executionPhase(.running)
                            ]
                        )
                    )
                }.to(equal([
                    JobQueue.JobQueueId(databaseId: nil, transientId: testUUID): JobState(
                        queueId: JobQueue.JobQueueId(databaseId: nil, transientId: testUUID)!,
                        job: Job(
                            id: nil,
                            failureCount: 0,
                            variant: .failedMessageSends,
                            threadId: nil,
                            interactionId: nil,
                            details: nil,
                            transientData: nil
                        ),
                        jobDependencies: [],
                        executionState: .running(task: Task(operation: {})),
                        resultStream: CurrentValueAsyncStream(nil)
                    )
                ]))
            }
            
            // MARK: ---- can filter to specific jobs
            it("can filter to specific jobs") {
                await jobRunner.appDidBecomeActive()
                
                try await mockStorage.writeAsync { db in
                    jobRunner.add(db, job: job1)
                    jobRunner.add(db, job: job2)
                }
                
                // Validate the filtering works
                await expect { await jobRunner.jobsMatching(filters: .matchingAll) }.toNot(beEmpty())
                await expect {
                    await jobRunner.jobsMatching(
                        filters: JobRunner.Filters(
                            include: [
                                .jobId(100)
                            ]
                        )
                    )
                }.to(equal([
                    JobQueue.JobQueueId(databaseId: 100): JobState(
                        queueId: JobQueue.JobQueueId(databaseId: 100),
                        job: job1,
                        jobDependencies: [],
                        executionState: .pending(lastAttempt: nil),
                        resultStream: CurrentValueAsyncStream(nil)
                    )
                ]))
                await expect {
                    await jobRunner.jobsMatching(
                        filters: JobRunner.Filters(
                            include: [
                                .jobId(101)
                            ]
                        )
                    )
                }.to(equal([
                    JobQueue.JobQueueId(databaseId: 101): JobState(
                        queueId: JobQueue.JobQueueId(databaseId: 101),
                        job: job2,
                        jobDependencies: [],
                        executionState: .pending(lastAttempt: nil),
                        resultStream: CurrentValueAsyncStream(nil)
                    )
                ]))
            }
            
            // MARK: ---- can filter to running jobs
            it("can filter to running jobs") {
                await jobRunner.appDidBecomeActive()
                
                try await mockStorage.writeAsync { db in
                    jobRunner.add(db, job: job1)
                    jobRunner.add(
                        db,
                        job: job2,
                        initialDependencies: [
                            .timestamp(waitUntil: TimeInterval.greatestFiniteMagnitude)
                        ]
                    )
                }
                
                // Wait for there to be data and the validate the filtering works
                await expect {
                    await jobRunner.jobsMatching(
                        filters: JobRunner.Filters(
                            include: [
                                .executionPhase(.running)
                            ]
                        )
                    )
                }.to(equal([
                    JobQueue.JobQueueId(databaseId: 100): JobState(
                        queueId: JobQueue.JobQueueId(databaseId: 100),
                        job: job1,
                        jobDependencies: [],
                        executionState: .pending(lastAttempt: nil),
                        resultStream: CurrentValueAsyncStream(nil)
                    )
                ]))
                await expect {
                    await Array(jobRunner
                        .jobsMatching(filters: .matchingAll)
                        .keys)
                    .compactMap { $0.databaseId }
                    .sorted()
                }.to(equal([100, 101]))
            }
            
            // MARK: ---- can filter to pending jobs
            it("can filter to pending jobs") {
                await jobRunner.appDidBecomeActive()
                
                try await mockStorage.writeAsync { db in
                    jobRunner.add(db, job: job1)
                    jobRunner.add(
                        db,
                        job: job2,
                        initialDependencies: [
                            .timestamp(waitUntil: TimeInterval.greatestFiniteMagnitude)
                        ]
                    )
                }
                
                // Wait for there to be data and the validate the filtering works
                await expect {
                    await jobRunner.jobsMatching(
                        filters: JobRunner.Filters(
                            include: [
                                .executionPhase(.pending)
                            ]
                        )
                    )
                }.to(equal([
                    JobQueue.JobQueueId(databaseId: 101): JobState(
                        queueId: JobQueue.JobQueueId(databaseId: 101),
                        job: job2,
                        jobDependencies: [],
                        executionState: .pending(lastAttempt: nil),
                        resultStream: CurrentValueAsyncStream(nil)
                    )
                ]))
                await expect {
                    await Array(jobRunner
                        .jobsMatching(filters: .matchingAll)
                        .keys)
                    .compactMap { $0.databaseId }
                    .sorted()
                }.to(equal([100, 101]))
            }
            
            // MARK: ---- can filter to specific variants
            it("can filter to specific variants") {
                job1 = job1.with(details: TestDetails(completeTime: 1))
                job2 = job2.with(details: TestDetails(completeTime: 2))
                await jobRunner.appDidBecomeActive()
                
                try await mockStorage.writeAsync { db in
                    jobRunner.add(db, job: job1)
                    jobRunner.add(db, job: job2)
                }
                
                // Wait for there to be data and the validate the filtering works
                await expect {
                    await jobRunner.jobsMatching(
                        filters: JobRunner.Filters(
                            include: [
                                .variant(.attachmentUpload)
                            ]
                        )
                    )
                }.to(equal([
                    JobQueue.JobQueueId(databaseId: 101): JobState(
                        queueId: JobQueue.JobQueueId(databaseId: 101),
                        job: job2,
                        jobDependencies: [],
                        executionState: .pending(lastAttempt: nil),
                        resultStream: CurrentValueAsyncStream(nil)
                    )
                ]))
                await expect {
                    await Array(jobRunner
                        .jobsMatching(filters: .matchingAll)
                        .keys)
                    .compactMap { $0.databaseId }
                    .sorted()
                }.to(equal([100, 101]))
            }
        }
        
        // MARK: -- when running jobs
        context("when running jobs") {
            beforeEach {
                await jobRunner.appDidBecomeActive()
            }
            
            // MARK: ---- does not start the job if it does not allow concurrent execution
            it("does not start the job if it does not allow concurrent execution") {
                job1 = Job(
                    id: 100,
                    failureCount: 0,
                    variant: .messageSend,
                    threadId: nil,
                    interactionId: nil,
                    details: try? JSONEncoder(using: dependencies)
                        .encode(TestDetails(
                            completeTime: 1,
                            allowConcurrentJobs: false
                        )),
                    transientData: nil
                )
                job2 = Job(
                    id: 101,
                    failureCount: 0,
                    variant: .messageSend,
                    threadId: nil,
                    interactionId: nil,
                    details: try? JSONEncoder(using: dependencies)
                        .encode(TestDetails(
                            completeTime: 1,
                            allowConcurrentJobs: false
                        )),
                    transientData: nil
                )
                
                try await mockStorage.writeAsync { db in
                    jobRunner.add(db, job: job1)
                    jobRunner.add(db, job: job2)
                }
                
                await expect {
                    await jobRunner.jobsMatching(filters: .matchingAll)
                }.to(equal([
                    JobQueue.JobQueueId(databaseId: 100): JobState(
                        queueId: JobQueue.JobQueueId(databaseId: 100),
                        job: job1,
                        jobDependencies: [],
                        executionState: .running(task: Task(operation: {})),
                        resultStream: CurrentValueAsyncStream(nil)
                    ),
                    JobQueue.JobQueueId(databaseId: 101): JobState(
                        queueId: JobQueue.JobQueueId(databaseId: 101),
                        job: job2,
                        jobDependencies: [],
                        executionState: .pending(lastAttempt: nil),
                        resultStream: CurrentValueAsyncStream(nil)
                    )
                ]))
            }
        }
        
        // MARK: ---- does not start a job until it has no dependencies
        it("does not start a job until it has no dependencies") {
            try await mockStorage.writeAsync { db in
                jobRunner.add(db, job: job1)
                jobRunner.add(
                    db,
                    job: job2,
                    initialDependencies: [
                        .job(otherJobId: 100)
                    ]
                )
            }
            
            // Make sure the dependency is run
            await expect {
                await jobRunner.jobsMatching(filters: .matchingAll)
            }.to(equal([
                JobQueue.JobQueueId(databaseId: 100): JobState(
                    queueId: JobQueue.JobQueueId(databaseId: 100),
                    job: job1,
                    jobDependencies: [],
                    executionState: .running(task: Task(operation: {})),
                    resultStream: CurrentValueAsyncStream(nil)
                ),
                JobQueue.JobQueueId(databaseId: 101): JobState(
                    queueId: JobQueue.JobQueueId(databaseId: 101),
                    job: job2,
                    jobDependencies: [],
                    executionState: .pending(lastAttempt: nil),
                    resultStream: CurrentValueAsyncStream(nil)
                )
            ]))
            
            // Step forward in time and check to make sure the other job starts
            await dependencies.stepForwardInTime()
            
            await expect {
                await jobRunner.jobsMatching(filters: .matchingAll)
            }.to(equal([
                JobQueue.JobQueueId(databaseId: 100): JobState(
                    queueId: JobQueue.JobQueueId(databaseId: 100),
                    job: job1,
                    jobDependencies: [],
                    executionState: .completed(result: .succeeded),
                    resultStream: CurrentValueAsyncStream(nil)
                ),
                JobQueue.JobQueueId(databaseId: 101): JobState(
                    queueId: JobQueue.JobQueueId(databaseId: 101),
                    job: job2,
                    jobDependencies: [],
                    executionState: .running(task: Task(operation: {})),
                    resultStream: CurrentValueAsyncStream(nil)
                )
            ]))
        }
        
        // MARK: ---- does not start a dependant job if the dependency fails
        it("does not start a dependant job if the dependency fails") {
            job1 = job1.with(details: TestDetails(result: .failure, completeTime: 1))
            
            try await mockStorage.writeAsync { db in
                jobRunner.add(db, job: job1)
                jobRunner.add(
                    db,
                    job: job2,
                    initialDependencies: [
                        .job(otherJobId: 100)
                    ]
                )
            }
            
            // Make sure the dependency is run
            await expect {
                await jobRunner.jobsMatching(filters: .matchingAll)
            }.to(equal([
                JobQueue.JobQueueId(databaseId: 100): JobState(
                    queueId: JobQueue.JobQueueId(databaseId: 100),
                    job: job1,
                    jobDependencies: [],
                    executionState: .running(task: Task(operation: {})),
                    resultStream: CurrentValueAsyncStream(nil)
                ),
                JobQueue.JobQueueId(databaseId: 101): JobState(
                    queueId: JobQueue.JobQueueId(databaseId: 101),
                    job: job2,
                    jobDependencies: [],
                    executionState: .pending(lastAttempt: nil),
                    resultStream: CurrentValueAsyncStream(nil)
                )
            ]))
            
            // Step forward in time and check to make sure the other job starts
            await dependencies.stepForwardInTime()
            
            await expect {
                await jobRunner.jobsMatching(filters: .matchingAll)
            }.to(equal([
                JobQueue.JobQueueId(databaseId: 100): JobState(
                    queueId: JobQueue.JobQueueId(databaseId: 100),
                    job: job1,
                    jobDependencies: [],
                    executionState: .completed(result: .failed(MockError.mock, isPermanent: false)),
                    resultStream: CurrentValueAsyncStream(nil)
                ),
                JobQueue.JobQueueId(databaseId: 101): JobState(
                    queueId: JobQueue.JobQueueId(databaseId: 101),
                    job: job2,
                    jobDependencies: [],
                    executionState: .pending(lastAttempt: nil),
                    resultStream: CurrentValueAsyncStream(nil)
                )
            ]))
        }
        
        // MARK: ---- does not delete the initial job if the dependencies fail
        it("does not delete the initial job if the dependencies fail") {
            job1 = job1.with(details: TestDetails(result: .failure, completeTime: 1))
            
            try await mockStorage.writeAsync { db in
                jobRunner.add(db, job: job1)
                jobRunner.add(
                    db,
                    job: job2,
                    initialDependencies: [
                        .job(otherJobId: 100)
                    ]
                )
            }
            
            // Ensure the job was started
            await expect {
                await jobRunner.jobsMatching(filters: .matchingAll)
            }.to(equal([
                JobQueue.JobQueueId(databaseId: 100): JobState(
                    queueId: JobQueue.JobQueueId(databaseId: 100),
                    job: job1,
                    jobDependencies: [],
                    executionState: .running(task: Task(operation: {})),
                    resultStream: CurrentValueAsyncStream(nil)
                )
            ]))
            
            await dependencies.stepForwardInTime()
            expect(mockStorage.read { db in try Job.fetchCount(db) }).to(equal(2))
        }
        
        // MARK: ---- deletes both jobs if the dependencies permanently fail
        it("deletes both jobs if the dependencies permanently fail") {
            job1 = job1.with(details: TestDetails(result: .permanentFailure, completeTime: 1))
            
            try await mockStorage.writeAsync { db in
                jobRunner.add(db, job: job1)
                jobRunner.add(
                    db,
                    job: job2,
                    initialDependencies: [
                        .job(otherJobId: 100)
                    ]
                )
            }
            
            // Ensure the job was started
            await expect {
                await jobRunner.jobsMatching(filters: .matchingAll)
            }.to(equal([
                JobQueue.JobQueueId(databaseId: 100): JobState(
                    queueId: JobQueue.JobQueueId(databaseId: 100),
                    job: job1,
                    jobDependencies: [],
                    executionState: .running(task: Task(operation: {})),
                    resultStream: CurrentValueAsyncStream(nil)
                )
            ]))
            
            await dependencies.stepForwardInTime()
            expect(mockStorage.read { db in try Job.fetchCount(db) }).to(equal(0))
        }
            
        // MARK: -- when completing jobs
        context("when completing jobs") {
            beforeEach {
                await jobRunner.appDidBecomeActive()
            }
            
            // MARK: ---- marks the job as completed
            it("marks the job as completed") {
                job1 = job1.with(details: TestDetails(result: .success, completeTime: 1))
                
                try await mockStorage.writeAsync { db in
                    jobRunner.add(db, job: job1)
                }
                
                // Ensure the job was started
                await expect {
                    await jobRunner.jobsMatching(filters: .matchingAll)
                }.to(equal([
                    JobQueue.JobQueueId(databaseId: 100): JobState(
                        queueId: JobQueue.JobQueueId(databaseId: 100),
                        job: job1,
                        jobDependencies: [],
                        executionState: .running(task: Task(operation: {})),
                        resultStream: CurrentValueAsyncStream(nil)
                    )
                ]))
                
                // Make sure there are no running jobs
                await dependencies.stepForwardInTime()
                await expect {
                    await jobRunner.jobsMatching(filters: .matchingAll)
                }.to(equal([
                    JobQueue.JobQueueId(databaseId: 100): JobState(
                        queueId: JobQueue.JobQueueId(databaseId: 100),
                        job: job1,
                        jobDependencies: [],
                        executionState: .completed(result: .succeeded),
                        resultStream: CurrentValueAsyncStream(nil)
                    )
                ]))
            }
            
            // MARK: ---- deletes the job
            it("deletes the job") {
                dependencies.set(feature: .completedJobCleanupDelay, to: 1)
                job1 = job1.with(details: TestDetails(result: .success, completeTime: 1))
                
                try await mockStorage.writeAsync { db in
                    jobRunner.add(db, job: job1)
                }
                
                // Ensure the job was started
                await expect {
                    await jobRunner.jobsMatching(filters: .matchingAll)
                }.to(equal([
                    JobQueue.JobQueueId(databaseId: 100): JobState(
                        queueId: JobQueue.JobQueueId(databaseId: 100),
                        job: job1,
                        jobDependencies: [],
                        executionState: .running(task: Task(operation: {})),
                        resultStream: CurrentValueAsyncStream(nil)
                    )
                ]))
                
                await dependencies.stepForwardInTime()
                
                // Make sure the jobs were deleted
                await expect {
                    try await mockStorage.readAsync { db in try Job.fetchCount(db) }
                }.toEventually(equal(0), timeout: .seconds(2))
            }
        }
        
        // MARK: -- when deferring jobs
        context("when deferring jobs") {
            beforeEach {
                await jobRunner.appDidBecomeActive()
            }
            
            // MARK: ---- reschedules the job to run again later
            it("reschedules the job to run again later") {
                job1 = job1.with(details: TestDetails(result: .deferred, completeTime: 1))
                
                try await mockStorage.writeAsync { db in
                    jobRunner.add(db, job: job1)
                }
                
                // Ensure the job was started
                await expect {
                    await jobRunner.jobsMatching(filters: .matchingAll)
                }.to(equal([
                    JobQueue.JobQueueId(databaseId: 100): JobState(
                        queueId: JobQueue.JobQueueId(databaseId: 100),
                        job: job1,
                        jobDependencies: [],
                        executionState: .running(task: Task(operation: {})),
                        resultStream: CurrentValueAsyncStream(nil)
                    )
                ]))
                
                // Make sure there are no running jobs
                await dependencies.stepForwardInTime()
                await expect {
                    await jobRunner.jobsMatching(filters: .matchingAll)
                }.to(equal([
                    JobQueue.JobQueueId(databaseId: 100): JobState(
                        queueId: JobQueue.JobQueueId(databaseId: 100),
                        job: job1,
                        jobDependencies: [],
                        executionState: .pending(lastAttempt: .deferred),
                        resultStream: CurrentValueAsyncStream(nil)
                    )
                ]))
                
                await expect {
                    try await mockStorage.readAsync { db in try Job.select(.details).asRequest(of: Data.self).fetchOne(db) }
                }.to(equal(
                    try! JSONEncoder(using: dependencies)
                        .encode(TestDetails(result: .deferred, completeTime: 3))
                ))
            }
            
            // MARK: -------- does not delete the job
            it("does not delete the job") {
                job1 = job1.with(details: TestDetails(result: .deferred, completeTime: 1))
                
                try await mockStorage.writeAsync { db in
                    jobRunner.add(db, job: job1)
                }
                
                // Ensure the job was started
                await expect {
                    await jobRunner.jobsMatching(filters: .matchingAll)
                }.to(equal([
                    JobQueue.JobQueueId(databaseId: 100): JobState(
                        queueId: JobQueue.JobQueueId(databaseId: 100),
                        job: job1,
                        jobDependencies: [],
                        executionState: .running(task: Task(operation: {})),
                        resultStream: CurrentValueAsyncStream(nil)
                    )
                ]))
                
                await dependencies.stepForwardInTime()
                await expect {
                    try await mockStorage.readAsync { db in try Job.fetchCount(db) }
                }.toNot(equal(0))
            }
            
            // MARK: -------- fails the job if it is deferred too many times
            it("fails the job if it is deferred too many times") {
                job1 = job1.with(details: TestDetails(result: .deferred, completeTime: 1))
                
                try await mockStorage.writeAsync { db in
                    jobRunner.add(db, job: job1)
                }
                
                // Ensure the job was started
                await expect {
                    await jobRunner.jobsMatching(filters: .matchingAll)
                }.to(equal([
                    JobQueue.JobQueueId(databaseId: 100): JobState(
                        queueId: JobQueue.JobQueueId(databaseId: 100),
                        job: job1,
                        jobDependencies: [],
                        executionState: .running(task: Task(operation: {})),
                        resultStream: CurrentValueAsyncStream(nil)
                    )
                ]))
                
                await dependencies.stepForwardInTime()
                await dependencies.stepForwardInTime()
                await dependencies.stepForwardInTime()
                
                await expect {
                    await jobRunner.jobsMatching(filters: .matchingAll)
                }.to(equal([
                    JobQueue.JobQueueId(databaseId: 100): JobState(
                        queueId: JobQueue.JobQueueId(databaseId: 100),
                        job: job1,
                        jobDependencies: [],
                        executionState: .pending(lastAttempt: .deferred),
                        resultStream: CurrentValueAsyncStream(nil)
                    )
                ]))
                
                // Make sure the job was marked as failed
                await expect {
                    try await mockStorage.readAsync { db in try Job.fetchOne(db, id: 100)?.failureCount }
                }.to(equal(1))
            }
        }
        
        // MARK: -- when failing jobs
        context("when failing jobs") {
            beforeEach {
                await jobRunner.appDidBecomeActive()
            }
            
            // MARK: ---- marks the job as failed
            it("marks the job as failed") {
                job1 = job1.with(details: TestDetails(result: .failure, completeTime: 1))
                
                try await mockStorage.writeAsync { db in
                    jobRunner.add(db, job: job1)
                }
                
                // Ensure the job was started
                await expect {
                    await jobRunner.jobsMatching(filters: .matchingAll)
                }.to(equal([
                    JobQueue.JobQueueId(databaseId: 100): JobState(
                        queueId: JobQueue.JobQueueId(databaseId: 100),
                        job: job1,
                        jobDependencies: [],
                        executionState: .running(task: Task(operation: {})),
                        resultStream: CurrentValueAsyncStream(nil)
                    )
                ]))
                
                // Make sure there are no running jobs
                await dependencies.stepForwardInTime()
                await expect {
                    await jobRunner.jobsMatching(filters: .matchingAll)
                }.to(equal([
                    JobQueue.JobQueueId(databaseId: 100): JobState(
                        queueId: JobQueue.JobQueueId(databaseId: 100),
                        job: job1,
                        jobDependencies: [],
                        executionState: .pending(lastAttempt: .failed(MockError.mock, isPermanent: false)),
                        resultStream: CurrentValueAsyncStream(nil)
                    )
                ]))
            }
            
            // MARK: ---- does not delete the job
            it("does not delete the job") {
                job1 = job1.with(details: TestDetails(result: .failure, completeTime: 1))
                
                try await mockStorage.writeAsync { db in
                    jobRunner.add(db, job: job1)
                }
                
                // Ensure the job was started
                await expect {
                    await jobRunner.jobsMatching(filters: .matchingAll)
                }.to(equal([
                    JobQueue.JobQueueId(databaseId: 100): JobState(
                        queueId: JobQueue.JobQueueId(databaseId: 100),
                        job: job1,
                        jobDependencies: [],
                        executionState: .running(task: Task(operation: {})),
                        resultStream: CurrentValueAsyncStream(nil)
                    )
                ]))
                
                await dependencies.stepForwardInTime()
                await expect {
                    try await mockStorage.readAsync { db in try Job.fetchCount(db) }
                }.toNot(equal(0))
            }
        }
        
        // MARK: -- when permanently failing jobs
        context("when permanently failing jobs") {
            beforeEach {
                await jobRunner.appDidBecomeActive()
            }
            
            // MARK: ---- marks the job as failed
            it("marks the job as failed") {
                job1 = job1.with(details: TestDetails(result: .permanentFailure, completeTime: 1))
                
                try await mockStorage.writeAsync { db in
                    jobRunner.add(db, job: job1)
                }
                
                // Ensure the job was started
                await expect {
                    await jobRunner.jobsMatching(filters: .matchingAll)
                }.to(equal([
                    JobQueue.JobQueueId(databaseId: 100): JobState(
                        queueId: JobQueue.JobQueueId(databaseId: 100),
                        job: job1,
                        jobDependencies: [],
                        executionState: .running(task: Task(operation: {})),
                        resultStream: CurrentValueAsyncStream(nil)
                    )
                ]))
                
                // Make sure there are no running jobs
                await dependencies.stepForwardInTime()
                await expect {
                    await jobRunner.jobsMatching(filters: .matchingAll)
                }.to(equal([
                    JobQueue.JobQueueId(databaseId: 100): JobState(
                        queueId: JobQueue.JobQueueId(databaseId: 100),
                        job: job1,
                        jobDependencies: [],
                        executionState: .pending(lastAttempt: .failed(MockError.mock, isPermanent: true)),
                        resultStream: CurrentValueAsyncStream(nil)
                    )
                ]))
            }
            
            // MARK: ---- deletes the job from the database
            it("deletes the job from the database") {
                job1 = job1.with(details: TestDetails(result: .permanentFailure, completeTime: 1))
                
                try await mockStorage.writeAsync { db in
                    jobRunner.add(db, job: job1)
                }
                
                // Ensure the job was started
                await expect {
                    await jobRunner.jobsMatching(filters: .matchingAll)
                }.to(equal([
                    JobQueue.JobQueueId(databaseId: 100): JobState(
                        queueId: JobQueue.JobQueueId(databaseId: 100),
                        job: job1,
                        jobDependencies: [],
                        executionState: .running(task: Task(operation: {})),
                        resultStream: CurrentValueAsyncStream(nil)
                    )
                ]))
                
                await dependencies.stepForwardInTime()
                await expect {
                    try await mockStorage.readAsync { db in try Job.fetchCount(db) }
                }.to(equal(0))
            }
        }
    }
}

// MARK: - Test Types

fileprivate struct TestDetails: Codable {
    enum ResultType: Codable {
        case success
        case failure
        case permanentFailure
        case deferred
    }
    
    public let result: ResultType
    public let completeTime: Int
    public let allowConcurrentJobs: Bool
    public let intValue: Int64
    public let stringValue: String
    
    init(
        result: ResultType = .success,
        completeTime: Int = 0,
        allowConcurrentJobs: Bool = true,
        intValue: Int64 = 100,
        stringValue: String = "200",
    ) {
        self.result = result
        self.completeTime = completeTime
        self.allowConcurrentJobs = allowConcurrentJobs
        self.intValue = intValue
        self.stringValue = stringValue
    }
}

fileprivate struct InvalidDetails: Codable {
    func encode(to encoder: Encoder) throws { throw MockError.mock }
}

fileprivate enum TestJob: JobExecutor {
    static let maxFailureCount: Int = 1
    static let requiresThreadId: Bool = false
    static let requiresInteractionId: Bool = false
    
    static func canRunConcurrentlyWith(
        runningJobs: [JobState],
        jobState: JobState,
        using dependencies: Dependencies
    ) -> Bool {
        guard
            let detailsData: Data = jobState.job.details,
            let details: TestDetails = try? JSONDecoder(using: dependencies).decode(TestDetails.self, from: detailsData)
        else { return true }
        
        return (details.allowConcurrentJobs || runningJobs.isEmpty)
    }
    
    static func run(_ job: Job, using dependencies: Dependencies) async throws -> JobExecutionResult {
        guard
            let detailsData: Data = job.details,
            let details: TestDetails = try? JSONDecoder(using: dependencies).decode(TestDetails.self, from: detailsData)
        else { return .success }
        
        let completeJob: () async throws -> JobExecutionResult = {
            // Need to increase the 'completeTime' and 'nextRunTimestamp' to prevent the job
            // from immediately being run again or immediately completing afterwards
            let updatedJob: Job = job.with(
                details: TestDetails(
                    result: details.result,
                    completeTime: (details.completeTime + 2),
                    intValue: details.intValue,
                    stringValue: details.stringValue
                )
            )!
            try await dependencies[singleton: .storage].writeAsync { db in
                try updatedJob.upserted(db)
            }
            
            switch details.result {
                case .success: return .success
                case .failure: throw MockError.mock
                case .permanentFailure: throw JobRunnerError.permanentFailure(MockError.mock)
                case .deferred:
                    return .deferred(nextRunTimestamp: TimeInterval(details.completeTime + 1))
            }
        }
        
        guard dependencies.fixedTime < details.completeTime else {
            return try await completeJob()
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            dependencies.async(at: details.completeTime) {
                do { continuation.resume(returning: try await completeJob()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}

// MARK: - Unit Test Convenience

fileprivate extension JobRunner {
    init(
        isTestingJobRunner: Bool = false,
        executors: [Job.Variant: JobExecutor.Type],
        using dependencies: Dependencies
    ) async {
        self.init(
            isTestingJobRunner: isTestingJobRunner,
            using: dependencies
        )
        
        for (variant, executor) in executors {
            await self.setExecutor(executor, for: variant)
        }
    }
}
