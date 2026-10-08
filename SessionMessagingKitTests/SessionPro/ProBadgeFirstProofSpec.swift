// Copyright © 2026 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit
import TestUtilities

import Quick
import Nimble

@testable import SessionNetworkingKit
@testable import SessionMessagingKit

/// Covers the condition that turns the pro badge on when a proof lands.
///
/// The badge is off by default and the settings toggle is the user's own choice, so the question asked is
/// whether the account has EVER held Pro rather than whether it holds Pro now. The second question is the one
/// that ships easily and is miserable to diagnose: a subscriber who turns the badge off has it turned back on
/// at every renewal, with no way to make it stick. The cases below which expect `false` carry that regression.
class ProBadgeFirstProofSpec: AsyncSpec {
    override class func spec() {
        // MARK: Configuration
        
        @TestState var dependencies: TestDependencies! = TestDependencies()
        @TestState var mockLibSessionCache: MockLibSessionCache! = .create(using: dependencies)
        
        beforeEach {
            dependencies.set(cache: .libSession, to: mockLibSessionCache)
            try await mockLibSessionCache.defaultInitialSetup()
        }
        
        // MARK: - the first-ever proof check
        describe("the first-ever proof check") {
            // MARK: -- says yes for an account which has never been Pro
            it("says yes for an account which has never been Pro") {
                await expect(SessionProManager.hasNeverHeldPro(mockLibSessionCache)).to(beTrue())
            }
            
            // MARK: -- says no when a proof is already stored
            it("says no when a proof is already stored") {
                try await mockLibSessionCache
                    .when { $0.proConfig }
                    .thenReturn(
                        SessionPro.ProConfig(
                            rotatingPrivateKey: Array(Data(hex: TestConstants.edSecretKey)),
                            proProof: Network.SessionPro.ProProof(expiryUnixTimestampSeconds: 2000)
                        )
                    )
                
                await expect(SessionProManager.hasNeverHeldPro(mockLibSessionCache)).to(beFalse())
            }
            
            // MARK: -- says no when only the access expiry survives
            it("says no when only the access expiry survives") {
                /// A lapsed plan has its proof cleared, so the access expiry is the only evidence left that this
                /// account has been Pro before - and the only thing between the user's choice and a fresh proof
                /// reinstating the badge
                try await mockLibSessionCache.when { $0.proAccessExpiryTimestampSeconds }.thenReturn(1500)
                
                await expect(SessionProManager.hasNeverHeldPro(mockLibSessionCache)).to(beFalse())
            }
            
            // MARK: -- says no when config carries a profile feature
            it("says no when config carries a profile feature") {
                /// The case where Pro was only ever held on another device: it synced the feature bitset without
                /// this device ever holding a proof or an expiry
                try await mockLibSessionCache
                    .when { $0.profile(contactId: .any, threadId: .any, threadVariant: .any, visibleMessage: .any) }
                    .thenReturn(
                        Profile(
                            id: "05\(TestConstants.publicKey)",
                            name: "TestProfileName",
                            nickname: nil,
                            displayPictureUrl: nil,
                            displayPictureEncryptionKey: nil,
                            profileLastUpdated: nil,
                            blocksCommunityMessageRequests: nil,
                            proFeatures: .animatedAvatar,
                            proExpiryUnixTimestampSeconds: 0,
                            proRevocationTagHex: nil
                        )
                    )
                
                await expect(SessionProManager.hasNeverHeldPro(mockLibSessionCache)).to(beFalse())
            }
        }
    }
}
