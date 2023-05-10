// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation

import Quick
import Nimble

@testable import SessionUtilitiesKit

class ArrayUtilitiesSpec: QuickSpec {
    private struct TestType: Equatable {
        let stringValue: String
        let intValue: Int
    }
    
    // MARK: - Spec

    override func spec() {
        describe("an Array") {
            context("when grouping") {
                it("maintains the original array ordering") {
                    let data: [TestType] = [
                        TestType(stringValue: "b", intValue: 5),
                        TestType(stringValue: "A", intValue: 2),
                        TestType(stringValue: "z", intValue: 1),
                        TestType(stringValue: "x", intValue: 3),
                        TestType(stringValue: "7", intValue: 6),
                        TestType(stringValue: "A", intValue: 7),
                        TestType(stringValue: "z", intValue: 8),
                        TestType(stringValue: "7", intValue: 9),
                        TestType(stringValue: "7", intValue: 4),
                        TestType(stringValue: "h", intValue: 2),
                        TestType(stringValue: "z", intValue: 1),
                        TestType(stringValue: "m", intValue: 2)
                    ]
                    
                    let result1: [String: [TestType]] = data.grouped(by: \.stringValue)
                    let result2: [Int: [TestType]] = data.grouped(by: \.intValue)
                    
                    expect(result1).to(equal(
                        [
                            "b": [TestType(stringValue: "b", intValue: 5)],
                            "A": [
                                TestType(stringValue: "A", intValue: 2),
                                TestType(stringValue: "A", intValue: 7)
                            ],
                            "z": [
                                TestType(stringValue: "z", intValue: 1),
                                TestType(stringValue: "z", intValue: 8),
                                TestType(stringValue: "z", intValue: 1)
                            ],
                            "x": [TestType(stringValue: "x", intValue: 3)],
                            "7": [
                                TestType(stringValue: "7", intValue: 6),
                                TestType(stringValue: "7", intValue: 9),
                                TestType(stringValue: "7", intValue: 4)
                            ],
                            "h": [TestType(stringValue: "h", intValue: 2)],
                            "m": [TestType(stringValue: "m", intValue: 2)]
                        ]
                    ))
                    expect(result2).to(equal(
                        [
                            1: [
                                TestType(stringValue: "z", intValue: 1),
                                TestType(stringValue: "z", intValue: 1),
                            ],
                            2: [
                                TestType(stringValue: "A", intValue: 2),
                                TestType(stringValue: "h", intValue: 2),
                                TestType(stringValue: "m", intValue: 2)
                            ],
                            3: [TestType(stringValue: "x", intValue: 3)],
                            4: [TestType(stringValue: "7", intValue: 4)],
                            5: [TestType(stringValue: "b", intValue: 5)],
                            6: [TestType(stringValue: "7", intValue: 6)],
                            7: [TestType(stringValue: "A", intValue: 7)],
                            9: [TestType(stringValue: "7", intValue: 9)],
                            8: [TestType(stringValue: "z", intValue: 8)]
                        ]
                    ))
                }
            }
        }
    }
}
