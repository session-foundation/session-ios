// Copyright © 2026 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUIKit
import SessionUtilitiesKit

import Quick
import Nimble

@testable import SessionMessagingKit

class ProStatsReaderSpec: AsyncSpec {
    override class func spec() {
        // MARK: Configuration
        
        @TestState var dependencies: TestDependencies! = TestDependencies()
        @TestState var mockStorage: Storage! = try! Storage.createForTesting(using: dependencies)
        @TestState var mockGeneralCache: MockGeneralCache! = .create(using: dependencies)
        
        beforeEach {
            dependencies.set(cache: .general, to: mockGeneralCache)
            try await mockGeneralCache.defaultInitialSetup()
            
            dependencies.set(singleton: .storage, to: mockStorage)
            try await mockStorage.perform(migrations: SNMessagingKit.migrations)
        }
        
        // MARK: - the pro settings screen
        describe("the pro settings screen") {
            @TestState var previousState: SessionProSettingsViewModel.State! = SessionProSettingsViewModel.State(
                isInBottomSheet: false,
                profile: Profile.defaultFor("05\(TestConstants.publicKey)"),
                proState: .invalid,
                numberOfGroupsUpgraded: 0,
                numberOfPinnedConversations: 0,
                numberOfProBadgesSent: 0,
                numberOfLongerMessagesSent: 0
            )
            
            // MARK: -- when a counter changes while it is open
            context("when a counter changes while it is open") {
                // MARK: ---- takes the new value
                it("takes the new value") {
                    /// This is the regression the screen actually had: the counters were right on entry and then frozen,
                    /// because the events are bucketed by the generic half of their key and the screen was reading a
                    /// different bucket from the one the writes go into. Nothing about the emission side catches that -
                    /// it has to be the read
                    let updatedState: SessionProSettingsViewModel.State = await SessionProSettingsViewModel.queryState(
                        previousState: previousState,
                        events: [
                            ObservedEvent(key: .keyValue(.proBadgesSentCounter), value: 7),
                            ObservedEvent(key: .keyValue(.longerMessagesSentCounter), value: 4)
                        ],
                        isInitialQuery: false,
                        using: dependencies
                    )
                    
                    expect(updatedState.numberOfProBadgesSent).to(equal(7))
                    expect(updatedState.numberOfLongerMessagesSent).to(equal(4))
                }
                
                // MARK: ---- leaves a counter alone when only the other one changed
                it("leaves a counter alone when only the other one changed") {
                    /// The positive half is deliberately in the same call as the absence: without it, a changeset which
                    /// never reached the counter handling at all would satisfy the absence and the test would pass for
                    /// the wrong reason
                    let updatedState: SessionProSettingsViewModel.State = await SessionProSettingsViewModel.queryState(
                        previousState: previousState,
                        events: [ObservedEvent(key: .keyValue(.proBadgesSentCounter), value: 3)],
                        isInitialQuery: false,
                        using: dependencies
                    )
                    
                    expect(updatedState.numberOfProBadgesSent).to(equal(3))
                    expect(updatedState.numberOfLongerMessagesSent).to(equal(0))
                }
            }
        }
        
        // MARK: - the stat number format
        describe("the stat number format") {
            /// A cross-client contract rather than cosmetics - the same counter has to read the same way on all three
            /// platforms, so these are pinned either side of the abbreviation threshold
            
            // MARK: -- below the threshold
            context("below the threshold") {
                // MARK: ---- renders exactly
                it("renders exactly") {
                    expect(0.formatted(format: .abbreviated(decimalPlaces: 1))).to(equal("0"))
                    expect(1.formatted(format: .abbreviated(decimalPlaces: 1))).to(equal("1"))
                    expect(42.formatted(format: .abbreviated(decimalPlaces: 1))).to(equal("42"))
                    expect(999.formatted(format: .abbreviated(decimalPlaces: 1))).to(equal("999"))
                }
            }
            
            // MARK: -- at or above the threshold
            context("at or above the threshold") {
                // MARK: ---- abbreviates to one decimal, dropping a zero decimal
                it("abbreviates to one decimal, dropping a zero decimal") {
                    expect(1000.formatted(format: .abbreviated(decimalPlaces: 1))).to(equal("1K"))
                    expect(1300.formatted(format: .abbreviated(decimalPlaces: 1))).to(equal("1.3K"))
                    expect(1_000_000.formatted(format: .abbreviated(decimalPlaces: 1))).to(equal("1M"))
                }
            }
        }
    }
}
