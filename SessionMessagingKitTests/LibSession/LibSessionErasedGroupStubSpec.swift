// Copyright © 2026 Session Technology Foundation. All rights reserved.

import Foundation
import SessionUtilitiesKit

import Quick
import Nimble

@testable import SessionNetworkingKit
@testable import SessionMessagingKit

class LibSessionErasedGroupStubSpec: QuickSpec {
    override class func spec() {
        func groupInfo(
            name: String = "",
            groupIdentityPrivateKey: Data? = nil,
            authData: Data? = nil,
            wasKickedFromGroup: Bool = false,
            wasGroupDestroyed: Bool = true
        ) -> LibSession.GroupInfo {
            return LibSession.GroupInfo(
                groupSessionId: "03" + String(repeating: "ab", count: 32),
                groupIdentityPrivateKey: groupIdentityPrivateKey,
                name: name,
                authData: authData,
                priority: 0,
                joinedAt: 0,
                invited: false,
                wasKickedFromGroup: wasKickedFromGroup,
                wasGroupDestroyed: wasGroupDestroyed
            )
        }

        // MARK: - a LibSession GroupInfo
        describe("a LibSession GroupInfo") {
            // MARK: -- is an erased-group stub when removed with no name and no keys
            it("is an erased-group stub when removed with no name and no keys") {
                expect(groupInfo().isErasedGroupStub).to(beTrue())
                expect(groupInfo(wasKickedFromGroup: true, wasGroupDestroyed: false).isErasedGroupStub).to(beTrue())
            }

            // MARK: -- is not a stub when it keeps its name
            it("is not a stub when it keeps its name") {
                expect(groupInfo(name: "Book club").isErasedGroupStub).to(beFalse())
            }

            // MARK: -- is not a stub when it has an admin key or auth data
            it("is not a stub when it has an admin key or auth data") {
                expect(groupInfo(groupIdentityPrivateKey: Data(repeating: 1, count: 64)).isErasedGroupStub)
                    .to(beFalse())
                expect(groupInfo(authData: Data(repeating: 7, count: 100)).isErasedGroupStub).to(beFalse())
            }

            // MARK: -- is never a stub while the group is still in use
            it("is never a stub while the group is still in use") {
                expect(groupInfo(wasGroupDestroyed: false).isErasedGroupStub).to(beFalse())
            }
        }
    }
}
