// Copyright © 2026 Session Technology Foundation. All rights reserved.

import UIKit
import Quick
import Nimble
import SessionUtilitiesKit
import TestUtilities

@testable import Session

class DisappearingMessageTimerViewSpec: AsyncSpec {
    override class func spec() {
        // MARK: Configuration
        
        @TestState var nowMs: Double! = 1234567890000
        @TestState var dependencies: TestDependencies! = TestDependencies { dependencies in
            dependencies.dateNow = Date(timeIntervalSince1970: 1234567890)
        }
        
        @MainActor func makeView(secondsLeft: Double, duration: Double) -> DisappearingMessageTimerView {
            let view: DisappearingMessageTimerView = DisappearingMessageTimerView()
            view.configure(
                expirationTimestampMs: nowMs + (secondsLeft * 1000),
                initialDurationSeconds: duration,
                using: dependencies
            )
            
            return view
        }
        
        /// The icon view is private but it's the only subview
        @MainActor func icon(of view: DisappearingMessageTimerView) -> UIImage? {
            return (view.subviews.first as? UIImageView)?.image
        }
        
        /// Setting the same image again can leave the same instance in place, so count the sets instead of comparing images
        @MainActor func observeIconSets(of view: DisappearingMessageTimerView, count: ThreadSafe<Int>) -> NSKeyValueObservation? {
            return (view.subviews.first as? UIImageView)?.observe(\.image) { _, _ in
                count.performUpdateAndMap { ($0 + 1, ()) }
            }
        }
        
        /// Long enough for the view's 0.1s timer to fire several times
        func waitForTicks() async {
            try? await Task.sleep(for: .milliseconds(350))
        }
        
        // MARK: - a DisappearingMessageTimerView
        describe("a DisappearingMessageTimerView") {
            // MARK: -- does not redraw the icon while its state is unchanged
            it("does not redraw the icon while its state is unchanged") {
                let view: DisappearingMessageTimerView = await makeView(secondsLeft: 60, duration: 60)
                let iconSets: ThreadSafe<Int> = ThreadSafe(0)
                let observation: NSKeyValueObservation? = await observeIconSets(of: view, count: iconSets)
                await waitForTicks()
                observation?.invalidate()
                let finalIcon: UIImage? = await icon(of: view)
                
                expect(observation).toNot(beNil())
                expect(finalIcon).toNot(beNil())
                expect(iconSets.wrappedValue).to(equal(0))
            }
            
            // MARK: -- redraws the icon when its state changes
            it("redraws the icon when its state changes") {
                let view: DisappearingMessageTimerView = await makeView(secondsLeft: 60, duration: 60)
                let initialIcon: UIImage? = await icon(of: view)
                dependencies.dateNow = Date(timeIntervalSince1970: 1234567890 + 30)
                await waitForTicks()
                let finalIcon: UIImage? = await icon(of: view)
                
                expect(finalIcon).toNot(beNil())
                expect(finalIcon).toNot(beIdenticalTo(initialIcon))
            }
            
            // MARK: -- stops updating once expired
            it("stops updating once expired") {
                let view: DisappearingMessageTimerView = await makeView(secondsLeft: -1, duration: 60)
                let expiredIcon: UIImage? = await icon(of: view)
                
                /// Moving the clock back would change the icon if the timer were still running
                dependencies.dateNow = Date(timeIntervalSince1970: 1234567890 - 60)
                await waitForTicks()
                let finalIcon: UIImage? = await icon(of: view)
                
                expect(expiredIcon).toNot(beNil())
                expect(finalIcon).to(beIdenticalTo(expiredIcon))
            }
        }
    }
}
