// Copyright © 2026 Session Technology Foundation. All rights reserved.

import Foundation
import SessionUIKit
import SessionUtilitiesKit
import TestUtilities

import Quick
import Nimble

@testable import SessionNetworkingKit
@testable import SessionMessagingKit

class SessionProGateSpec: AsyncSpec {
    override class func spec() {
        // MARK: Configuration

        @TestState var dependencies: TestDependencies! = TestDependencies { dependencies in
            dependencies.dateNow = Date(timeIntervalSince1970: 1234567890)
            dependencies.forceSynchronous = true
        }
        @TestState var mockStorage: Storage! = try! Storage.createForTesting(using: dependencies)
        @TestState var mockGeneralCache: MockGeneralCache! = .create(using: dependencies)
        @TestState var mockLibSessionCache: MockLibSessionCache! = .create(using: dependencies)
        @TestState var mockNetwork: MockNetwork! = .create(using: dependencies)
        @TestState var mockAppContext: MockAppContext! = .create(using: dependencies)
        @TestState var manager: SessionProManager!

        beforeEach {
            dependencies.set(cache: .general, to: mockGeneralCache)
            try await mockGeneralCache.defaultInitialSetup()

            dependencies.set(cache: .libSession, to: mockLibSessionCache)
            try await mockLibSessionCache.defaultInitialSetup()

            dependencies.set(singleton: .storage, to: mockStorage)
            try await mockStorage.perform(migrations: SNMessagingKit.migrations)

            /// Not the main app by default, so the manager's main app only background work (which needs a lot more stubbing) stays off
            dependencies.set(singleton: .appContext, to: mockAppContext)
            try await mockAppContext.when { $0.isMainApp }.thenReturn(false)

            dependencies.set(singleton: .network, to: mockNetwork)
            try await mockNetwork.when { await $0.networkTimeOffsetMs }.thenReturn(0)
            try await mockNetwork
                .when { $0.networkStatus }
                .thenReturn(.singleValue(value: .connected))

            /// Grants our own Pro on its own when the gate lets it through, so a leak shows up without a real proof
            dependencies[feature: .mockCurrentUserSessionProProof] = .simulate(.valid)
        }
        
        func profile(id: String) -> Profile {
            return Profile(
                id: id,
                name: "TestProfileName",
                nickname: nil,
                displayPictureUrl: nil,
                displayPictureEncryptionKey: nil,
                profileLastUpdated: nil,
                blocksCommunityMessageRequests: nil,
                proFeatures: .proBadge,
                proExpiryUnixTimestampSeconds: 2_000_000_000,
                proRevocationTagHex: "aa"
            )
        }
        let ourProfile: Profile = profile(id: "05\(TestConstants.publicKey)")
        let otherProfile: Profile = profile(id: "05\(String(repeating: "1", count: 64))")

        /// The flag is set before the manager exists because flipping it afterwards is observed, and the observer goes to
        /// the network when Pro turns on
        func createManager(sessionProEnabled: Bool) {
            dependencies[feature: .sessionProEnabled] = sessionProEnabled
            manager = SessionProManager(using: dependencies)
        }

        // MARK: - the Session Pro gate
        describe("the Session Pro gate") {
            // MARK: -- when Session Pro is disabled
            context("when Session Pro is disabled") {
                beforeEach {
                    createManager(sessionProEnabled: false)
                }

                // MARK: ---- grants no Pro access
                it("grants no Pro access") {
                    expect(manager.currentUserHasProAccess).to(beFalse())
                }

                // MARK: ---- uses the standard character limit
                it("uses the standard character limit") {
                    expect(manager.characterLimit).to(equal(SessionPro.CharacterLimit))
                }

                // MARK: ---- reports no Pro features for us
                it("reports no Pro features for us") {
                    expect(manager.profileFeatures(for: ourProfile)).to(equal(SessionPro.ProfileFeatures.none))
                }
                
                // MARK: ---- still reports another user's Pro features
                it("still reports another user's Pro features") {
                    expect(manager.profileFeatures(for: otherProfile)).to(equal(.proBadge))
                    expect(manager.profileProFeatureList(.proBadge)).to(equal(.proBadge))
                    expect(manager.messageProFeatureList(.largerCharacterLimit)).to(equal(.largerCharacterLimit))
                }

                // MARK: ---- lets any profile animate
                it("lets any profile animate") {
                    expect(ProfilePictureView.canProfileAnimate(nil, using: dependencies)).to(beTrue())
                }

                // MARK: ---- declines to show a CTA
                it("declines to show a CTA") {
                    let outcome: ProCTAOutcome = await manager.showSessionProCTAIfNeeded(.longerMessages(renew: false))

                    expect(outcome).to(equal(.suppressedProDisabled))
                }

                // MARK: ---- has no expiring CTA to show
                it("has no expiring CTA to show") {
                    /// Awaits initialisation internally, so this also fails (by timing out) if the disabled path stops
                    /// signalling that initialisation finished
                    await expect { await manager.sessionProExpiringCTAInfo() == nil }
                        .toEventually(beTrue(), timeout: .seconds(5))
                }
            }

            // MARK: -- when Session Pro is enabled
            context("when Session Pro is enabled") {
                beforeEach {
                    createManager(sessionProEnabled: true)
                }

                // MARK: ---- grants Pro access
                it("grants Pro access") {
                    expect(manager.currentUserHasProAccess).to(beTrue())
                }

                // MARK: ---- uses the Pro character limit
                it("uses the Pro character limit") {
                    expect(manager.characterLimit).to(equal(SessionPro.ProCharacterLimit))
                }

                // MARK: ---- reports our Pro features
                it("reports our Pro features") {
                    expect(manager.profileFeatures(for: ourProfile)).to(equal(.proBadge))
                }
                
                // MARK: ---- reports another user's Pro features
                it("reports another user's Pro features") {
                    expect(manager.profileFeatures(for: otherProfile)).to(equal(.proBadge))
                }

                // MARK: ---- does not let a missing profile animate
                it("does not let a missing profile animate") {
                    expect(ProfilePictureView.canProfileAnimate(nil, using: dependencies)).to(beFalse())
                }
            }
        }
        
        // MARK: - a SessionProManager
        describe("a SessionProManager") {
            /// Initialisation finishing is the last thing the background work does before returning, so waiting on it (via
            /// `sessionProExpiringCTAInfo`) means anything the manager was going to touch on startup has been touched
            ///
            /// **Note:** The wait is bounded because the main app path doesn't finish initialising with Pro enabled in this setup, so
            /// a regression which sent an extension down it would otherwise hang the test run rather than fail
            func createManagerAndWaitForInitialisation(sessionProEnabled: Bool) async {
                createManager(sessionProEnabled: sessionProEnabled)
                
                let initialisation: InitialisationFlag = InitialisationFlag()
                Task { [manager] in
                    _ = await manager?.sessionProExpiringCTAInfo()
                    initialisation.markFinished()
                }
                await expect(initialisation.hasFinished).toEventually(beTrue(), timeout: .seconds(5))
            }
            
            // MARK: -- in the main app
            context("in the main app") {
                beforeEach {
                    try await mockAppContext.when { $0.isMainApp }.thenReturn(true)
                }
                
                // MARK: ---- uses the network on startup
                it("uses the network on startup") {
                    await createManagerAndWaitForInitialisation(sessionProEnabled: false)
                    
                    await mockNetwork
                        .verify { $0.networkStatus }
                        .wasCalled(timeout: .seconds(1))
                }
            }
            
            // MARK: -- in an extension
            context("in an extension") {
                beforeEach {
                    dependencies[singleton: .storage] = nil as Storage?
                }
                
                // MARK: ---- does not use the network on startup
                it("does not use the network on startup") {
                    await createManagerAndWaitForInitialisation(sessionProEnabled: false)
                    
                    await mockNetwork
                        .verify { $0.networkStatus }
                        .wasNotCalled(timeout: .milliseconds(200))
                }
                
                // MARK: ---- does not use the network on startup when Session Pro is enabled
                it("does not use the network on startup when Session Pro is enabled") {
                    await createManagerAndWaitForInitialisation(sessionProEnabled: true)
                    
                    await mockNetwork
                        .verify { $0.networkStatus }
                        .wasNotCalled(timeout: .milliseconds(200))
                }
                
                // MARK: ---- does not open the database on startup
                it("does not open the database on startup") {
                    await createManagerAndWaitForInitialisation(sessionProEnabled: true)
                    try await Task.sleep(for: .milliseconds(200))
                    
                    let storage: Storage? = dependencies[singleton: .storage]
                    expect(storage).to(beNil())
                }
            }
        }
    }
}

// MARK: - InitialisationFlag

private final class InitialisationFlag: @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var _hasFinished: Bool = false
    
    var hasFinished: Bool { lock.withLock { _hasFinished } }
    
    func markFinished() { lock.withLock { _hasFinished = true } }
}
