// Copyright © 2026 Session Technology Foundation. All rights reserved.

import Foundation

import Quick
import Nimble

@testable import Session

class ForegroundSceneGateSpec: AsyncSpec {
    override class func spec() {
        // MARK: - a ForegroundSceneGate
        describe("a ForegroundSceneGate") {
            // MARK: -- when a scene is in the foreground
            context("when a scene is in the foreground") {
                // MARK: ---- lets the caller carry on without holding the work
                it("lets the caller carry on without holding the work") {
                    let result: (isOpen: Bool, runCount: Int) = await MainActor.run {
                        var runCount: Int = 0
                        let gate: ForegroundSceneGate = ForegroundSceneGate { true }
                        let isOpen: Bool = gate.isOpen(elseDefer: { runCount += 1 })
                        gate.sceneWillEnterForeground()

                        return (isOpen, runCount)
                    }

                    expect(result.isOpen).to(beTrue())
                    expect(result.runCount).to(equal(0))
                }
            }

            // MARK: -- when there is no scene in the foreground
            context("when there is no scene in the foreground") {
                // MARK: ---- holds the work until a scene enters the foreground
                it("holds the work until a scene enters the foreground") {
                    let result: (isOpen: Bool, runCountBefore: Int, runCountAfter: Int) = await MainActor.run {
                        var runCount: Int = 0
                        let gate: ForegroundSceneGate = ForegroundSceneGate { false }
                        let isOpen: Bool = gate.isOpen(elseDefer: { runCount += 1 })
                        let runCountBefore: Int = runCount
                        gate.sceneWillEnterForeground()

                        return (isOpen, runCountBefore, runCount)
                    }

                    expect(result.isOpen).to(beFalse())
                    expect(result.runCountBefore).to(equal(0))
                    expect(result.runCountAfter).to(equal(1))
                }

                // MARK: ---- runs the held work only once
                it("runs the held work only once") {
                    let runCount: Int = await MainActor.run {
                        var runCount: Int = 0
                        let gate: ForegroundSceneGate = ForegroundSceneGate { false }
                        _ = gate.isOpen(elseDefer: { runCount += 1 })
                        gate.sceneWillEnterForeground()
                        gate.sceneWillEnterForeground()

                        return runCount
                    }

                    expect(runCount).to(equal(1))
                }
            }
        }
    }
}
