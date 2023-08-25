// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Sodium
import SessionUtil
import SessionUtilitiesKit

import Quick
import Nimble

class LibSessionSpec: QuickSpec {
    // MARK: - Spec

    override func spec() {
        describe("libSession") {
            ConfigContacts.tests()
            ConfigUserProfile.tests()
            ConfigConvoInfoVolatile.tests()
            ConfigUserGroups.tests()
            ConfigGroupInfo.tests()
            ConfigGroupMembers.tests()
            ConfigGroupKeys.tests()
        }
    }
}
