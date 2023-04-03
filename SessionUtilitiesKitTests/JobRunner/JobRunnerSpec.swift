// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB

import Quick
import Nimble

@testable import SessionUtilitiesKit

class JobRunnerSpec: QuickSpec {
    public enum TestSuccessfulJob: JobExecutor {
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
            success(job, true, dependencies)
        }
    }
    
    // MARK: - Spec

    override func spec() {
        var jobRunner: JobRunner!
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
                
                jobRunner = JobRunner()
            }
            
            afterEach {
                jobRunner = nil
                mockStorage = nil
                dependencies = nil
            }
            
            context("when configuring") {
                it("adds an executor correctly") {
                    // TODO: Test this
                    jobRunner.add(executor: TestSuccessfulJob.self, for: .messageSend)
                }
            }
        }
    }
}
