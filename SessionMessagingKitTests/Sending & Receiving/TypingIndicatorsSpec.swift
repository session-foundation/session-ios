// Copyright © 2026 Session Technology Foundation. All rights reserved.

import Foundation
import Quick
import Nimble
import SessionUtilitiesKit
import TestUtilities

@testable import SessionMessagingKit

class TypingIndicatorsSpec: AsyncSpec {
    override class func spec() {
        @TestState var dependencies: TestDependencies! = TestDependencies { dependencies in
            dependencies.dateNow = Date(timeIntervalSince1970: 1234567890)
        }

        // MARK: - a TypingIndicators Indicator
        describe("a TypingIndicators Indicator") {
            // MARK: -- survives concurrent timeout refreshes
            it("survives concurrent timeout refreshes") {
                /// Each keystroke and each incoming typing message refreshes the timeout, and those calls can overlap
                let indicator: TypingIndicators.Indicator = TypingIndicators.Indicator(
                    threadId: "05\(String(repeating: "1", count: 64))",
                    threadVariant: .contact,
                    direction: .incoming,
                    timestampMs: 1234567890000
                )

                await withTaskGroup(of: Void.self) { group in
                    for _ in 0..<5000 {
                        group.addTask {
                            await indicator.refreshTimeout(sentTimestampMs: 1234567890000, using: dependencies)
                        }
                    }
                }

                let threadVariant: SessionThread.Variant = await indicator.threadVariant
                expect(threadVariant).to(equal(.contact))
            }
        }
    }
}
